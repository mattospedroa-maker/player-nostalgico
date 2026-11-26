import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'audiobooks.dart';
import 'book_text.dart';
import 'error_log.dart';
import 'library_search.dart' show normalizeText;
import 'podcast_info.dart' show Chapter, GeminiClient, captionUrl;

/// Cuida das partes dos audiolivros que vêm da internet: capítulos (na hora do download), o texto da obra
/// (Projeto Gutenberg → Wikisource, ou um EPUB que você anexa) e uma ilustração antiga por capítulo.
/// Tudo fica guardado ao lado do áudio, então funciona off-line depois.
class BookService extends ChangeNotifier {
  final http.Client client;
  String Function() geminiKey;

  /// Pode buscar texto/ilustrações sozinho agora? (aba Internet das Opções)
  bool Function() allowNet;

  /// Pode usar a IA agora?
  bool Function() allowAi;

  BookService({required this.client, required this.geminiKey, bool Function()? allowNet, bool Function()? allowAi})
      : allowNet = allowNet ?? (() => true),
        allowAi = allowAi ?? (() => true);

  static const _ua = {'User-Agent': 'NostalgicMPlayer/1.0 (app pessoal de audiolivros offline)'};

  /// Teto de ilustrações por livro (~150 KB cada: uns 5 MB por livro).
  static const maxArt = 30;

  final Map<String, BookInfo?> _info = {};
  final Map<String, BookText?> _text = {};
  final Set<String> _working = {};

  bool isWorking(String path) => _working.contains(path);

  BookInfo? infoFor(String path) => _info.containsKey(path) ? _info[path] : (_info[path] = BookInfo.read(path));

  /// Texto da obra já carregado (null = ainda não leu do disco, ou não tem). Use [loadText] para ler.
  BookText? textIfLoaded(String path) => _text[path];

  bool hasTextFile(String path) => _text[path] != null || File(bookTextPath(path)).existsSync();

  /// Lê o texto do disco fora da linha da tela (o JSON de um livro tem centenas de KB).
  Future<BookText?> loadText(String path) async {
    if (_text.containsKey(path)) return _text[path];
    final file = bookTextPath(path);
    final t = await Isolate.run(() {
      try {
        final f = File(file);
        return f.existsSync() ? BookText.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>) : null;
      } catch (_) {
        return null;
      }
    });
    _text[path] = t;
    return t;
  }

  Future<void> save(String path, BookInfo info) async {
    _info[path] = info;
    try {
      await File(bookInfoPath(path)).writeAsString(const JsonEncoder.withIndent('  ').convert(info.toJson()));
    } catch (e) {
      errorLog.warn('Audiolivros', 'Não deu para salvar as informações do livro ${p.basename(path)}', error: e);
    }
    notifyListeners();
  }

  /// O livro mudou de lugar: informações, texto e ilustrações vão junto.
  void moved(String from, String to) {
    for (final (a, b) in [(bookInfoPath(from), bookInfoPath(to)), (bookTextPath(from), bookTextPath(to))]) {
      try {
        if (File(a).existsSync()) File(a).renameSync(b);
      } catch (e) {
        errorLog.info('Audiolivros', 'Não deu para mover ${p.basename(a)} junto com o livro', e);
      }
    }
    try {
      final d = Directory(bookArtDir(from));
      if (d.existsSync()) d.renameSync(bookArtDir(to));
    } catch (e) {
      errorLog.info('Audiolivros', 'Não deu para mover as ilustrações junto com o livro', e);
    }
    for (final m in [_info, _text]) {
      m.remove(from);
      m.remove(to);
    }
  }

  /// Ajuste à mão: troca o começo de um capítulo (ou o título).
  Future<void> editChapter(String path, int index, {Duration? start, String? title}) async {
    final info = infoFor(path);
    if (info == null || index < 0 || index >= info.chapters.length) return;
    final list = [...info.chapters];
    final c = list[index];
    list[index] = Chapter(startMs: start?.inMilliseconds ?? c.startMs, title: title ?? c.title, summary: c.summary, visual: c.visual);
    list.sort((a, b) => a.startMs.compareTo(b.startMs));
    await save(path, info.copyWith(chapters: list, chapterSource: ChapterSource.manual));
  }

  // ---------------------------------------------------------------------------
  // Capítulos (na hora do download)

  /// Monta as informações a partir do yt-dlp (-J): capítulos pela descrição → legenda → Gemini.
  /// Nunca lança: sem internet/legenda/chave, fica com o que deu.
  Future<BookInfo> build(Map<String, dynamic> yt, {required String title, required String author}) async {
    final id = '${yt['id'] ?? ''}';
    var info = BookInfo(
      videoId: id,
      url: '${yt['webpage_url'] ?? (id.isEmpty ? '' : 'https://www.youtube.com/watch?v=$id')}',
      title: title,
      author: author,
    );
    var (chapters, source) = detectChapters(yt);
    if (chapters.isNotEmpty) return info.copyWith(chapters: chapters, chapterSource: source);
    // legenda automática: procura "capítulo N" falado
    var captions = const <(int, String)>[];
    try {
      final url = captionUrl(yt);
      if (url != null) {
        final r = await client.get(url).timeout(const Duration(seconds: 40));
        if (r.statusCode == 200) captions = parseCaptions(utf8.decode(r.bodyBytes, allowMalformed: true));
      }
    } catch (e) {
      errorLog.info('Audiolivros', 'Não deu para ler a legenda do livro "$title"', e);
    }
    (chapters, source) = detectChapters(yt, captions: captions);
    if (chapters.isNotEmpty) return info.copyWith(chapters: chapters, chapterSource: source);
    // por último, o Gemini lê a transcrição
    final key = geminiKey().trim();
    if (captions.isNotEmpty && key.isNotEmpty && allowAi()) {
      try {
        final ai = await GeminiClient(client, key).generateJson(chapterPrompt(title: title, author: author, transcript: bookTranscript(captions)));
        final c = chaptersFromAi(ai);
        if (c.length >= 2) return info.copyWith(chapters: c, chapterSource: ChapterSource.ai);
      } catch (e) {
        errorLog.info('Audiolivros', 'O Gemini não conseguiu marcar os capítulos de "$title"', e);
      }
    }
    return info;
  }

  // ---------------------------------------------------------------------------
  // Texto da obra

  /// Procura e baixa o texto da obra (sozinho, depois do download, ou pelo botão "Procurar texto").
  /// [manual]: pedido por você (vale mesmo com a busca automática desligada na aba Internet).
  Future<TextStatus> fetchText(String path, {bool manual = false}) async {
    final info = infoFor(path) ?? const BookInfo();
    if (!manual && (!allowNet() || info.textStatus == TextStatus.notFound)) return info.textStatus;
    if (!_working.add(path)) return TextStatus.searching;
    await save(path, info.copyWith(textStatus: TextStatus.searching));
    try {
      final title = info.title, author = info.author;
      final found = await _findEpub(title, author);
      if (found == null) {
        await save(path, info.copyWith(textStatus: TextStatus.notFound));
        return TextStatus.notFound;
      }
      final text = await Isolate.run(() => parseEpub(found.$1));
      await text.save(path);
      _text[path] = text;
      await save(path, info.copyWith(textStatus: TextStatus.ok, textSource: found.$2));
      unawaited(fetchArt(path));
      return TextStatus.ok;
    } catch (e) {
      errorLog.add(ErrorLog.isNetwork(e) ? LogLevel.info : LogLevel.warning, 'Audiolivros', 'Não deu para baixar o texto de "${info.title}"', error: e);
      await save(path, info.copyWith(textStatus: TextStatus.failed));
      return TextStatus.failed;
    } finally {
      _working.remove(path);
      notifyListeners();
    }
  }

  /// Usa um EPUB escolhido no celular.
  Future<void> attachEpub(String path, String epubPath) async {
    final bytes = await File(epubPath).readAsBytes();
    final text = await Isolate.run(() => parseEpub(bytes));
    await text.save(path);
    _text[path] = text;
    final info = infoFor(path) ?? const BookInfo();
    await save(path, info.copyWith(textStatus: TextStatus.ok, textSource: 'EPUB anexado (${p.basename(epubPath)})', artDone: false));
    unawaited(fetchArt(path));
  }

  /// Tira o texto (o livro volta a mostrar só a capa e as ilustrações).
  Future<void> removeText(String path) async {
    try {
      final f = File(bookTextPath(path));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    _text[path] = null;
    final info = infoFor(path) ?? const BookInfo();
    await save(path, info.copyWith(textStatus: TextStatus.none, textSource: ''));
  }

  /// Gutenberg (EPUB pronto, sem imagens) → Wikisource (EPUB gerado pelo ws-export). (bytes, de onde veio)
  /// Não achou com o nome em português? O Gemini diz o nome da obra em inglês (e o autor na grafia do Gutenberg)
  /// e tenta de novo: traduções em português de obras russas/alemãs quase sempre ainda têm direitos autorais,
  /// então o texto livre costuma estar em inglês.
  Future<(Uint8List, String)?> _findEpub(String title, String author) async {
    if (title.trim().isEmpty) return null;
    final g = await _gutenberg(title, author);
    if (g != null) return g;
    for (final lang in ['pt', 'en']) {
      final w = await _wikisource(title, author, lang);
      if (w != null) return w;
    }
    final other = await _identify(title, author);
    if (other == null) return null;
    final g2 = await _gutenberg(other.title, other.author);
    if (g2 != null) return g2;
    return _wikisource(other.title, other.author, 'en');
  }

  /// Nome da obra e do autor em inglês, pelo Gemini (uma pergunta curta, só quando a busca normal falhou).
  Future<({String title, String author})?> _identify(String title, String author) async {
    final key = geminiKey();
    if (key.isEmpty || !allowAi()) return null;
    try {
      final r = bookIdentityFromAi(await GeminiClient(client, key).generateJson(identifyPrompt(title, author)));
      if (r == null || (titleSimilarity(r.title, title) == 1 && normalizeText(r.author) == normalizeText(author))) return null;
      return r;
    } catch (e) {
      errorLog.info('Audiolivros', 'O Gemini não reconheceu a obra "$title"', e);
      return null;
    }
  }

  static String identifyPrompt(String title, String author) => '''
Audiolivro: "$title", autor "$author" (pode estar em português e com grafia brasileira).
Que obra é essa? Diga o título mais usado EM INGLÊS e o nome do autor como aparece no Projeto Gutenberg (grafia inglesa).
Responda só com JSON: {"titulo_en": "White Nights", "autor_en": "Fyodor Dostoyevsky"}. Se não souber, {"titulo_en": ""}.
''';

  @visibleForTesting
  static ({String title, String author})? bookIdentityFromAi(Object? ai) {
    if (ai is! Map) return null;
    final t = '${ai['titulo_en'] ?? ''}'.trim(), a = '${ai['autor_en'] ?? ''}'.trim();
    return t.isEmpty ? null : (title: t, author: a);
  }

  Future<(Uint8List, String)?> _gutenberg(String title, String author) async {
    try {
      // o autor em várias grafias ("Dostoiévski" → dostoyevsky, dostoevsky) e, por último, só o título
      final queries = <String>{for (final v in surnameVariants(author).take(3)) '$title $v', title};
      for (final q in queries) {
        final r = await client.get(Uri.https('gutendex.com', '/books', {'search': q.trim()}), headers: _ua).timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) continue;
        final best = pickGutenberg(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>, title, author);
        if (best == null) continue;
        final epub =
            await client.get(Uri.parse('https://www.gutenberg.org/ebooks/${best.id}.epub.noimages'), headers: _ua).timeout(const Duration(minutes: 2));
        if (epub.statusCode != 200 || epub.bodyBytes.length < 1000) return null;
        return (epub.bodyBytes, 'Projeto Gutenberg #${best.id}${langLabel(best.lang)}');
      }
      return null;
    } catch (e) {
      errorLog.info('Audiolivros', 'Projeto Gutenberg não respondeu', e);
      return null;
    }
  }

  /// " (em inglês)" para mostrar de onde veio o texto quando não é português.
  static String langLabel(String lang) => switch (lang) {
        'pt' || '' => '',
        'en' => ' (em inglês)',
        'es' => ' (em espanhol)',
        'fr' => ' (em francês)',
        _ => ' ($lang)',
      };

  Future<(Uint8List, String)?> _wikisource(String title, String author, String lang) async {
    try {
      final r = await client
          .get(
              Uri.https('$lang.wikisource.org', '/w/api.php', {
                'action': 'query',
                'list': 'search',
                'srsearch': '$title ${_lastName(author)}'.trim(),
                'srnamespace': '0',
                'srlimit': '8',
                'format': 'json',
              }),
              headers: _ua)
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      final page = pickWikisource(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>, title);
      if (page == null) return null;
      final epub = await client
          .get(Uri.https('ws-export.wmcloud.org', '/', {'format': 'epub', 'lang': lang, 'page': page}), headers: _ua)
          .timeout(const Duration(minutes: 3));
      if (epub.statusCode != 200 || epub.bodyBytes.length < 1000) return null;
      return (epub.bodyBytes, 'Wikisource ($lang): $page${langLabel(lang)}');
    } catch (e) {
      errorLog.info('Audiolivros', 'Wikisource não respondeu', e);
      return null;
    }
  }

  static String _lastName(String author) {
    final w = author.trim().split(RegExp(r'\s+'));
    return author == unknownAuthor || w.isEmpty ? '' : w.last;
  }

  /// Escolhe o livro certo na resposta do Gutendex: título parecido (e autor, quando conhecido, em qualquer grafia);
  /// prefere português.
  @visibleForTesting
  static ({int id, String lang})? pickGutenberg(Map<String, dynamic> json, String title, String author) {
    ({int id, String lang})? best;
    var bestScore = 0.0;
    final names = author == unknownAuthor ? const <String>[] : surnameVariants(author);
    for (final b in (json['results'] as List?) ?? const []) {
      if (b is! Map) continue;
      final formats = (b['formats'] as Map?) ?? const {};
      if (!formats.keys.any((k) => '$k'.startsWith('application/epub'))) continue;
      final id = (b['id'] as num?)?.toInt();
      if (id == null) continue;
      final authors = normalizeText([for (final a in (b['authors'] as List?) ?? const []) if (a is Map) '${a['name'] ?? ''}'].join(' '));
      var score = titleSimilarity(title, '${b['title'] ?? ''}');
      if (score < .6) continue;
      if (names.isNotEmpty) score += names.any(authors.contains) ? .3 : -.4;
      final langs = [for (final l in (b['languages'] as List?) ?? const []) '$l'];
      if (langs.contains('pt')) score += .1;
      if (score > bestScore) {
        bestScore = score;
        best = (id: id, lang: langs.contains('pt') ? 'pt' : (langs.firstOrNull ?? ''));
      }
    }
    return bestScore >= .6 ? best : null;
  }

  /// Escolhe a página da obra na busca do Wikisource (título parecido; não um capítulo solto).
  @visibleForTesting
  static String? pickWikisource(Map<String, dynamic> json, String title) {
    String? best;
    var bestScore = 0.0;
    for (final r in (json['query']?['search'] as List?) ?? const []) {
      if (r is! Map) continue;
      final t = '${r['title'] ?? ''}';
      if (t.contains('/')) continue; // subpágina = capítulo
      final s = titleSimilarity(title, t);
      if (s > bestScore) {
        bestScore = s;
        best = t;
      }
    }
    return bestScore >= .7 ? best : null;
  }

  /// Quanto dois títulos se parecem (0..1): palavras do primeiro que aparecem no segundo.
  /// "Memórias Póstumas de Brás Cubas" ≈ "Memorias Posthumas de Braz Cubas" (grafia antiga).
  static double titleSimilarity(String a, String b) {
    List<String> words(String s) => [
          for (final w in normalizeText(s).replaceAll('th', 't').replaceAll('z', 's').replaceAll('y', 'i').split(RegExp(r'[^a-z0-9]+')))
            if (w.length > 2) w,
        ];
    final wa = words(a), wb = words(b).toSet();
    if (wa.isEmpty || wb.isEmpty) return 0;
    return wa.where(wb.contains).length / wa.length;
  }

  // ---------------------------------------------------------------------------
  // Ilustrações por capítulo

  /// Capítulos do áudio que ganham ilustração: todos até [maxArt]; mais que isso, espalhados pelo livro.
  @visibleForTesting
  static List<int> artSlots(int chapters) {
    if (chapters <= maxArt) return [for (var i = 0; i < chapters; i++) i];
    return [for (var k = 0; k < maxArt; k++) (k * chapters / maxArt).floor()];
  }

  /// Pedido para o Gemini: uma cena e uma busca (em inglês, para o Wikimedia Commons) por capítulo.
  static String artPrompt(String title, String author, List<(int, String, String)> chapters) => '''
Livro de domínio público: "$title", de $author.
Para cada capítulo abaixo, escolha UMA cena marcante e escreva uma busca curta EM INGLÊS para achar uma ilustração ou
pintura antiga (domínio público) no Wikimedia Commons. Prefira coisas concretas (lugar, objeto, animal, época, tipo de pessoa).
Responda só com JSON: {"cenas": [{"i": 0, "cena": "frase curta em português", "busca": "19th century engraving hippopotamus"}]}

Capítulos (i: título — começo do texto):
${chapters.map((c) => '${c.$1}: ${c.$2} — ${c.$3}').join('\n')}
''';

  /// Busca as ilustrações que faltam (uma vez por livro; respeita a aba Internet e o teto de [maxArt]).
  Future<void> fetchArt(String path, {bool manual = false}) async {
    var info = infoFor(path);
    if (info == null || (!manual && (info.artDone || !allowNet()))) return;
    if (!_working.add('$path#art')) return;
    try {
      final text = await loadText(path);
      final n = info.chapters.isNotEmpty ? info.chapters.length : (text?.chapters.length ?? 0);
      if (n == 0) return;
      final slots = artSlots(n);
      final match = text == null ? const <int>[] : matchChapters(info.chapters, text.chapters);
      String opening(int i) {
        if (text == null) return '';
        final t = info!.chapters.isEmpty ? i : (i < match.length ? match[i] : -1);
        if (t < 0 || t >= text.chapters.length) return '';
        final s = text.chapters[t].paragraphs.take(3).join(' ');
        return s.length > 350 ? s.substring(0, 350) : s;
      }

      String titleOf(int i) => info!.chapters.isNotEmpty ? info.chapters[i].title : (text?.chapters[i].title ?? 'Capítulo ${i + 1}');
      final queries = <int, String>{};
      final key = geminiKey().trim();
      if (key.isNotEmpty && allowAi()) {
        try {
          final ai = await GeminiClient(client, key).generateJson(artPrompt(info.title, info.author, [for (final i in slots) (i, titleOf(i), opening(i))]));
          for (final c in (ai['cenas'] as List?) ?? const []) {
            if (c is Map && c['i'] is num && '${c['busca'] ?? ''}'.trim().isNotEmpty) queries[(c['i'] as num).toInt()] = '${c['busca']}'.trim();
          }
        } catch (e) {
          errorLog.info('Audiolivros', 'O Gemini não escolheu as cenas de "${info.title}"', e);
        }
      }
      // sem IA: ilustrações da própria obra/autor espalhadas pelos capítulos
      if (queries.isEmpty) {
        final generic = '${info.title} ${info.author}'.trim();
        for (final i in slots.take(6)) {
          queries[i] = generic;
        }
      }
      final dir = Directory(bookArtDir(path));
      await dir.create(recursive: true);
      final art = {...info.art}, credit = {...info.artCredit};
      final used = <String>{...art.values};
      for (final e in queries.entries) {
        if (art.containsKey(e.key) || art.length >= maxArt) continue;
        final img = await _commonsImage(e.value, skip: used);
        if (img == null) continue;
        try {
          final r = await client.get(Uri.parse(img.url), headers: _ua).timeout(const Duration(seconds: 40));
          if (r.statusCode != 200 || r.bodyBytes.length < 2000) continue;
          final name = 'cap_${e.key}${img.ext}';
          await File(p.join(dir.path, name)).writeAsBytes(r.bodyBytes);
          art[e.key] = name;
          credit[e.key] = img.credit;
          used.add(img.id);
        } catch (err) {
          errorLog.info('Audiolivros', 'Não deu para baixar uma ilustração', err);
        }
      }
      info = infoFor(path) ?? info;
      await save(path, info.copyWith(art: art, artCredit: credit, artDone: true));
    } finally {
      _working.remove('$path#art');
      notifyListeners();
    }
  }

  /// Uma imagem de domínio público no Wikimedia Commons (miniatura de 800 px).
  Future<({String url, String ext, String credit, String id})?> _commonsImage(String query, {Set<String> skip = const {}}) async {
    try {
      final r = await client
          .get(
              Uri.https('commons.wikimedia.org', '/w/api.php', {
                'action': 'query',
                'format': 'json',
                'generator': 'search',
                'gsrsearch': 'filetype:bitmap $query',
                'gsrnamespace': '6',
                'gsrlimit': '12',
                'prop': 'imageinfo',
                'iiprop': 'url|mime|extmetadata',
                'iiurlwidth': '800',
                'iiextmetadatafilter': 'Artist|LicenseShortName',
              }),
              headers: _ua)
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return null;
      return pickCommons(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>, skip: skip);
    } catch (e) {
      errorLog.info('Audiolivros', 'Wikimedia Commons não respondeu', e);
      return null;
    }
  }

  /// A primeira imagem JPEG/PNG em domínio público (ou CC0) da resposta do Commons.
  @visibleForTesting
  static ({String url, String ext, String credit, String id})? pickCommons(Map<String, dynamic> json, {Set<String> skip = const {}}) {
    final pages = (json['query']?['pages'] as Map<String, dynamic>?)?.values.whereType<Map<String, dynamic>>().toList() ?? [];
    pages.sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    String strip(Object? s) => '${s ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    for (final pg in pages) {
      final info = (pg['imageinfo'] as List?)?.whereType<Map<String, dynamic>>().firstOrNull;
      if (info == null) continue;
      final mime = '${info['mime'] ?? ''}';
      if (mime != 'image/jpeg' && mime != 'image/png') continue;
      final meta = (info['extmetadata'] as Map?) ?? const {};
      final lic = strip((meta['LicenseShortName'] as Map?)?['value']);
      final l = lic.toLowerCase();
      if (!(l.contains('public domain') || l.startsWith('pd') || l.contains('cc0') || l.contains('domínio público'))) continue;
      final id = '${pg['title'] ?? ''}';
      if (skip.contains(id)) continue;
      final url = '${info['thumburl'] ?? info['url'] ?? ''}';
      if (url.isEmpty) continue;
      return (
        url: url,
        ext: mime == 'image/png' ? '.png' : '.jpg',
        credit: '${id.replaceFirst('File:', '')} · ${strip((meta['Artist'] as Map?)?['value'])} · $lic',
        id: id,
      );
    }
    return null;
  }

  /// Arquivo da ilustração do capítulo [i] (null = não tem).
  File? artFile(String path, int i) {
    final name = infoFor(path)?.art[i];
    if (name == null) return null;
    final f = File(p.join(bookArtDir(path), name));
    return f.existsSync() ? f : null;
  }

  /// Todas as ilustrações do livro, na ordem dos capítulos.
  List<File> allArt(String path) {
    final info = infoFor(path);
    if (info == null) return const [];
    final keys = info.art.keys.toList()..sort();
    return [for (final k in keys) ?artFile(path, k)];
  }
}
