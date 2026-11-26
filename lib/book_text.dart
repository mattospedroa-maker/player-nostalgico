import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'audiobooks.dart';
import 'library_search.dart' show normalizeText;
import 'podcast_info.dart' show Chapter;

/// Texto de uma obra (de domínio público), lido de um EPUB e guardado como JSON leve ao lado do áudio.
/// Só parágrafos de texto: sem imagens, estilos ou notas do EPUB (fica ~0,3 a 1 MB por livro).
class BookChapter {
  final String title;
  final List<String> paragraphs;

  /// Quando cada parágrafo começa no áudio (ms). Só no texto feito pela transcrição do vídeo; vazio no EPUB.
  final List<int> times;
  const BookChapter(this.title, this.paragraphs, [this.times = const []]);

  bool get timed => times.isNotEmpty && times.length == paragraphs.length;
  int get length => paragraphs.fold(0, (s, x) => s + x.length + 1);

  Map<String, Object> toJson() => {'t': title, 'p': paragraphs, if (timed) 'ms': times};
  static BookChapter fromJson(Map<String, dynamic> m) => BookChapter(
        '${m['t'] ?? ''}',
        [for (final x in (m['p'] as List?) ?? const []) '$x'],
        [for (final x in (m['ms'] as List?) ?? const []) (x as num).toInt()],
      );
}

class BookText {
  final String title;
  final String author;
  final List<BookChapter> chapters;
  const BookText({this.title = '', this.author = '', this.chapters = const []});

  bool get isEmpty => chapters.every((c) => c.paragraphs.isEmpty);

  /// Texto da transcrição: cada parágrafo sabe quando é lido.
  bool get timed => chapters.isNotEmpty && chapters.every((c) => c.timed || c.paragraphs.isEmpty);
  int get length => chapters.fold(0, (s, c) => s + c.length);

  Map<String, Object> toJson() => {'versao': 1, 'titulo': title, 'autor': author, 'capitulos': [for (final c in chapters) c.toJson()]};
  static BookText fromJson(Map<String, dynamic> m) => BookText(
        title: '${m['titulo'] ?? ''}',
        author: '${m['autor'] ?? ''}',
        chapters: [for (final c in (m['capitulos'] as List?) ?? const []) BookChapter.fromJson((c as Map).cast<String, dynamic>())],
      );

  static BookText? read(String audioPath) {
    try {
      final f = File(bookTextPath(audioPath));
      if (!f.existsSync()) return null;
      return fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String audioPath) => File(bookTextPath(audioPath)).writeAsString(jsonEncode(toJson()));
}

// ---------------------------------------------------------------------------
// EPUB -> BookText

class EpubException implements Exception {
  final String message;
  const EpubException(this.message);
  @override
  String toString() => message;
}

/// Lê um EPUB (zip com XHTML). Segue a ordem de leitura (spine) e o índice (nav/ncx) para os títulos.
/// Capítulos sem texto (capa, sumário, licença do Gutenberg) ficam de fora.
BookText parseEpub(Uint8List bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const EpubException('Esse arquivo não é um EPUB válido.');
  }
  String? read(String name) {
    final f = zip.findFile(name) ?? zip.files.where((x) => x.name.toLowerCase() == name.toLowerCase()).firstOrNull;
    if (f == null || !f.isFile) return null;
    return utf8.decode(f.content, allowMalformed: true);
  }

  final container = read('META-INF/container.xml');
  final opfPath = container == null ? null : RegExp(r'full-path="([^"]+)"').firstMatch(container)?.group(1);
  final opf = opfPath == null ? null : read(opfPath);
  if (opf == null) throw const EpubException('EPUB sem índice (content.opf).');
  final base = p.posix.dirname(opfPath!);
  String resolve(String href) => p.posix.normalize(base == '.' ? Uri.decodeComponent(href) : p.posix.join(base, Uri.decodeComponent(href)));

  final title = _meta(opf, 'title');
  final author = _meta(opf, 'creator');
  final manifest = <String, (String, String)>{}; // id -> (href, media-type)
  String? navHref, ncxId;
  for (final m in RegExp(r'<(?:\w+:)?item\b[^>]*>', caseSensitive: false).allMatches(opf)) {
    final tag = m.group(0)!;
    final id = _attr(tag, 'id'), href = _attr(tag, 'href'), type = _attr(tag, 'media-type') ?? '';
    if (id == null || href == null) continue;
    manifest[id] = (href, type);
    if ((_attr(tag, 'properties') ?? '').contains('nav')) navHref = href;
  }
  ncxId = RegExp(r'<(?:\w+:)?spine\b[^>]*\btoc="([^"]+)"', caseSensitive: false).firstMatch(opf)?.group(1);
  final spine = [
    for (final m in RegExp(r'<(?:\w+:)?itemref\b[^>]*>', caseSensitive: false).allMatches(opf))
      if (_attr(m.group(0)!, 'idref') case final id? when manifest.containsKey(id)) manifest[id]!.$1,
  ];

  // títulos do índice: arquivo -> título (o primeiro que aponta para o arquivo)
  final tocTitles = <String, String>{};
  if (navHref != null) {
    final nav = read(resolve(navHref));
    if (nav != null) {
      for (final m in RegExp(r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>', caseSensitive: false, dotAll: true).allMatches(nav)) {
        // o nav fica numa pasta própria: o href é relativo a ele
        final rel = p.posix.normalize(p.posix.join(p.posix.dirname(resolve(navHref)), Uri.decodeComponent(m.group(1)!.split('#').first)));
        final l = _plain(m.group(2)!).trim();
        if (l.isNotEmpty) tocTitles.putIfAbsent(rel, () => l);
      }
    }
  } else if (ncxId != null && manifest[ncxId] != null) {
    final ncx = read(resolve(manifest[ncxId]!.$1));
    if (ncx != null) {
      for (final m in RegExp(r'<navPoint\b.*?<text>(.*?)</text>.*?<content\b[^>]*src="([^"]+)"', caseSensitive: false, dotAll: true).allMatches(ncx)) {
        final rel = p.posix.normalize(p.posix.join(p.posix.dirname(resolve(manifest[ncxId]!.$1)), Uri.decodeComponent(m.group(2)!.split('#').first)));
        final l = _plain(m.group(1)!).trim();
        if (l.isNotEmpty) tocTitles.putIfAbsent(rel, () => l);
      }
    }
  }

  final chapters = <BookChapter>[];
  for (final href in spine) {
    final file = resolve(href);
    if (file == (navHref == null ? null : resolve(navHref))) continue;
    final html = read(file);
    if (html == null) continue;
    chapters.addAll(splitXhtml(html, fallbackTitle: tocTitles[file]));
  }
  final kept = [
    for (final c in chapters)
      if (c.paragraphs.isNotEmpty && !_isBoilerplate(c)) c,
  ];
  if (kept.isEmpty) throw const EpubException('Não achei texto nesse EPUB.');
  return BookText(title: title, author: author, chapters: kept);
}

/// Um arquivo XHTML vira um ou mais capítulos: cada título (h1/h2/h3) começa um capítulo novo.
/// (O Gutenberg costuma pôr vários capítulos num arquivo só.)
List<BookChapter> splitXhtml(String html, {String? fallbackTitle}) {
  final body = RegExp(r'<body\b[^>]*>(.*)</body>', caseSensitive: false, dotAll: true).firstMatch(html)?.group(1) ?? html;
  final cleaned = body
      .replaceAll(RegExp(r'<(script|style|head)\b.*?</\1>', caseSensitive: false, dotAll: true), '')
      .replaceAll(RegExp(r'<(sup|a)\b[^>]*class="[^"]*(noteref|footnote|pginternal)[^"]*"[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), '');
  final out = <BookChapter>[];
  String? curTitle = fallbackTitle;
  var paras = <String>[];
  void flush() {
    if (paras.isNotEmpty || (curTitle != null && out.isEmpty && paras.isNotEmpty)) out.add(BookChapter(curTitle ?? '', paras));
    paras = <String>[];
  }

  final block = RegExp(r'<(h[1-4]|p|div|blockquote|li|pre)\b[^>]*>(.*?)</\1>', caseSensitive: false, dotAll: true);
  for (final m in block.allMatches(cleaned)) {
    final tag = m.group(1)!.toLowerCase();
    final inner = m.group(2)!;
    if (tag == 'div' && RegExp(r'<(p|div|h\d)\b', caseSensitive: false).hasMatch(inner)) continue; // div que só embrulha
    final text = _plain(inner).trim();
    if (text.isEmpty) continue;
    if (tag.startsWith('h')) {
      if (paras.isNotEmpty) {
        flush();
        curTitle = text;
      } else {
        curTitle = curTitle == null || curTitle == fallbackTitle ? text : '$curTitle · $text'; // "CAPÍTULO VII" + "O DELÍRIO"
      }
      continue;
    }
    paras.add(text);
  }
  flush();
  return out;
}

bool _isBoilerplate(BookChapter c) {
  final t = normalizeText('${c.title} ${c.paragraphs.take(2).join(' ')}');
  return t.contains('project gutenberg') && (t.contains('license') || t.contains('licenca') || t.contains('start of') || t.contains('end of'));
}

String _meta(String opf, String name) =>
    _plain(RegExp('<dc:$name\\b[^>]*>(.*?)</dc:$name>', caseSensitive: false, dotAll: true).firstMatch(opf)?.group(1) ?? '').trim();

String? _attr(String tag, String name) => RegExp('\\b$name="([^"]*)"', caseSensitive: false).firstMatch(tag)?.group(1);

/// Tira as tags e troca as entidades HTML comuns. Espaços seguidos viram um.
String _plain(String html) {
  var s = html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ').replaceAll(RegExp(r'<[^>]+>'), '');
  s = s.replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
    return code == null ? '' : String.fromCharCode(code);
  });
  const ents = {'&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'", '&mdash;': '—', '&ndash;': '–', '&hellip;': '…', '&laquo;': '«', '&raquo;': '»'};
  for (final e in ents.entries) {
    s = s.replaceAll(e.key, e.value);
  }
  return s.replaceAll(RegExp(r'\s+'), ' ');
}

// ---------------------------------------------------------------------------
// Onde a narração está no texto

/// Número do capítulo no título ("Capítulo VII · O delírio" -> 7, "7. O delírio" -> 7). Null se não tem.
int? numberInTitle(String title) {
  final t = title.trim();
  final word = RegExp(r'(?:cap[ií]tulo|chapter|cap\.|parte|part)\s+([0-9]+|[ivxlcdm]+\b|[a-zà-ú]+(?:\s+e\s+[a-zà-ú]+)?)', caseSensitive: false).firstMatch(t);
  if (word != null) return chapterNumber(word.group(1)!);
  final lead = RegExp(r'^([0-9]+|[IVXLCDM]+)\b[.\-–—:)]?(\s|$)').firstMatch(t);
  if (lead != null) return chapterNumber(lead.group(1)!);
  return null;
}

/// Liga cada capítulo do áudio a um capítulo do texto: pelo número no título; sem número,
/// pela ordem (alinhando os dois finais). Devolve índice do texto para cada capítulo do áudio (-1 = sem par).
List<int> matchChapters(List<Chapter> audio, List<BookChapter> text) {
  if (audio.isEmpty || text.isEmpty) return List.filled(audio.length, -1);
  final textByNum = <int, int>{};
  for (var i = 0; i < text.length; i++) {
    final n = numberInTitle(text[i].title);
    if (n != null) textByNum.putIfAbsent(n, () => i);
  }
  final out = List.filled(audio.length, -1);
  var hits = 0;
  for (var i = 0; i < audio.length; i++) {
    final n = numberInTitle(audio[i].title);
    if (n != null && textByNum[n] != null) {
      out[i] = textByNum[n]!;
      hits++;
    }
  }
  if (hits >= audio.length ~/ 2 && hits > 0) {
    // capítulos sem número (introdução, prefácio) no meio: o do texto logo antes do próximo com par
    for (var i = 0; i < audio.length; i++) {
      if (out[i] >= 0) continue;
      final nextHit = out.skip(i + 1).firstWhere((x) => x >= 0, orElse: () => -1);
      if (nextHit > 0) out[i] = nextHit - 1;
    }
    return out;
  }
  // pela ordem: os últimos capítulos de cada lado se correspondem (introduções extras ficam no começo)
  final offset = text.length - audio.length;
  for (var i = 0; i < audio.length; i++) {
    final j = i + offset;
    out[i] = j >= 0 && j < text.length ? j : (j < 0 ? 0 : text.length - 1);
  }
  return out;
}

/// Onde a narração está: capítulo do texto e quanto dele já foi lido (0..1).
/// Sem capítulos no áudio, usa a proporção do livro inteiro.
({int chapter, double fraction}) textPosition({
  required BookText text,
  required List<Chapter> audio,
  required List<int> match,
  required Duration pos,
  required Duration total,
}) {
  if (text.chapters.isEmpty) return (chapter: 0, fraction: 0);
  final ms = pos.inMilliseconds, tot = total.inMilliseconds;
  if (text.timed) return timedPosition(text, ms, tot);
  if (audio.isNotEmpty && match.length == audio.length) {
    var i = 0;
    for (var k = 0; k < audio.length; k++) {
      if (audio[k].startMs <= ms) i = k;
    }
    final t = match[i];
    if (t >= 0) {
      final start = audio[i].startMs;
      // capítulos do áudio que caem no mesmo capítulo do texto dividem esse capítulo entre si
      var first = i, last = i;
      while (first > 0 && match[first - 1] == t) {
        first--;
      }
      while (last + 1 < audio.length && match[last + 1] == t) {
        last++;
      }
      final from = audio[first].startMs;
      final to = last + 1 < audio.length ? audio[last + 1].startMs : (tot > 0 ? tot : start + 1);
      final f = to > from ? ((ms - from) / (to - from)).clamp(0.0, 1.0) : 0.0;
      return (chapter: t, fraction: f);
    }
  }
  if (tot <= 0) return (chapter: 0, fraction: 0);
  // livro inteiro: proporção de letras
  final target = (ms / tot).clamp(0.0, 1.0) * text.length;
  var acc = 0;
  for (var i = 0; i < text.chapters.length; i++) {
    final len = text.chapters[i].length;
    if (acc + len >= target) return (chapter: i, fraction: len == 0 ? 0 : (target - acc) / len);
    acc += len;
  }
  return (chapter: text.chapters.length - 1, fraction: 1);
}

/// Tempo do áudio onde começa o capítulo [textIndex] do texto (para "tocar daqui"). Null sem par.
Duration? audioStartOfText(int textIndex, List<Chapter> audio, List<int> match) {
  for (var i = 0; i < audio.length && i < match.length; i++) {
    if (match[i] == textIndex) return Duration(milliseconds: audio[i].startMs);
  }
  return null;
}

/// Posição exata no texto da transcrição: o parágrafo que está sendo lido, e quanto dele (pelo tempo até o próximo).
({int chapter, double fraction}) timedPosition(BookText text, int ms, int totalMs) {
  var c = 0, k = 0;
  for (var i = 0; i < text.chapters.length; i++) {
    final t = text.chapters[i].times;
    if (t.isEmpty) continue;
    if (t.first > ms && i > 0) break;
    c = i;
    k = 0;
    for (var j = 0; j < t.length; j++) {
      if (t[j] <= ms) k = j;
    }
  }
  final ch = text.chapters[c];
  if (ch.paragraphs.isEmpty) return (chapter: c, fraction: 0);
  var before = 0;
  for (var j = 0; j < k; j++) {
    before += ch.paragraphs[j].length + 1;
  }
  // próximo parágrafo (deste capítulo ou do seguinte) marca o fim deste
  int? next = k + 1 < ch.times.length ? ch.times[k + 1] : null;
  if (next == null) {
    for (var i = c + 1; i < text.chapters.length && next == null; i++) {
      if (text.chapters[i].times.isNotEmpty) next = text.chapters[i].times.first;
    }
  }
  next ??= totalMs > ch.times[k] ? totalMs : ch.times[k] + 1;
  final inside = ((ms - ch.times[k]) / (next - ch.times[k])).clamp(0.0, 1.0);
  return (chapter: c, fraction: ((before + inside * ch.paragraphs[k].length) / ch.length).clamp(0.0, 1.0));
}

// ---------------------------------------------------------------------------
// Transcrição do vídeo -> BookText

/// Trechos da legenda automática do vídeo, guardados ao lado do áudio ("Livro.transcricao.json"),
/// e os parágrafos que o Gemini já arrumou (pedaço a pedaço, mantendo os tempos).
class Transcript {
  /// (início em ms, texto) de cada trecho da legenda.
  final List<(int, String)> segs;

  /// Parágrafos arrumados (início em ms, texto) dos primeiros [done] pedaços.
  final List<(int, String)> polished;
  final int done;
  const Transcript(this.segs, {this.polished = const [], this.done = 0});

  /// Trechos por pedaço mandado ao Gemini (~12 min de leitura, uns 2 mil palavras).
  static const chunk = 250;
  int get chunks => (segs.length + chunk - 1) ~/ chunk;
  bool get finished => done >= chunks;

  Map<String, Object> toJson() => {
        'versao': 1,
        'trechos': [for (final (ms, t) in segs) [ms, t]],
        'arrumados': [for (final (ms, t) in polished) [ms, t]],
        'pedacos': done,
      };

  static List<(int, String)> _pairs(Object? v) => [
        for (final x in (v as List?) ?? const [])
          if (x is List && x.length == 2) ((x[0] as num).toInt(), '${x[1]}'),
      ];

  static Transcript fromJson(Map<String, dynamic> m) =>
      Transcript(_pairs(m['trechos']), polished: _pairs(m['arrumados']), done: (m['pedacos'] as num?)?.toInt() ?? 0);

  static Transcript? read(String audioPath) {
    try {
      final f = File(transcriptPath(audioPath));
      if (!f.existsSync()) return null;
      return fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String audioPath) => File(transcriptPath(audioPath)).writeAsString(jsonEncode(toJson()));

  /// Parágrafos de agora: os já arrumados + o resto montado pelas pausas da fala.
  List<(int, String)> paragraphs() => [...polished, ...roughParagraphs(segs.sublist(math.min(done * chunk, segs.length)))];

  /// Texto do livro: um capítulo do texto por capítulo do áudio (mesmos títulos); sem capítulos, partes de 30 min.
  BookText toBook({required String title, required String author, required List<Chapter> audio}) =>
      BookText(title: title, author: author, chapters: splitByTime(paragraphs(), audio));
}

/// Legenda automática não tem pontuação: um parágrafo novo a cada pausa longa (ou a cada ~120 palavras),
/// com a primeira letra maiúscula e ponto no fim.
List<(int, String)> roughParagraphs(List<(int, String)> segs) {
  final out = <(int, String)>[];
  var start = -1, words = 0;
  final buf = StringBuffer();
  void flush() {
    final t = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isNotEmpty) {
      var p = t[0].toUpperCase() + t.substring(1);
      if (!RegExp(r'[.!?…:;"”»]$').hasMatch(p)) p = '$p.';
      out.add((start, p));
    }
    buf.clear();
    words = 0;
    start = -1;
  }

  for (var i = 0; i < segs.length; i++) {
    final (ms, text) = segs[i];
    final clean = text.replaceAll(RegExp(r'\[(música|music|aplausos|risos|applause|laughter)\]', caseSensitive: false), ' ').trim();
    if (clean.isEmpty) continue;
    if (start < 0) start = ms;
    buf
      ..write(clean)
      ..write(' ');
    words += clean.split(RegExp(r'\s+')).length;
    final gap = i + 1 < segs.length ? segs[i + 1].$1 - ms : 0;
    // pausa: o próximo trecho demora a chegar (leitura de audiolivro: ~2-4 s por trecho)
    if ((words >= 40 && gap >= 5500) || words >= 120) flush();
  }
  flush();
  return out;
}

/// Divide os parágrafos pelos capítulos do áudio (pelo tempo em que cada um começa).
List<BookChapter> splitByTime(List<(int, String)> pars, List<Chapter> audio) {
  if (pars.isEmpty) return const [];
  final starts = <(int, String)>[
    if (audio.isNotEmpty) ...[for (final c in audio) (c.startMs, c.title)]
    else
      for (var k = 0; k * 1800000 <= pars.last.$1; k++) (k * 1800000, 'Parte ${k + 1}'),
  ];
  final out = <BookChapter>[];
  for (var i = 0; i < starts.length; i++) {
    final from = i == 0 ? -1 : starts[i].$1;
    final to = i + 1 < starts.length ? starts[i + 1].$1 : 1 << 62;
    final mine = [for (final x in pars) if (x.$1 >= from && x.$1 < to) x];
    out.add(BookChapter(starts[i].$2, [for (final x in mine) x.$2], [for (final x in mine) x.$1]));
  }
  return out;
}

/// Pedido ao Gemini para arrumar um pedaço da legenda (pontuação e parágrafos), sem resumir.
String polishPrompt({required String title, required String author, required List<(int, String)> segs, required int firstIndex}) => '''
Abaixo há trechos numerados da legenda automática da leitura do livro "$title", de $author.
A legenda não tem pontuação e pode ter palavras erradas. Reescreva como texto de livro:
- ponha pontuação, letras maiúsculas e travessões nos diálogos; divida em parágrafos como num livro;
- corrija só palavras que a legenda claramente ouviu errado;
- NÃO resuma, NÃO pule e NÃO invente frases: todo o conteúdo tem que continuar;
- tire falas que não são do livro (ex.: "inscreva-se no canal", "[música]").
Para cada parágrafo, diga o número do trecho em que ele começa ("i"), em ordem crescente.
Responda só com JSON: {"p": [{"i": $firstIndex, "t": "Parágrafo pontuado."}]}

Trechos:
${[for (var k = 0; k < segs.length; k++) '[${firstIndex + k}] ${segs[k].$2}'].join('\n')}
''';

/// Confere a resposta do Gemini para um pedaço: começa no 1º trecho, números crescentes dentro do pedaço e
/// quase o mesmo tanto de palavras (não resumiu nem inventou). Null = resposta ruim (fica a versão das pausas).
List<(int, String)>? polishedFromAi(Object? ai, List<(int, String)> segs, int firstIndex) {
  if (ai is! Map || ai['p'] is! List) return null;
  final out = <(int, String)>[];
  var last = firstIndex - 1;
  for (final x in ai['p'] as List) {
    if (x is! Map) return null;
    final i = (x['i'] as num?)?.toInt();
    final t = '${x['t'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) continue;
    if (i == null || i <= last || i < firstIndex || i >= firstIndex + segs.length) return null;
    last = i;
    out.add((segs[i - firstIndex].$1, t));
  }
  if (out.isEmpty) return null;
  // o primeiro parágrafo começa no primeiro trecho (nada some no começo)
  out[0] = (segs.first.$1, out[0].$2);
  int count(String s) => s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  final before = segs.fold(0, (n, s) => n + count(s.$2));
  final after = out.fold(0, (n, p) => n + count(p.$2));
  if (before == 0) return null;
  final r = after / before;
  return r >= .8 && r <= 1.25 ? out : null;
}
