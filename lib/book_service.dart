import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'audiobooks.dart';
import 'book_text.dart';
import 'error_log.dart';
import 'library_search.dart' show normalizeText;
import 'podcast_info.dart' show Chapter, GeminiClient, GeminiException, captionUrl;

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

  /// Informações completas do vídeo (yt-dlp -J), para pegar a legenda de um livro baixado antes.
  Future<Map<String, dynamic>> Function(String url)? fetchInfo;

  BookService({required this.client, required this.geminiKey, bool Function()? allowNet, bool Function()? allowAi, this.fetchInfo})
      : allowNet = allowNet ?? (() => true),
        allowAi = allowAi ?? (() => true);

  /// Busca do texto atual: livros procurados por uma busca mais velha (sem texto, ou com texto em outra
  /// língua) tentam de novo sozinhos. 2 = transcrição do vídeo.
  /// 3 = transcrição do vídeo é o padrão (com o tempo de cada palavra, para o destaque da frase).
  static const searchVersion = 3;

  /// Legenda lida na hora do download (por id do vídeo), para o texto pela transcrição não baixar de novo.
  final Map<String, String> _captionCache = {};
  final Map<String, Uri> _captionUrlCache = {};
  final Set<String> _polishing = {};

  /// Pedaços da transcrição já arrumados / total (para mostrar o andamento).
  final Map<String, (int, int)> _progress = {};
  (int, int)? polishProgress(String path) => _progress[path];

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
    for (final (a, b) in [(bookInfoPath(from), bookInfoPath(to)), (bookTextPath(from), bookTextPath(to)), (transcriptPath(from), transcriptPath(to))]) {
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
    final fixed = info.copyWith(chapters: list, chapterSource: ChapterSource.manual);
    await save(path, fixed);
    await _rebuildFromTranscript(path, fixed); // texto da transcrição: capítulos do texto seguem os do áudio
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
      language: '${yt['language'] ?? ''}'.split('-').first.toLowerCase(),
    );
    final capUrl = captionUrl(yt);
    if (capUrl != null && id.isNotEmpty) _captionUrlCache[id] = capUrl;
    var (chapters, source) = detectChapters(yt);
    if (chapters.isNotEmpty) return info.copyWith(chapters: chapters, chapterSource: source);
    // legenda automática: procura "capítulo N" falado
    var captions = const <(int, String)>[];
    try {
      final url = captionUrl(yt);
      if (url != null) {
        final r = await client.get(url).timeout(const Duration(seconds: 40));
        if (r.statusCode == 200) {
          final body = utf8.decode(r.bodyBytes, allowMalformed: true);
          captions = parseCaptions(body);
          if (captions.isNotEmpty && id.isNotEmpty) _captionCache[id] = body;
        }
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

  /// Procura o texto do livro (sozinho, depois do download, ou pelo menu do texto), nesta ordem:
  /// 1. a transcrição do próprio vídeo (legenda automática, com o tempo de cada palavra; o Gemini arruma a
  ///    pontuação aos poucos) — o padrão, porque segue a narração frase por frase;
  /// 2. texto livre na língua da narração (Gutenberg/Wikisource);
  /// 3. texto livre em outra língua (inglês, quase sempre).
  /// [book]: "Usar o texto do livro" no menu: só 2 e 3; sem achar, fica o texto que já tinha.
  /// [manual]: pedido por você (vale mesmo com a busca automática desligada na aba Internet).
  Future<TextStatus> fetchText(String path, {bool manual = false, bool book = false}) async {
    final info = infoFor(path) ?? const BookInfo();
    if (!manual && (!allowNet() || (info.textStatus == TextStatus.notFound && info.searchVersion >= searchVersion))) return info.textStatus;
    if (!_working.add(path)) return TextStatus.searching;
    await save(path, info.copyWith(textStatus: TextStatus.searching));
    try {
      final title = info.title, author = info.author;
      if (!book && await _fromTranscript(path, info)) return TextStatus.ok;
      final lang = info.language.isEmpty ? 'pt' : info.language;
      var found = title.trim().isEmpty ? null : await _findEpub(title, author, lang: lang);
      found ??= title.trim().isEmpty ? null : await _findEpub(title, author);
      if (found == null) {
        if (book && info.textStatus == TextStatus.ok) {
          await save(path, info); // fica o texto de antes
          return TextStatus.notFound;
        }
        await save(path, info.copyWith(textStatus: TextStatus.notFound, searchVersion: searchVersion));
        return TextStatus.notFound;
      }
      final text = await Isolate.run(() => parseEpub(found!.$1));
      await text.save(path);
      _text[path] = text;
      _deleteTranscript(path);
      await save(path, info.copyWith(textStatus: TextStatus.ok, textSource: found.$2, searchVersion: searchVersion));
      unawaited(fetchArt(path));
      return TextStatus.ok;
    } catch (e) {
      errorLog.add(ErrorLog.isNetwork(e) ? LogLevel.info : LogLevel.warning, 'Audiolivros', 'Não deu para baixar o texto de "${info.title}"', error: e);
      await save(path, info.copyWith(textStatus: info.textStatus == TextStatus.ok ? TextStatus.ok : TextStatus.failed));
      return TextStatus.failed;
    } finally {
      _working.remove(path);
      notifyListeners();
    }
  }

  static bool _isFreeText(String source) => source.startsWith('Projeto Gutenberg') || source.startsWith('Wikisource');

  /// Vale procurar o texto de novo sozinho? (busca nunca feita, falhou, ou feita por uma versão mais velha:
  /// sem texto, com texto em outra língua, ou com o texto do livro quando agora o padrão é a transcrição)
  bool shouldSearchText(BookInfo info) =>
      info.textStatus == TextStatus.none ||
      info.textStatus == TextStatus.failed ||
      info.textStatus == TextStatus.searching ||
      (info.searchVersion < searchVersion &&
          (info.textStatus == TextStatus.notFound ||
              (info.textStatus == TextStatus.ok && (info.textSource.contains('(em ') || (_isFreeText(info.textSource) && info.videoId.isNotEmpty)))));

  // ---------------------------------------------------------------------------
  // Texto pela transcrição do vídeo

  static const transcriptSource = 'Transcrição do vídeo (legenda automática)';

  /// Monta o texto pela legenda do vídeo. Falso se o vídeo não tem legenda que dê para ler.
  Future<bool> _fromTranscript(String path, BookInfo info) async {
    final cap = await _captions(info);
    if (cap.segs.length < 30) return false;
    final tr = Transcript(cap.segs, offsets: cap.offsets);
    await tr.save(path);
    _progress[path] = (0, tr.chunks);
    final fresh = (infoFor(path) ?? info).copyWith(textStatus: TextStatus.ok, textSource: transcriptSource, searchVersion: searchVersion);
    final text = tr.toBook(title: fresh.title, author: fresh.author, audio: fresh.chapters);
    await text.save(path);
    _text[path] = text;
    await save(path, fresh);
    unawaited(polish(path));
    unawaited(fetchArt(path));
    return true;
  }

  /// Transcrição guardada antes do destaque da frase (sem o tempo de cada palavra)?
  bool needsWordTimes(String path) {
    final info = infoFor(path);
    if (info == null || info.textSource != transcriptSource || info.searchVersion >= searchVersion) return false;
    final tr = Transcript.read(path);
    return tr != null && !tr.hasWordTimes;
  }

  /// Busca de novo a legenda só para ganhar o tempo de cada palavra, sem perder o que o Gemini já arrumou.
  Future<void> addWordTimes(String path) async {
    final info = infoFor(path);
    if (info == null || !_working.add(path)) return;
    try {
      final cap = await _captions(info);
      final old = Transcript.read(path);
      if (old == null || cap.segs.isEmpty) return;
      final same = cap.segs.length == old.segs.length && cap.segs.first.$1 == old.segs.first.$1;
      // legenda mudou no YouTube: recomeça a transcrição (o Gemini arruma de novo)
      final tr = same ? Transcript(old.segs, polished: old.polished, done: old.done, offsets: cap.offsets) : Transcript(cap.segs, offsets: cap.offsets);
      await tr.save(path);
      _progress[path] = (tr.done, tr.chunks);
      final text = tr.toBook(title: info.title, author: info.author, audio: info.chapters);
      await text.save(path);
      _text[path] = text;
      await save(path, info.copyWith(searchVersion: searchVersion));
      if (!tr.finished) unawaited(polish(path));
    } catch (e) {
      errorLog.info('Audiolivros', 'Não deu para buscar os tempos das palavras de "${info.title}"', e);
    } finally {
      _working.remove(path);
      notifyListeners();
    }
  }

  /// Legenda do vídeo com o tempo de cada palavra: a lida no download, ou pede de novo ao YouTube
  /// (o endereço da legenda vence em horas).
  Future<({List<(int, String)> segs, List<List<int>> offsets})> _captions(BookInfo info) async {
    const none = (segs: <(int, String)>[], offsets: <List<int>>[]);
    final cached = _captionCache.remove(info.videoId);
    if (cached != null) return parseJson3Words(cached);
    final fetch = fetchInfo;
    final url = info.url.isNotEmpty ? info.url : (info.videoId.isEmpty ? '' : 'https://www.youtube.com/watch?v=${info.videoId}');
    try {
      // endereço guardado no download (vale por algumas horas); senão pergunta de novo ao YouTube
      final capUrl = _captionUrlCache.remove(info.videoId) ?? (fetch == null || url.isEmpty ? null : captionUrl(await fetch(url)));
      if (capUrl == null) return none;
      final r = await client.get(capUrl, headers: _ua).timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) return none;
      return parseJson3Words(utf8.decode(r.bodyBytes, allowMalformed: true));
    } catch (e) {
      errorLog.info('Audiolivros', 'Não deu para ler a legenda do vídeo de "${info.title}"', e);
      return none;
    }
  }

  /// Ainda tem pedaço da transcrição para o Gemini arrumar?
  bool needsPolish(String path) {
    final info = infoFor(path);
    if (info == null || info.textSource != transcriptSource) return false;
    final tr = Transcript.read(path);
    if (tr != null) _progress[path] = (tr.done, tr.chunks);
    return tr != null && !tr.finished;
  }

  /// O Gemini arruma a transcrição pedaço por pedaço (~12 min de leitura cada), mantendo os tempos.
  /// Cada pedaço pronto já aparece no leitor. Parou (sem internet, limite do dia)? Continua na próxima vez.
  Future<void> polish(String path) async {
    final key = geminiKey().trim();
    if (key.isEmpty || !allowAi() || !_polishing.add(path)) return;
    try {
      var tr = await Isolate.run(() => Transcript.read(path));
      while (tr != null && !tr.finished) {
        final info = infoFor(path);
        if (info == null || info.textSource != transcriptSource || !allowAi()) return;
        final from = tr.done * Transcript.chunk;
        final segs = tr.segs.sublist(from, (from + Transcript.chunk).clamp(0, tr.segs.length));
        List<(int, String)>? pars;
        for (var attempt = 0; attempt < 2 && pars == null; attempt++) {
          try {
            final ai = await GeminiClient(client, key).generateJson(polishPrompt(title: info.title, author: info.author, segs: segs, firstIndex: from));
            pars = polishedFromAi(ai, segs, from);
          } on GeminiException catch (e) {
            // limite, sem internet ou demora: para e continua depois. Recusa/resposta vazia (o Gemini às vezes
            // recusa repetir texto de livro): conta como resposta ruim desse pedaço.
            if (e.quota || e.message.contains('conexão') || e.message.contains('demorou') || e.message.contains('inválida') || e.message.contains('respondeu 5')) rethrow;
          }
        }
        // duas respostas ruins: esse pedaço fica como estava (pelas pausas) e segue para o próximo
        pars ??= roughParagraphs(segs);
        tr = tr.copyWith(polished: [...tr.polished, ...pars], done: tr.done + 1);
        await tr.save(path);
        _progress[path] = (tr.done, tr.chunks);
        final text = tr.toBook(title: info.title, author: info.author, audio: info.chapters);
        await text.save(path);
        _text[path] = text;
        notifyListeners();
        if (!tr.finished) await Future<void>.delayed(const Duration(seconds: 4)); // sem estourar o limite por minuto
      }
    } on GeminiException catch (e) {
      errorLog.info('Audiolivros', e.quota ? 'Limite do Gemini: a arrumação do texto continua depois' : 'O Gemini não arrumou o texto agora', e);
    } catch (e) {
      errorLog.info('Audiolivros', 'A arrumação do texto parou (continua depois)', e);
    } finally {
      _polishing.remove(path);
    }
  }

  Future<void> _rebuildFromTranscript(String path, BookInfo info) async {
    if (info.textSource != transcriptSource) return;
    final tr = Transcript.read(path);
    if (tr == null) return;
    final text = tr.toBook(title: info.title, author: info.author, audio: info.chapters);
    await text.save(path);
    _text[path] = text;
    notifyListeners();
  }

  /// O livro foi apagado: leva junto informações, texto, transcrição e ilustrações.
  void deleteFiles(String path) {
    for (final f in [bookInfoPath(path), bookTextPath(path), transcriptPath(path)]) {
      try {
        if (File(f).existsSync()) File(f).deleteSync();
      } catch (_) {}
    }
    try {
      final d = Directory(bookArtDir(path));
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
    _info.remove(path);
    _text.remove(path);
    _progress.remove(path);
  }

  void _deleteTranscript(String path) {
    _progress.remove(path);
    try {
      final f = File(transcriptPath(path));
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Usa um EPUB escolhido no celular.
  Future<void> attachEpub(String path, String epubPath) async {
    final bytes = await File(epubPath).readAsBytes();
    final text = await Isolate.run(() => parseEpub(bytes));
    await text.save(path);
    _text[path] = text;
    _deleteTranscript(path);
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
    _deleteTranscript(path);
    _text[path] = null;
    final info = infoFor(path) ?? const BookInfo();
    await save(path, info.copyWith(textStatus: TextStatus.none, textSource: ''));
  }

  /// Gutenberg (EPUB pronto, sem imagens) → Wikisource (EPUB gerado pelo ws-export). (bytes, de onde veio)
  /// [lang]: só texto nessa língua. Sem [lang]: qualquer língua; se não achar pelo nome em português, o Gemini diz
  /// o nome da obra em inglês (e o autor na grafia do Gutenberg) e tenta de novo.
  Future<(Uint8List, String)?> _findEpub(String title, String author, {String? lang}) async {
    if (lang != null) {
      return await _gutenberg(title, author, lang: lang) ?? await _wikisource(title, author, lang);
    }
    final g = await _gutenberg(title, author);
    if (g != null) return g;
    final w = await _wikisource(title, author, 'en');
    if (w != null) return w;
    final other = await _identify(title, author);
    if (other == null) return null;
    return await _gutenberg(other.title, other.author) ?? await _wikisource(other.title, other.author, 'en');
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

  Future<(Uint8List, String)?> _gutenberg(String title, String author, {String? lang}) async {
    try {
      // o autor em várias grafias ("Dostoiévski" → dostoyevsky, dostoevsky) e, por último, só o título
      final queries = <String>{for (final v in surnameVariants(author).take(3)) '$title $v', title};
      for (final q in queries) {
        final r = await client.get(Uri.https('gutendex.com', '/books', {'search': q.trim()}), headers: _ua).timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) continue;
        final best = pickGutenberg(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>, title, author, lang: lang);
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
  static ({int id, String lang})? pickGutenberg(Map<String, dynamic> json, String title, String author, {String? lang}) {
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
      if (lang != null && !langs.contains(lang)) continue;
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

  /// Ilustrações v2: pinturas da época/país da obra e pranchas das cenas fortes.
  static const artVersion = 2;

  /// Primeira chave das pranchas (as de capítulo usam o número do capítulo).
  static const sceneBase = 1000;

  /// Uma prancha a cada ~10 min de leitura, com o que sobrar do teto depois das ilustrações dos capítulos.
  @visibleForTesting
  static List<int> sceneTimes({required int totalMs, required int chapterArt}) {
    final room = maxArt - chapterArt;
    final count = math.min(room, totalMs ~/ 600000);
    if (count <= 0) return const [];
    return [for (var k = 0; k < count; k++) ((k + .5) * totalMs / count).round()];
  }

  /// Pedido para o Gemini: uma cena e uma busca (em inglês, para o Wikimedia Commons) por capítulo ou trecho.
  static String artPrompt(String title, String author, List<(int, String, String)> chapters) => """
Livro de domínio público: "$title", de $author.
Para cada item abaixo (capítulo ou trecho), escolha UMA cena marcante e escreva uma busca curta EM INGLÊS para achar
uma PINTURA antiga (óleo, aquarela; domínio público) no Wikimedia Commons, de preferência da mesma época e do mesmo
país da obra (ex.: para Dostoiévski, "19th century Russian painting ..."). Prefira coisas concretas (lugar, paisagem,
tipo de pessoa, momento do dia).
Responda só com JSON: {"cenas": [{"i": 0, "cena": "nome curto da cena em português", "busca": "19th century Russian painting white night river embankment"}]}

Itens (i: título — texto):
${chapters.map((c) => '${c.$1}: ${c.$2} — ${c.$3}').join('\n')}
""";

  /// Texto perto de [ms] (para o Gemini escolher a cena daquele trecho).
  static String excerptAt(BookText text, int ms, {int max = 350}) {
    final at = sentenceAt(text, ms);
    if (at == null) return '';
    final ch = text.chapters[at.chapter];
    final s = ch.paragraphs.skip(at.para).take(2).join(' ');
    return s.length > max ? s.substring(0, max) : s;
  }

  /// Busca as ilustrações que faltam (uma vez por livro; respeita a aba Internet e o teto de [maxArt]):
  /// uma por capítulo e, no texto da transcrição, pranchas das cenas fortes a cada ~10 min.
  Future<void> fetchArt(String path, {bool manual = false}) async {
    var info = infoFor(path);
    if (info == null || (!manual && ((info.artDone && info.artVersion >= artVersion) || !allowNet()))) return;
    if (!_working.add('$path#art')) return;
    try {
      final text = await loadText(path);
      final n = info.chapters.isNotEmpty ? info.chapters.length : (text?.chapters.length ?? 0);
      if (n == 0) return;
      final slots = [for (final i in artSlots(n)) if (!info.art.containsKey(i)) i];
      final match = text == null ? const <int>[] : matchChapters(info.chapters, text.chapters);
      String opening(int i) {
        if (text == null) return '';
        final t = info!.chapters.isEmpty ? i : (i < match.length ? match[i] : -1);
        if (t < 0 || t >= text.chapters.length) return '';
        final s = text.chapters[t].paragraphs.take(3).join(' ');
        return s.length > 350 ? s.substring(0, 350) : s;
      }

      String titleOf(int i) => info!.chapters.isNotEmpty ? info.chapters[i].title : (text?.chapters[i].title ?? 'Capítulo ${i + 1}');
      // pranchas: só no texto com tempos (transcrição), onde dá para pôr a cena no lugar certo
      final total = text != null && text.timed && text.chapters.isNotEmpty
          ? [for (final c in text.chapters) if (c.times.isNotEmpty) c.times.last].fold(0, math.max) + 60000
          : 0;
      final sceneMs = info.scenes.isNotEmpty || total == 0 ? const <int>[] : sceneTimes(totalMs: total, chapterArt: artSlots(n).length);
      final items = <(int, String, String)>[
        for (final i in slots) (i, titleOf(i), opening(i)),
        for (var k = 0; k < sceneMs.length; k++) (sceneBase + k, 'Trecho aos ${sceneMs[k] ~/ 60000} min', excerptAt(text!, sceneMs[k])),
      ];
      final queries = <int, String>{}, names = <int, String>{};
      final key = geminiKey().trim();
      if (items.isNotEmpty && key.isNotEmpty && allowAi()) {
        try {
          final ai = await GeminiClient(client, key).generateJson(artPrompt(info.title, info.author, items));
          for (final c in (ai['cenas'] as List?) ?? const []) {
            if (c is! Map || c['i'] is! num || '${c['busca'] ?? ''}'.trim().isEmpty) continue;
            final i = (c['i'] as num).toInt();
            queries[i] = '${c['busca']}'.trim();
            names[i] = '${c['cena'] ?? ''}'.trim();
          }
        } catch (e) {
          errorLog.info('Audiolivros', 'O Gemini não escolheu as cenas de "${info.title}"', e);
        }
      }
      // sem IA: ilustrações da própria obra/autor espalhadas pelos capítulos
      if (queries.isEmpty && info.art.isEmpty) {
        final generic = '${info.title} ${info.author}'.trim();
        for (final i in slots.take(6)) {
          queries[i] = generic;
        }
      }
      final dir = Directory(bookArtDir(path));
      await dir.create(recursive: true);
      final art = {...info.art}, credit = {...info.artCredit};
      final scenes = {...info.scenes};
      final used = <String>{...art.values};
      for (final e in queries.entries) {
        if (art.containsKey(e.key) || art.length >= maxArt) continue;
        final img = await _commonsImage(e.value, skip: used);
        if (img == null) continue;
        try {
          final r = await client.get(Uri.parse(img.url), headers: _ua).timeout(const Duration(seconds: 40));
          if (r.statusCode != 200 || r.bodyBytes.length < 2000) continue;
          final scene = e.key >= sceneBase;
          final name = '${scene ? 'cena' : 'cap'}_${e.key}${img.ext}';
          await File(p.join(dir.path, name)).writeAsBytes(r.bodyBytes);
          art[e.key] = name;
          credit[e.key] = img.credit;
          used.add(img.id);
          if (scene) scenes[e.key] = (sceneMs[e.key - sceneBase], names[e.key]?.isNotEmpty == true ? names[e.key]! : 'Cena');
          notifyListeners();
        } catch (err) {
          errorLog.info('Audiolivros', 'Não deu para baixar uma ilustração', err);
        }
      }
      info = infoFor(path) ?? info;
      await save(path, info.copyWith(art: art, artCredit: credit, scenes: scenes, artDone: true, artVersion: artVersion));
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
    final keys = info.art.keys.where((k) => k < sceneBase).toList()..sort();
    return [for (final k in keys) ?artFile(path, k)];
  }
}
