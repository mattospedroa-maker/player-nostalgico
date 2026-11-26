import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'error_log.dart';
import 'library_search.dart' show normalizeText;
import 'models.dart';
import 'organizer.dart' show safeFolderName;
import 'podcast_info.dart' show Chapter, parseJson3, transcriptText;

/// Audiolivros são o terceiro tipo de mídia: ficam em `<pasta de músicas>`/Audiolivros/Autor/Livro.m4a.
/// Um livro é UM arquivo só; os capítulos são marcas de tempo guardadas num .json ao lado do áudio
/// (sem cortar o arquivo). Como os podcasts, nunca entram em Músicas, Tocar tudo, mix ou playlists.
const audiobooksFolder = 'Audiolivros';

/// Nome usado quando o autor é desconhecido.
const unknownAuthor = 'Autor desconhecido';

/// O arquivo está dentro de `<raiz>`/Audiolivros/?
bool isAudiobookPath(String? root, String path) {
  if (root == null || root.isEmpty || !p.isWithin(root, path)) return false;
  final parts = p.split(p.relative(path, from: root));
  return parts.length > 1 && parts.first.toLowerCase() == audiobooksFolder.toLowerCase();
}

/// Onde um livro baixado fica: Audiolivros/`<Autor>`/`<Livro>`.ext
String audiobookTargetPath(String root, String author, String fileName) =>
    p.join(root, audiobooksFolder, safeFolderName(author.trim().isEmpty ? unknownAuthor : author), fileName);

/// Arquivo de informações do livro ao lado do áudio: "Livro.m4a" -> "Livro.livro.json".
String bookInfoPath(String audioPath) => '${p.withoutExtension(audioPath)}.livro.json';

/// Texto da obra já lido do EPUB: "Livro.m4a" -> "Livro.texto.json".
String bookTextPath(String audioPath) => '${p.withoutExtension(audioPath)}.texto.json';

/// Legenda do vídeo guardada para o texto feito pela transcrição: "Livro.m4a" -> "Livro.transcricao.json".
String transcriptPath(String audioPath) => '${p.withoutExtension(audioPath)}.transcricao.json';

/// Pasta das ilustrações do livro: "Livro.m4a" -> ".Livro.ilustracoes/" (escondida, ao lado do áudio).
String bookArtDir(String audioPath) => p.join(p.dirname(audioPath), '.${p.basenameWithoutExtension(audioPath)}.ilustracoes');

// ---------------------------------------------------------------------------
// Detecção

final _bookWords = RegExp(
  r'audio\s?livro|audiobook|audio\s?book|livro\s+(completo|narrado|falado)|narra[çc][ãa]o\s+completa|'
  r'\blivro\s+em\s+[áa]udio|leitura\s+completa|obra\s+completa|full\s+audiobook|unabridged',
  caseSensitive: false,
);

/// O texto tem cara de audiolivro?
bool hasAudiobookWords(String text) => _bookWords.hasMatch(text);

final _chapterWord = RegExp(r'\b(cap[ií]tulo|chapter|cap\.)\s*([0-9]+|[ivxlcdm]+\b)', caseSensitive: false);

/// Duração mínima para algo ser tratado como livro.
const audiobookMinDuration = Duration(minutes: 40);

/// Vídeo do YouTube parece audiolivro? Juntando pistas: palavras no título/descrição, duração longa e
/// capítulos com "Capítulo N". Livro vence podcast quando as palavras de livro aparecem.
bool looksLikeAudiobookVideo(Map<String, dynamic> info, {String? playlistTitle}) {
  String s(String k) => (info[k] ?? '').toString();
  final secs = (info['duration'] as num?)?.toDouble() ?? 0;
  final title = '${s('title')} ${playlistTitle ?? ''}';
  if (hasAudiobookWords(title) || hasAudiobookWords(s('channel'))) return secs == 0 || secs >= 15 * 60;
  if (secs < audiobookMinDuration.inSeconds) return false;
  // longo, sem palavra de livro no título: muitos capítulos chamados "Capítulo N" também denunciam
  final chapters = (info['chapters'] as List?) ?? const [];
  final named = chapters.where((c) => c is Map && _chapterWord.hasMatch('${c['title'] ?? ''}')).length;
  if (named >= 3) return true;
  final desc = s('description');
  return hasAudiobookWords(desc.length > 600 ? desc.substring(0, 600) : desc) && _chapterWord.allMatches(desc).length >= 3;
}

/// Título e autor adivinhados pelo título do vídeo ("Memórias Póstumas de Brás Cubas - Machado de Assis - Audiolivro
/// Completo"). Sem autor no título, fica o canal.
({String title, String author}) guessBookNames(String videoTitle, {String channel = ''}) {
  var t = videoTitle
      .replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{20E3}]', unicode: true), ' ') // 📕 🎧
      .replaceAll(RegExp(r'[\[\(【][^\]\)】]*[\]\)】]'), ' ') // (Audiolivro), [Completo]
      .replaceAll(RegExp(r'\b(livro|parte|cap[íi]tulo|tomo)\s+([ivxlc]+|\d+)\b', caseSensitive: false), ' ') // Livro I
      .replaceAll(_bookWords, ' ')
      .replaceAll(
          RegExp(r'\b(com\s+)?(voz\s+humana|narra[çc][ãa]o(\s+humana|\s+completa)?|legendas?)\b|\b(narrado|lido|na\s+voz\s+de)\s+(por\s+)?[^|\-–—]+', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\b(completo|completa|integral|parte\s*\d+|vol(ume)?\.?\s*\d+|pt-?br)\b', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s\-–—|:]+|[\s\-–—|:]+$'), '')
      .trim();
  final parts = [
    for (final x in t.split(RegExp(r'\s+[-–—|:]\s+|\s*\|\s*')))
      if (x.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '').isNotEmpty && !_isFiller(x)) x.replaceAll(RegExp(r'\s+'), ' ').trim(),
  ];
  // "de Machado de Assis" / "por Machado de Assis" no fim do título
  if (parts.length == 1) {
    final m = RegExp(r'^(.+?),?\s+(?:de|por|by)\s+([A-ZÀ-Ú][\p{L}.]+(?:\s+(?:de|da|do|dos|das|e|[A-ZÀ-Ú][\p{L}.]+))*)$', unicode: true).firstMatch(parts.first);
    if (m != null && (m.group(2)!.split(' ').length >= 2 || isKnownAuthor(m.group(2)!))) return (title: m.group(1)!.trim(), author: m.group(2)!.trim());
  }
  final ch = channel.trim().isEmpty ? unknownAuthor : channel.trim();
  if (parts.isEmpty) return (title: videoTitle.trim().isEmpty ? 'Sem título' : videoTitle.trim(), author: ch);
  if (parts.length == 1) return (title: parts.first, author: ch);
  // autor conhecido em qualquer pedaço ("Noites Brancas | Dostoiévski")
  final known = parts.indexWhere(isKnownAuthor);
  if (known >= 0) return (title: parts[known == 0 ? 1 : 0], author: parts[known]);
  // senão: título primeiro, autor depois, a menos que o primeiro tenha bem mais cara de nome de pessoa
  // ("Machado de Assis | Dom Casmurro")
  final a = parts[0], b = parts[1];
  final sa = personScore(a);
  return sa >= 1 && sa > personScore(b) ? (title: b, author: a) : (title: a, author: b);
}

const _filler = {
  'com', 'e', 'de', 'em', 'por', 'na', 'no', 'voz', 'humana', 'completo', 'completa', 'audio', 'livro', 'narrado', 'narracao',
  'integral', 'versao', 'portugues', 'brasil', 'br', 'pt', 'hd', 'full', 'parte', 'legendado', 'legendas',
};

/// Pedaço do título que é só enfeite ("com", "Versão Integral").
bool _isFiller(String s) {
  final w = normalizeText(s).split(RegExp(r'[^a-z0-9]+')).where((x) => x.isNotEmpty).toList();
  return w.isEmpty || w.every(_filler.contains);
}

/// Sobrenomes de autores com obras em domínio público que aparecem muito em audiolivros (sem acento).
const _knownAuthors = {
  'machado de assis', 'jose de alencar', 'alencar', 'aluisio azevedo', 'eca de queiros', 'eca de queiroz', 'camoes', 'lima barreto',
  'monteiro lobato', 'euclides da cunha', 'graciliano', 'olavo bilac', 'castro alves', 'alvares de azevedo', 'manuel antonio de almeida',
  'bernardo guimaraes', 'raul pompeia', 'joaquim manuel de macedo', 'franklin tavora', 'visconde de taunay', 'gil vicente', 'fernando pessoa',
  'camilo castelo branco', 'julio dinis', 'almeida garrett', 'dostoievski', 'dostoievsky', 'dostoyevsky', 'dostoevsky', 'tolstoi', 'tolstoy',
  'tchekhov', 'chekhov', 'gogol', 'turgueniev', 'pushkin', 'puchkin', 'kafka', 'shakespeare', 'dickens', 'jane austen', 'austen',
  'oscar wilde', 'wilde', 'edgar allan poe', 'poe', 'mark twain', 'twain', 'jules verne', 'julio verne', 'victor hugo', 'balzac', 'flaubert',
  'stendhal', 'dumas', 'cervantes', 'goethe', 'nietzsche', 'homero', 'platao', 'aristoteles', 'maquiavel', 'dante', 'conan doyle',
  'arthur conan doyle', 'h g wells', 'wells', 'bram stoker', 'stoker', 'mary shelley', 'lewis carroll', 'carroll', 'jack london',
  'herman melville', 'melville', 'robert louis stevenson', 'stevenson', 'kipling', 'voltaire', 'rousseau', 'zola', 'lovecraft',
  'george orwell', 'orwell', 'agatha christie', 'fitzgerald', 'sun tzu', 'marco aurelio', 'seneca', 'epicteto', 'joseph conrad', 'virginia woolf', 'woolf', 'charlotte bronte', 'emily bronte',
};

/// O texto é (ou tem) o nome de um autor conhecido? "Dostoiévski", "Fiódor Dostoiévski", "Machado de Assis".
bool isKnownAuthor(String s) {
  final n = normalizeText(s).replaceAll(RegExp(r'[^a-z ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (n.isEmpty || n.split(' ').length > 5) return false;
  for (final k in _knownAuthors) {
    if (n == k || n.endsWith(' $k') || (k.contains(' ') && n.contains(k))) return true;
  }
  return false;
}

const _connectors = {'de', 'da', 'do', 'dos', 'das', 'e', 'van', 'von', 'del'};
const _articles = {'o', 'a', 'os', 'as', 'um', 'uma', 'the', 'el', 'la', 'le', 'les'};

/// Quanto um texto parece nome de pessoa: palavras com maiúscula ligadas por "de/da/dos", de 2 a 4 palavras,
/// sem artigo no começo (título de livro costuma começar com "O", "A"...).
@visibleForTesting
double personScore(String s) {
  final w = s.trim().split(RegExp(r'\s+'));
  if (w.length < 2 || w.length > 6) return -1;
  if (_articles.contains(w.first.toLowerCase())) return -1;
  final names = w.where((x) => !_connectors.contains(x.toLowerCase())).toList();
  bool cap(String x) => x.isNotEmpty && x[0] != x[0].toLowerCase();
  if (!names.every(cap)) return -1;
  var score = 0.0;
  if (names.length != w.length) score += 1; // "de", "da"... entre nomes
  if (w.length <= 4) score += .5;
  if (RegExp(r'^[A-Z]\.').hasMatch(w.first)) score += 1; // "J. K. Rowling"
  return score;
}

// ---------------------------------------------------------------------------
// Capítulos (um arquivo só, com marcas de tempo)

/// De onde vieram os capítulos (aparece nas Propriedades do livro).
enum ChapterSource {
  none('sem capítulos'),
  youtube('capítulos do vídeo'),
  description('marcas de tempo da descrição'),
  captions('"capítulo N" na legenda'),
  ai('marcados pelo Gemini'),
  manual('ajustados à mão');

  final String label;
  const ChapterSource(this.label);
}

/// 1) Capítulos que o próprio vídeo tem (o YouTube monta a partir da descrição).
List<Chapter> chaptersFromYoutube(Map<String, dynamic> info) {
  final out = <Chapter>[];
  for (final c in (info['chapters'] as List?) ?? const []) {
    if (c is! Map) continue;
    final start = (c['start_time'] as num?)?.toDouble() ?? 0;
    out.add(Chapter(startMs: (start * 1000).round(), title: '${c['title'] ?? ''}'.trim()));
  }
  return _clean(out);
}

final _stamp = RegExp(r'(?<![\d:])(\d{1,2}:)?(\d{1,2}):(\d{2})(?![\d:])');

/// 2) Marcas de tempo escritas na descrição ("0:00 Ao leitor", "1:12:30 - Capítulo 7", "Cap. 2 (6:40)").
List<Chapter> chaptersFromDescription(String description) {
  final out = <Chapter>[];
  for (final raw in description.split('\n')) {
    final line = raw.trim();
    final m = _stamp.firstMatch(line);
    if (m == null) continue;
    final h = int.tryParse((m.group(1) ?? '0:').replaceAll(':', '')) ?? 0;
    final ms = ((h * 60 + int.parse(m.group(2)!)) * 60 + int.parse(m.group(3)!)) * 1000;
    final title = (line.substring(0, m.start) + line.substring(m.end))
        .replaceAll(RegExp(r'^[\s\-–—:|•·()\[\]]+|[\s\-–—:|•·()\[\]]+$'), '')
        .trim();
    out.add(Chapter(startMs: ms, title: title.isEmpty ? 'Parte ${out.length + 1}' : title));
  }
  final c = _clean(out);
  return c.length >= 3 ? c : const [];
}

const _numberWords = {
  'um': 1, 'primeiro': 1, 'dois': 2, 'segundo': 2, 'tres': 3, 'terceiro': 3, 'quatro': 4, 'quarto': 4, 'cinco': 5, 'quinto': 5,
  'seis': 6, 'sexto': 6, 'sete': 7, 'setimo': 7, 'oito': 8, 'oitavo': 8, 'nove': 9, 'nono': 9, 'dez': 10, 'decimo': 10,
  'onze': 11, 'doze': 12, 'treze': 13, 'catorze': 14, 'quatorze': 14, 'quinze': 15, 'dezesseis': 16, 'dezessete': 17,
  'dezoito': 18, 'dezenove': 19, 'vinte': 20, 'trinta': 30, 'quarenta': 40, 'cinquenta': 50,
};

/// Número de um capítulo escrito de qualquer jeito: "7", "VII", "sete", "vinte e um". Null = não é número.
int? chapterNumber(String word) {
  final w = normalizeText(word).trim();
  if (w.isEmpty) return null;
  final n = int.tryParse(w);
  if (n != null) return n;
  final r = romanToInt(w);
  if (r != null) return r;
  var total = 0;
  for (final part in w.split(RegExp(r'\s+e\s+|\s+'))) {
    final v = _numberWords[part];
    if (v == null) return null;
    total += v;
  }
  return total == 0 ? null : total;
}

/// "vii" -> 7. Null se não for romano válido.
int? romanToInt(String s) {
  const v = {'i': 1, 'v': 5, 'x': 10, 'l': 50, 'c': 100, 'd': 500, 'm': 1000};
  final t = s.toLowerCase();
  if (t.isEmpty || !RegExp(r'^[ivxlcdm]+$').hasMatch(t)) return null;
  var total = 0;
  for (var i = 0; i < t.length; i++) {
    final cur = v[t[i]]!, next = i + 1 < t.length ? v[t[i + 1]]! : 0;
    total += cur < next ? -cur : cur;
  }
  return total > 0 && total < 400 ? total : null;
}

final _spokenChapter = RegExp(
  r'\bcap[ií]tulo\s+((?:\d+)|(?:[ivxlc]+)\b|(?:(?:vinte|trinta|quarenta|cinquenta)(?:\s+e\s+\w+)?)|\w+)',
  caseSensitive: false,
);

/// 3) "Capítulo 1", "capítulo dois"... falado na legenda automática, já com o tempo certo.
/// Fica só a primeira vez de cada número, em ordem crescente (o narrador às vezes cita outro capítulo no meio).
List<Chapter> chaptersFromCaptions(List<(int, String)> segs) {
  final out = <Chapter>[];
  var last = 0;
  for (final (ms, text) in segs) {
    for (final m in _spokenChapter.allMatches(text)) {
      final n = chapterNumber(m.group(1)!);
      if (n == null || n <= last || n > last + 3) continue; // pulo grande = citação, não começo de capítulo
      last = n;
      out.add(Chapter(startMs: ms, title: 'Capítulo $n'));
    }
  }
  final c = _clean(out);
  return c.length >= 3 ? c : const [];
}

/// Pedido para o Gemini achar onde cada capítulo começa (só quando os outros jeitos falharam).
String chapterPrompt({required String title, required String author, required String transcript}) => '''
Você recebe a transcrição automática (com marcas [h:mm:ss] a cada minuto) de um audiolivro inteiro num vídeo só.
Livro: "$title", de $author.
Ache onde começa cada capítulo (ou parte) do livro. Responda só com JSON, assim:
{"capitulos": [{"inicio_s": 0, "titulo": "Capítulo 1 — Título do capítulo, se houver"}]}
Use segundos a partir do começo do vídeo. Inclua a introdução/prefácio se houver. Em ordem crescente.

Transcrição:
$transcript
''';

/// Lê a resposta do Gemini ([chapterPrompt]).
List<Chapter> chaptersFromAi(Map<String, dynamic> ai) {
  final out = <Chapter>[];
  for (final c in (ai['capitulos'] as List?) ?? const []) {
    if (c is! Map) continue;
    final s = (c['inicio_s'] as num?)?.toDouble();
    if (s == null) continue;
    out.add(Chapter(startMs: (s * 1000).round(), title: '${c['titulo'] ?? ''}'.trim()));
  }
  return _clean(out);
}

/// Ordena, tira repetidos e capítulos colados (menos de 20 s entre um e outro).
List<Chapter> _clean(List<Chapter> list) {
  final sorted = [...list]..sort((a, b) => a.startMs.compareTo(b.startMs));
  final out = <Chapter>[];
  for (final c in sorted) {
    if (out.isNotEmpty && c.startMs - out.last.startMs < 20000) continue;
    out.add(c);
  }
  // primeiro capítulo começando bem depois do zero: o pedaço antes vira "Introdução"
  if (out.isNotEmpty && out.first.startMs > 60000) out.insert(0, const Chapter(startMs: 0, title: 'Introdução'));
  return out;
}

/// Acha os capítulos na ordem combinada: vídeo → descrição → legenda. (O Gemini é o último, fora daqui.)
(List<Chapter>, ChapterSource) detectChapters(Map<String, dynamic> info, {List<(int, String)> captions = const []}) {
  final yt = chaptersFromYoutube(info);
  if (yt.length >= 2) return (yt, ChapterSource.youtube);
  final desc = chaptersFromDescription('${info['description'] ?? ''}');
  if (desc.isNotEmpty) return (desc, ChapterSource.description);
  final cap = chaptersFromCaptions(captions);
  if (cap.isNotEmpty) return (cap, ChapterSource.captions);
  return (const [], ChapterSource.none);
}

/// Texto da transcrição para o [chapterPrompt].
String bookTranscript(List<(int, String)> captions) => transcriptText(captions, maxChars: 500000);

/// Legenda json3 lida.
List<(int, String)> parseCaptions(String body) => parseJson3(body);

// ---------------------------------------------------------------------------
// Informações do livro (arquivo .livro.json ao lado do áudio)

/// Situação do texto da obra.
enum TextStatus {
  none(''),
  searching('procurando o texto…'),
  ok('texto da obra pronto'),
  notFound('texto não encontrado (domínio público)'),
  failed('não deu para baixar o texto');

  final String label;
  const TextStatus(this.label);
}

class BookInfo {
  final String videoId;
  final String url;
  final String title;
  final String author;
  final List<Chapter> chapters;
  final ChapterSource chapterSource;

  /// De onde veio o texto ("Projeto Gutenberg #54829", "Wikisource", "EPUB anexado").
  final String textSource;
  final TextStatus textStatus;

  /// Ilustração escolhida para cada capítulo do áudio (índice -> nome do arquivo na pasta de ilustrações).
  final Map<int, String> art;

  /// Crédito de cada ilustração (índice -> "Arquivo · autor · licença").
  final Map<int, String> artCredit;

  /// As ilustrações já foram procuradas (para não repetir o pedido à IA toda vez).
  final bool artDone;

  /// Língua da narração (do YouTube: "pt", "en"...). O texto livre só vale direto se for nessa língua.
  final String language;

  /// Versão da busca do texto que já rodou (busca nova → tenta de novo os livros sem texto ou com texto em outra língua).
  final int searchVersion;

  const BookInfo({
    this.videoId = '',
    this.url = '',
    this.title = '',
    this.author = '',
    this.chapters = const [],
    this.chapterSource = ChapterSource.none,
    this.textSource = '',
    this.textStatus = TextStatus.none,
    this.art = const {},
    this.artCredit = const {},
    this.artDone = false,
    this.language = '',
    this.searchVersion = 0,
  });

  /// Índice do capítulo tocando em [pos] (-1 = sem capítulos).
  int chapterIndexAt(Duration pos) {
    var cur = -1;
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].startMs <= pos.inMilliseconds) {
        cur = i;
      } else {
        break;
      }
    }
    return chapters.isEmpty ? -1 : (cur < 0 ? 0 : cur);
  }

  /// Fim do capítulo [i] (começo do próximo, ou o fim do livro).
  int chapterEndMs(int i, int totalMs) => i + 1 < chapters.length ? chapters[i + 1].startMs : totalMs;

  BookInfo copyWith({
    String? title,
    String? author,
    List<Chapter>? chapters,
    ChapterSource? chapterSource,
    String? textSource,
    TextStatus? textStatus,
    Map<int, String>? art,
    Map<int, String>? artCredit,
    bool? artDone,
    String? language,
    int? searchVersion,
  }) =>
      BookInfo(
        videoId: videoId,
        url: url,
        title: title ?? this.title,
        author: author ?? this.author,
        chapters: chapters ?? this.chapters,
        chapterSource: chapterSource ?? this.chapterSource,
        textSource: textSource ?? this.textSource,
        textStatus: textStatus ?? this.textStatus,
        art: art ?? this.art,
        artCredit: artCredit ?? this.artCredit,
        artDone: artDone ?? this.artDone,
        language: language ?? this.language,
        searchVersion: searchVersion ?? this.searchVersion,
      );

  Map<String, Object?> toJson() => {
        'versao': 1,
        'id': videoId,
        'url': url,
        'titulo': title,
        'autor': author,
        'capitulos': [for (final c in chapters) c.toJson()],
        'capitulosDe': chapterSource.name,
        'textoDe': textSource,
        'texto': textStatus.name,
        'ilustracoes': {for (final e in art.entries) '${e.key}': e.value},
        'creditos': {for (final e in artCredit.entries) '${e.key}': e.value},
        'ilustracoesFeitas': artDone,
        'lingua': language,
        'busca': searchVersion,
      };

  static BookInfo fromJson(Map<String, dynamic> m) {
    Map<int, String> ints(Object? v) => {
          for (final e in ((v as Map?) ?? const {}).entries)
            if (int.tryParse('${e.key}') != null) int.parse('${e.key}'): '${e.value}',
        };
    return BookInfo(
      videoId: '${m['id'] ?? ''}',
      url: '${m['url'] ?? ''}',
      title: '${m['titulo'] ?? ''}',
      author: '${m['autor'] ?? ''}',
      chapters: [for (final c in (m['capitulos'] as List?) ?? const []) Chapter.fromJson((c as Map).cast<String, dynamic>())],
      chapterSource: ChapterSource.values.asNameMap()[m['capitulosDe']] ?? ChapterSource.none,
      textSource: '${m['textoDe'] ?? ''}',
      textStatus: TextStatus.values.asNameMap()[m['texto']] ?? TextStatus.none,
      art: ints(m['ilustracoes']),
      artCredit: ints(m['creditos']),
      artDone: m['ilustracoesFeitas'] == true,
      language: '${m['lingua'] ?? ''}',
      searchVersion: (m['busca'] as num?)?.toInt() ?? 0,
    );
  }

  static BookInfo? read(String audioPath) {
    try {
      final f = File(bookInfoPath(audioPath));
      if (!f.existsSync()) return null;
      return fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (e) {
      errorLog.info('Audiolivros', 'Arquivo de informações do livro ilegível', e);
      return null;
    }
  }
}

/// Um livro na Biblioteca: o arquivo e o que se sabe dele.
class Audiobook {
  final Track track;
  final BookInfo? info;
  const Audiobook(this.track, this.info);
  String get title => (info?.title ?? '').isNotEmpty ? info!.title : (track.album.isNotEmpty && track.album != unknownAlbum ? track.album : track.title);
  String get author => (info?.author ?? '').isNotEmpty ? info!.author : (track.artist == unknownArtist ? unknownAuthor : track.artist);
  List<Chapter> get chapters => info?.chapters ?? const [];
}

/// Autores e seus livros, em ordem alfabética.
List<(String, List<Audiobook>)> groupByAuthor(List<Audiobook> books) {
  final by = <String, List<Audiobook>>{};
  for (final b in books) {
    by.putIfAbsent(b.author, () => []).add(b);
  }
  final out = [for (final e in by.entries) (e.key, e.value..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())))];
  out.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
  return out;
}

/// Grafias do sobrenome em outras línguas (o Projeto Gutenberg usa a inglesa: "Dostoyevsky, Fyodor").
const _surnameSpellings = {
  'dostoievski': ['dostoyevsky', 'dostoevsky', 'dostoievsky'],
  'dostoiewski': ['dostoyevsky', 'dostoevsky'],
  'dostoyevsky': ['dostoevsky', 'dostoievski'],
  'tolstoi': ['tolstoy'],
  'tolstoy': ['tolstoi'],
  'tchekhov': ['chekhov', 'tchekoff'],
  'tchekov': ['chekhov'],
  'checov': ['chekhov'],
  'turgueniev': ['turgenev'],
  'turgeniev': ['turgenev'],
  'puchkin': ['pushkin'],
  'puskin': ['pushkin'],
  'gorki': ['gorky'],
  'gogol': ['gogol'],
  'lermontov': ['lermontov'],
  'goncharov': ['goncharov'],
  'kafka': ['kafka'],
  'dante': ['alighieri'],
  'alighieri': ['dante'],
  'homero': ['homer'],
  'cervantes': ['cervantes saavedra'],
  'verne': ['verne'],
  'goethe': ['goethe'],
};

/// Sobrenome do autor e as outras grafias dele (normalizados, sem acento). "Fiódor Dostoiévski" → [dostoievski, dostoyevsky, ...]
List<String> surnameVariants(String author) {
  final w = normalizeText(author).replaceAll(RegExp(r'[^a-z ]'), ' ').split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (w.isEmpty) return const [];
  final last = w.last;
  return {last, ...?_surnameSpellings[last]}.toList();
}
