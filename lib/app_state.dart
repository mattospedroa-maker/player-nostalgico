import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artist_names.dart';
import 'artist_photos.dart';
import 'audio_handler.dart';
import 'backup.dart';
import 'cover_embed.dart';
import 'cover_service.dart';
import 'crossfade.dart';
import 'db.dart';
import 'download_service.dart';
import 'experience_ai.dart';
import 'experiences.dart';
import 'error_log.dart';
import 'filename_parser.dart';
import 'gif_fetcher.dart';
import 'gif_providers.dart';
import 'gif_service.dart';
import 'genre.dart';
import 'genre_finder.dart';
import 'lastfm.dart';
import 'library_scanner.dart';
import 'metadata.dart';
import 'models.dart';
import 'mood.dart';
import 'info_retry.dart';
import 'organizer.dart';
import 'play_stats.dart';
import 'player_service.dart';
import 'audiobooks.dart';
import 'author_photos.dart';
import 'book_service.dart';
import 'podcast_info.dart';
import 'podcasts.dart';
import 'podcast_themes.dart';
import 'net_policy.dart';
import 'program_art.dart';
import 'storage_service.dart';
import 'recommender.dart';
import 'style_learning.dart';
import 'styles.dart';
import 'track_sheet.dart';
import 'visual_search.dart';

/// Estado central do app: pasta-fonte, biblioteca, playlists e serviços.
/// Suba quando a leitura de nomes/tags mudar, para reler a biblioteca toda.
// 3: .m4a do YouTube com a data "20180724" não eram lidos (agora são consertados na releitura)
const scanVersion = 3;

class AppState extends ChangeNotifier {
  final AppDb db;
  final SharedPreferences prefs;
  final PlayerService player;
  final GifService gifs;
  final MetadataReader metadata = const FileMetadataReader();
  final String dataDir;
  late final CoverService covers = CoverService(dataDir, metadata);
  late final GifFetcher gifFetcher = GifFetcher(gifs, client: http.Client())..lastFmKey = (() => lastFmKey);
  int? _lastAutoFetchId;
  late final ArtistPhotoService artistPhotos = ArtistPhotoService(dataDir);
  late final ArtistTagStore artistTags = ArtistTagStore(dataDir);

  /// Ficha das músicas: o que a IA disse e as cenas mexidas à mão (`track_facts.json`).
  late final TrackFactsStore trackFacts = TrackFactsStore(dataDir);

  /// O que o app pode buscar sozinho na internet agora (aba Internet das Opções).
  late final NetPolicy net = NetPolicy(prefs);

  /// Espaço dos GIFs, fotos, capas e cache (aba Armazenamento das Opções).
  late final StorageService storage = StorageService(db: db, gifRoot: () => gifs.gifRoot, dataDir: dataDir, musicRoot: () => sourceRoot);

  /// Imagens extras da roda de GIFs (sempre, sozinhas como os GIFs): capa do álbum e fotos do artista
  /// principal (parcerias contam no principal). Os GIFs continuam todos.
  List<String> gifExtrasFor(Track t) {
    return [?covers.fileFor(t)?.path, ...artistPhotos.photosFor(ArtistNames.current.main(t.artist))];
  }

  /// O caminho é a capa ou uma foto de artista (não um GIF)? Para o selo da roda.
  String? extraLabel(Track t, String path) {
    if (artistPhotos.isPhoto(path)) return 'Foto · ${ArtistNames.current.main(t.artist)}';
    if (p.isWithin(covers.dir, path)) return 'Capa do álbum';
    return null;
  }
  late final DownloadService downloads = DownloadService(this);

  /// Baixar GIFs sozinho quando uma música começa a tocar.
  bool get autoGifs => prefs.getBool('autoGifs') ?? true;
  Future<void> setAutoGifs(bool v) async {
    await prefs.setBool('autoGifs', v);
    notifyListeners();
  }

  /// Chave da API do Last.fm (fica só no celular, nunca no código). Vazia = GIFs pelo gênero.
  /// Chave digitada na tela; se vazia, a que veio embutida no APK de teste (secret LASTFM_KEY do GitHub).
  String get lastFmKey => _keyOr(prefs.getString('lastFmKey'), const String.fromEnvironment('LASTFM_KEY'));
  Future<void> setLastFmKey(String v) async {
    await prefs.setString('lastFmKey', v.trim());
    notifyListeners();
    // a música que está tocando já ganha os GIFs pelas tags
    final t = player.current == null ? null : byId(player.current!.id);
    if (t != null && autoGifs && net.allows(NetFeature.gifs)) unawaited(gifFetcher.fetchFor(t).catchError(_gifFetchFailed));
  }

  /// Chave do Gemini (resumo dos podcasts): a digitada nas Opções, senão a que veio no APK (secret GEMINI_KEY).
  String get geminiKey => _keyOr(prefs.getString('geminiKey'), const String.fromEnvironment('GEMINI_KEY'));

  /// Chave da Mistral (reserva do resumo quando o Gemini bate no limite): secret MISTRAL_KEY.
  String get mistralKey => _keyOr(prefs.getString('mistralKey'), const String.fromEnvironment('MISTRAL_KEY'));

  /// Informações e resumo dos episódios (arquivo .json ao lado de cada um).
  late final PodcastInfoService podcastInfo = PodcastInfoService(
    client: gifFetcher.client,
    apiKey: () => geminiKey,
    mistralKey: () => mistralKey,
    fetchInfo: (url) => downloads.ytdlp.info(url, playlist: false),
  );

  /// Imagem de cada programa de podcast (ícone do canal do YouTube, guardado na pasta do programa).
  late final ProgramArtService programArt = ProgramArtService(client: gifFetcher.client, prefs: prefs);

  /// Capítulos, texto da obra e ilustrações dos audiolivros (arquivos ao lado de cada livro).
  late final BookService bookService = BookService(
    client: gifFetcher.client,
    geminiKey: () => geminiKey,
    allowNet: () => net.allows(NetFeature.books),
    allowAi: () => net.allows(NetFeature.ai),
    fetchInfo: (url) => downloads.ytdlp.info(url, playlist: false),
  );

  /// Foto de cada autor de audiolivro (Wikipedia, guardada em Audiolivros/.autores/).
  late final AuthorPhotoService authorPhotos =
      AuthorPhotoService(client: gifFetcher.client, root: () => sourceRoot, allowNet: () => net.allows(NetFeature.photos));

  /// Livro mudou de lugar: informações, texto, ilustrações e o id do YouTube vão junto.
  void _bookMoved(String from, String to) {
    bookService.moved(from, to);
    programArt.episodeMoved(from, to);
    unawaited(downloads.moved(from, to));
  }

  /// Informações do livro; arquivo posto à mão na pasta Audiolivros ganha título/autor pelas tags.
  BookInfo bookInfoOf(Track t) =>
      bookService.infoFor(t.path) ??
      BookInfo(title: Audiobook(t, null).title, author: Audiobook(t, null).author);

  final Set<String> _bookChecked = {};

  /// Abriu/tocou um livro: procura o texto da obra e as ilustrações que faltam (uma vez por abertura do app).
  void ensureBook(Track t) {
    if (!isAudiobook(t) || !_bookChecked.add(t.path)) return;
    unawaited(() async {
      var info = bookService.infoFor(t.path);
      if (info == null) {
        info = bookInfoOf(t);
        await bookService.save(t.path, info);
      }
      await bookService.resplit(t.path); // destaque antigo (só no ponto): corta até a vírgula, sem internet
      if (!net.allows(NetFeature.books)) return;
      if (bookService.shouldSearchText(info)) {
        await bookService.fetchText(t.path);
        return;
      }
      if (bookService.needsWordTimes(t.path)) {
        await bookService.addWordTimes(t.path); // transcrição antiga: ganha o tempo das palavras (destaque da frase)
      } else if (bookService.needsPolish(t.path)) {
        unawaited(bookService.polish(t.path));
      }
      if (BookService.needsArt(bookService.infoFor(t.path) ?? info)) await bookService.fetchArt(t.path);
    }());
  }

  /// Livros da Biblioteca com o que se sabe de cada um.
  List<Audiobook> audiobookList() => [for (final t in audiobooks) Audiobook(t, bookService.infoFor(t.path))];

  /// Começo de cada capítulo do livro (ms), para o ⏮/⏭ pularem de capítulo.
  List<int> chapterStartsOf(Track t) =>
      isAudiobook(t) ? [for (final c in bookService.infoFor(t.path)?.chapters ?? const []) c.startMs] : const [];

  /// Episódios de cada programa separados por tema (Gemini + um GIF por tema).
  late final PodcastThemesService podcastThemes =
      PodcastThemesService(client: gifFetcher.client, prefs: prefs, geminiKey: () => net.allows(NetFeature.ai) ? geminiKey : '', giphy: () => giphy);

  /// Id do vídeo do YouTube de onde veio o episódio (do .json do resumo ou da lista de baixados).
  String? youtubeIdOf(Track t) {
    final id = podcastInfo.infoFor(t.path)?.videoId;
    return id != null && id.isNotEmpty ? id : downloads.youtubeIdFor(t.path);
  }

  /// Episódio mudou de lugar: o .json do resumo, a miniatura do vídeo e o id do YouTube vão junto.
  void _podcastMoved(String from, String to) {
    podcastInfo.moved(from, to);
    programArt.episodeMoved(from, to);
    unawaited(downloads.moved(from, to));
  }

  /// Pasta do programa (Podcasts/`<Programa>`/) pelo arquivo de um episódio.
  static String programDirOf(Track episode) => p.dirname(episode.path);

  /// Baixa o ícone do canal dos programas que ainda não têm (uma vez; falhou = tenta de novo dias depois).
  void ensureProgramArt(List<Track> episodes) {
    for (final t in episodes) {
      final dir = programDirOf(t);
      if (programArt.fileFor(dir) != null || !net.allows(NetFeature.covers)) return;
      final id = youtubeIdOf(t);
      if (id != null) {
        unawaited(programArt.ensure(dir, videoId: id));
        return;
      }
    }
  }

  /// Tocou um episódio sem resumo (baixado antes do resumo existir): faz agora, em segundo plano.
  void _ensureSummary(Track t) {
    if (podcastInfo.isWorking(t.path) || !podcastInfo.canSummarizeNow || !net.allows(NetFeature.ai)) return;
    final info = podcastInfo.infoFor(t.path);
    if (info != null && info.hasSummary) return;
    // já tentou: só tenta de novo sozinho se o erro foi temporário (Gemini sobrecarregado, 429...)
    final fails = prefs.getInt('summaryFails:${t.path}') ?? 0;
    if (info != null && info.status != SummaryStatus.none && !isTemporarySummaryError(info.error) && fails > 0) return;
    // falhou há pouco: espera cada vez mais (30 min, 2 h, 1 dia) para não gastar a cota grátis
    final tried = prefs.getInt('summaryTried:${t.path}') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - tried < summaryRetryWait(fails).inMilliseconds) return;
    final id = info?.videoId.isNotEmpty == true ? info!.videoId : downloads.youtubeIdFor(t.path);
    if (id == null || id.isEmpty) return; // arquivo que não veio do YouTube pelo app: sem como achar a legenda
    prefs.setInt('summaryTried:${t.path}', DateTime.now().millisecondsSinceEpoch);
    unawaited(podcastInfo.summarize(t.path, 'https://www.youtube.com/watch?v=$id', title: t.title, program: t.artist).then((r) {
      if (r != null && r.hasSummary) {
        prefs.remove('summaryFails:${t.path}');
      } else {
        prefs.setInt('summaryFails:${t.path}', fails + 1);
      }
    }));
  }

  Timer? _summaryRetryTimer;

  /// A cada 15 min (com o app aberto): um episódio cujo resumo falhou por erro temporário tenta de novo.
  /// Um por vez, e só quando a espera daquele episódio já passou.
  void _startSummaryRetries() {
    _summaryRetryTimer?.cancel();
    _summaryRetryTimer = Timer.periodic(const Duration(minutes: 15), (_) => retryFailedSummaries());
  }

  /// Escolhe o próximo episódio que falhou por erro temporário e tenta de novo (devolve se começou).
  bool retryFailedSummaries() {
    if (!podcastInfo.canSummarizeNow || !net.allows(NetFeature.ai)) return false;
    for (final t in podcasts) {
      if (podcastInfo.isWorking(t.path)) return false; // já tem um resumo em andamento
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final t in podcasts) {
      final info = podcastInfo.infoFor(t.path);
      if (info == null || info.hasSummary || !isTemporarySummaryError(info.error)) continue;
      final fails = prefs.getInt('summaryFails:${t.path}') ?? 1;
      final tried = prefs.getInt('summaryTried:${t.path}') ?? 0;
      if (now - tried < summaryRetryWait(fails).inMilliseconds) continue;
      if (fails == 0) prefs.setInt('summaryFails:${t.path}', 1);
      _ensureSummary(t);
      return true;
    }
    return false;
  }

  /// Chave da API do GIPHY (só no celular). Vazia = sem GIPHY, só anime.
  String get giphyKey => _keyOr(prefs.getString('giphyKey'), const String.fromEnvironment('GIPHY_KEY'));

  static String _keyOr(String? typed, String builtIn) => (typed != null && typed.trim().isNotEmpty) ? typed.trim() : builtIn.trim();
  Future<void> setGiphyKey(String v) async {
    await prefs.setString('giphyKey', v.trim());
    _playerVisuals.clear();
    _visualsFailedAt.clear();
    visualsEpoch++;
    notifyListeners();
  }

  /// De onde vêm os GIFs da roda do Tocando agora. Padrão: automático (anime + GIPHY intercalados).
  GifSource get gifSource => GifSource.values.asNameMap()[prefs.getString('gifSource')] ?? GifSource.auto;
  Future<void> setGifSource(GifSource v) async {
    await prefs.setString('gifSource', v.name);
    visualsEpoch++;
    notifyListeners();
  }

  /// Muda quando a chave/fonte muda, para a roda de GIFs recarregar.
  int visualsEpoch = 0;

  GiphyProvider get giphy => GiphyProvider(gifFetcher.client, giphyKey);

  /// GIFs do GIPHY para a roda (passam da internet, não são salvos; só os endereços ficam guardados).
  /// Guardados por música e clima: na memória e em `giphy_roda.json`, para não gastar o limite do GIPHY
  /// (chave gratuita = ~100 consultas por hora). Resultado vazio (limite, sem internet) não é guardado.
  final Map<String, List<VisualResult>> _playerVisuals = {};
  final Map<String, Future<List<VisualResult>>> _visualsInFlight = {};
  final Map<String, DateTime> _visualsFailedAt = {};
  static const _visualsMaxAge = Duration(days: 3);

  Future<List<VisualResult>> playerVisualsFor(Track t) {
    if (isSpoken(t)) return Future.value(const []); // GIFs de podcast vêm numa fase própria (estúdio de rádio)
    if (gifSource == GifSource.anime || giphyKey.isEmpty || t.id == null) return Future.value(const []);
    if (!net.allows(NetFeature.gifs)) return Future.value(const []); // GIFs do GIPHY passam pela internet
    // v2: sorteio por música (menos repetição no álbum). O nome entra na chave: corrigiu o artista ou o título,
    // a roda busca de novo com o nome certo (antes ficava 3 dias com os GIFs do nome errado)
    final key = '${t.id}|${t.mood}|${gifSource.name}|${_namesKey(t)}|v2';
    final rejected = _rejectedFor(t);
    final cached = _playerVisuals[key] ?? _readVisualsDisk(key);
    if (cached != null) {
      _playerVisuals[key] = cached;
      return Future.value(cached.where((r) => !rejected.contains(r.gif.id)).toList());
    }
    // falhou há pouco (ex.: limite do GIPHY): espera um pouco antes de tentar de novo
    final failed = _visualsFailedAt[key];
    if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 10)) return Future.value(const []);
    // a roda pode pedir duas vezes seguidas (troca de clima + GIFs novos chegando): uma consulta só
    return _visualsInFlight[key] ??= () async {
      try {
        final plan = await gifFetcher.visualPlanFor(t);
        final picks = await PlayerVisuals(giphy).pick(plan,
            count: gifSource == GifSource.giphy ? 9 : 5,
            rnd: Random(Object.hash(t.path, t.mood)),
            avoid: _visualsUsedNear(t),
            rejected: rejected,
            artist: t.artist,
            song: t.title);
        if (picks.isEmpty) {
          _visualsFailedAt[key] = DateTime.now();
        } else {
          _playerVisuals[key] = picks;
          _writeVisualsDisk(key, picks);
        }
        return picks;
      } catch (e) {
        errorLog.info('GIFs', 'GIPHY não respondeu (roda do Tocando agora)', e);
        _visualsFailedAt[key] = DateTime.now();
        return const <VisualResult>[]; // sem internet ou chave ruim: a roda fica só com os de anime
      } finally {
        unawaited(Future<void>(() => _visualsInFlight.remove(key)));
      }
    }();
  }

  /// Artista e título como entram na chave da roda do GIPHY (sem "|", que separa as partes da chave).
  static String _namesKey(Track t) {
    final (title, artist) = GifFetcher.namesFor(t);
    return '$artist / $title'.toLowerCase().replaceAll('|', ' ').trim();
  }

  Set<String> _rejectedFor(Track t) {
    final (title, artist) = GifFetcher.namesFor(t);
    return gifFetcher.feedback?.rejected(artist, title) ?? const {};
  }

  /// 👎 num GIF salvo da música.
  Future<void> rejectGif(Track t, String path) => gifFetcher.rejectFile(t, path);

  /// 👎 num GIF do GIPHY (tela "GIFs pela vibe" ou roda): some e o termo que trouxe ele perde força.
  void rejectWeb(Track t, VisualResult r) {
    final fb = gifFetcher.feedback;
    final (title, artist) = GifFetcher.namesFor(t);
    fb?.reject(artist, title, [r.gif.id, r.gif.url]);
    if (r.term.isNotEmpty) fb?.vote(artist, title, r.term, -1);
    visualsEpoch++;
    notifyListeners();
  }

  /// ⬇ de um GIF do GIPHY: o termo que achou ele ganha força para a música e o artista.
  void likedWeb(Track t, VisualResult r) {
    final (title, artist) = GifFetcher.namesFor(t);
    if (r.term.isNotEmpty) gifFetcher.feedback?.vote(artist, title, r.term, 1);
  }

  /// Salva as palavras da música e do artista e já baixa uns GIFs para as palavras novas.
  Future<int> saveKeywords(Track t, {required String song, required String artist}) async {
    final title = parseFileName(t.title).title;
    final oldWords = {...gifs.songExtras(t.artist, title).split(','), ...gifs.artistExtras(t.artist).split(',')}
        .map((w) => w.trim().toLowerCase())
        .toSet();
    await gifs.setSongExtras(t.artist, title, song);
    await gifs.setArtistExtras(t.artist, artist);
    final fresh = [...song.split(','), ...artist.split(',')].map((w) => w.trim()).where((w) => w.length >= 2 && !oldWords.contains(w.toLowerCase())).toList();
    if (fresh.isEmpty) return 0;
    _playerVisuals.removeWhere((k, _) => k.startsWith('${t.id}|'));
    final n = await gifFetcher.fetchForKeywords(t, fresh, giphy: giphyKey.isEmpty ? null : giphy);
    visualsEpoch++;
    notifyListeners();
    return n;
  }

  /// GIFs do GIPHY que outras músicas do mesmo álbum (ou artista) já mostram, para não repetir.
  Set<String> _visualsUsedNear(Track t) {
    final out = <String>{};
    final sameAlbum = t.album.isNotEmpty && t.album != unknownAlbum;
    for (final MapEntry(key: k, value: e) in _visualsMap.entries) {
      if (!k.endsWith('|v2')) continue;
      final other = byId(int.tryParse(k.split('|').first));
      if (other == null || other.id == t.id || e is! Map) continue;
      final near = sameAlbum ? other.album == t.album && other.artist == t.artist : other.artist == t.artist;
      if (!near) continue;
      for (final m in (e['items'] as List? ?? const [])) {
        if (m is Map) out.add('${m['id']}');
      }
    }
    return out;
  }

  File get _visualsFile => File(p.join(dataDir, 'giphy_roda.json'));
  Map<String, dynamic>? _visualsDisk;
  Map<String, dynamic> get _visualsMap {
    if (_visualsDisk != null) return _visualsDisk!;
    try {
      _visualsDisk = _visualsFile.existsSync() ? (jsonDecode(_visualsFile.readAsStringSync()) as Map).cast<String, dynamic>() : {};
    } catch (e) {
      errorLog.info('GIFs', 'Cache da roda do GIPHY estava ilegível e foi recomeçado', e);
      _visualsDisk = {};
    }
    return _visualsDisk!;
  }

  List<VisualResult>? _readVisualsDisk(String key) {
    final e = _visualsMap[key];
    if (e is! Map) return null;
    final at = DateTime.tryParse('${e['t']}');
    if (at == null || DateTime.now().difference(at) > _visualsMaxAge) return null;
    final list = [
      for (final m in (e['items'] as List? ?? const []))
        if (m is Map)
          VisualResult(
            GiphyGif(id: '${m['id']}', title: '${m['title'] ?? ''}', previewUrl: '${m['preview']}', url: '${m['url']}', pageUrl: '${m['page'] ?? ''}'),
            '${m['q'] ?? ''}',
            '${m['g'] ?? ''}',
            anime: m['a'] == true,
          ),
    ];
    return list.isEmpty ? null : list;
  }

  void _writeVisualsDisk(String key, List<VisualResult> items) {
    // tira o que já venceu (ex.: a lista do nome antigo de uma música corrigida), para o arquivo não crescer
    _visualsMap.removeWhere((_, e) {
      final at = e is Map ? DateTime.tryParse('${e['t']}') : null;
      return at == null || DateTime.now().difference(at) > _visualsMaxAge;
    });
    _visualsMap[key] = {
      't': DateTime.now().toIso8601String(),
      'items': [
        for (final r in items)
          {'id': r.gif.id, 'title': r.gif.title, 'preview': r.gif.previewUrl, 'url': r.gif.url, 'page': r.gif.pageUrl, 'q': r.query, 'g': r.group, 'a': r.anime},
      ],
    };
    try {
      _visualsFile.writeAsStringSync(jsonEncode(_visualsMap));
    } catch (e) {
      errorLog.warn('GIFs', 'Não deu para salvar o cache da roda do GIPHY', error: e);
    }
  }

  /// Download em massa ("Baixar GIFs para todas"): progresso feito/total, null = parado.
  (int, int)? bulkGifProgress;
  bool _cancelBulk = false;
  final List<Track> _pending = [];

  /// Só as músicas. Podcasts ficam de fora de propósito: tudo que usa [tracks] (Tocar tudo, mix,
  /// recomendações, coleções, repetidas, capas, GIFs) nunca vê um podcast.
  List<Track> tracks = const [];

  /// Episódios de podcast (arquivos dentro de `<pasta>`/Podcasts/).
  List<Track> podcasts = const [];

  /// Onde cada episódio parou e quais já foram ouvidos.
  late final PodcastProgress podcastProgress = PodcastProgress(prefs);

  bool isPodcast(Track t) => isPodcastPath(sourceRoot, t.path);

  /// Audiolivros (arquivos dentro de `<pasta>`/Audiolivros/). Um arquivo = um livro inteiro.
  List<Track> audiobooks = const [];

  bool isAudiobook(Track t) => isAudiobookPath(sourceRoot, t.path);

  /// Podcast ou audiolivro: fala, não música (sem GIFs de música, sem mix, retoma onde parou, velocidade).
  bool isSpoken(Track t) => isPodcast(t) || isAudiobook(t);

  /// Redesenha as telas (ex.: marcou um episódio como ouvido).
  void touch() => notifyListeners();

  /// Tipo de mídia escolhido no "Endereço" da Biblioteca.
  MediaKind get libraryMedia => MediaKind.values.asNameMap()[prefs.getString('libraryMedia')] ?? MediaKind.music;
  Future<void> setLibraryMedia(MediaKind m) async {
    if (!m.available || m == libraryMedia) return;
    await prefs.setString('libraryMedia', m.name);
    notifyListeners();
  }

  /// Avisado depois de ler a pasta quando aparecem músicas com cara de podcast que ainda não foram avisadas
  /// (a tela mostra o balão perto do relógio). Nunca move nada sozinho.
  void Function(List<PodcastCandidate> fresh)? onPodcastSuggestions;

  /// Músicas que parecem podcasts (menos as que você disse que não são).
  List<PodcastCandidate> podcastCandidates() =>
      findPodcastCandidates(tracks, dismissed: (prefs.getStringList('podcastNotPodcast') ?? const []).toSet());

  /// Avisa uma vez por arquivo (o balão não volta para o mesmo arquivo).
  void _suggestPodcasts() {
    final seen = (prefs.getStringList('podcastSuggested') ?? const []).toSet();
    final fresh = podcastCandidates().where((c) => c.strong && !seen.contains(c.track.path)).toList();
    if (fresh.isEmpty || onPodcastSuggestions == null) return;
    prefs.setStringList('podcastSuggested', [...seen, ...fresh.map((c) => c.track.path)]);
    onPodcastSuggestions!(fresh);
  }

  /// Move para Podcasts/`<Programa>`/ os escolhidos na revisão. Os desmarcados ficam marcados como "não é podcast"
  /// e não aparecem de novo. Devolve os movimentos feitos (para desfazer).
  Future<List<MoveRecord>> moveToPodcasts(Map<Track, String> chosen, {Iterable<Track> notPodcast = const []}) async {
    final root = sourceRoot;
    if (root == null) return const [];
    if (notPodcast.isNotEmpty) {
      final no = (prefs.getStringList('podcastNotPodcast') ?? const []).toSet()..addAll(notPodcast.map((t) => t.path));
      await prefs.setStringList('podcastNotPodcast', no.toList());
    }
    final done = <MoveRecord>[];
    for (final e in chosen.entries) {
      final from = e.key.path;
      var target = podcastTargetPath(root, e.value, p.basename(from));
      final base = p.withoutExtension(target), ext = p.extension(target);
      for (var k = 2; File(target).existsSync(); k++) {
        target = '$base ($k)$ext';
      }
      try {
        await player.forgetTrack(e.key.id); // o arquivo vai mudar de lugar: sai da fila de músicas
        await Directory(p.dirname(target)).create(recursive: true);
        await Organizer.moveFile(File(from), target);
        _podcastMoved(from, target);
        done.add(MoveRecord(from: from, to: target, artist: e.value, album: e.value, title: e.key.title));
      } catch (err) {
        errorLog.warn('Podcasts', 'Não deu para mover "${p.basename(from)}" para Podcasts', error: err, balloon: true);
      }
    }
    if (done.isNotEmpty) {
      removeEmptyParents(root, done.map((m) => m.from));
      await rescan();
    }
    return done;
  }

  /// Desfaz [moveToPodcasts]: devolve os arquivos para onde estavam.
  Future<void> undoMoveToPodcasts(List<MoveRecord> moves) async {
    final root = sourceRoot;
    for (final m in moves) {
      try {
        if (!File(m.to).existsSync()) continue;
        await player.forgetTrack(podcasts.where((t) => t.path == m.to).firstOrNull?.id);
        await Directory(p.dirname(m.from)).create(recursive: true);
        await Organizer.moveFile(File(m.to), m.from);
        podcastProgress.moved(m.to, m.from);
        _podcastMoved(m.to, m.from);
      } catch (err) {
        errorLog.warn('Podcasts', 'Não deu para devolver "${p.basename(m.to)}"', error: err, balloon: true);
      }
    }
    if (root != null) removeEmptyParents(root, moves.map((m) => m.to));
    await rescan();
  }

  List<Playlist> playlists = const [];
  bool scanning = false;
  double scanProgress = 0;

  AppState._(this.db, this.prefs, this.player, this.gifs, this.dataDir);

  /// Busca automática de GIFs falhou (rede ou pasta): só registra, a música segue com o que tem.
  static int _gifFetchFailed(Object e) {
    errorLog.add(ErrorLog.isNetwork(e) ? LogLevel.info : LogLevel.warning, 'GIFs', 'Busca automática de GIFs falhou', error: e);
    return 0;
  }

  static int _coversFailed(Object e) {
    errorLog.add(ErrorLog.isNetwork(e) ? LogLevel.info : LogLevel.warning, 'Capas', 'Busca de capas parou no meio', error: e);
    return 0;
  }

  static Future<AppState> create({PlayerAudioHandler? handler}) async {
    final dir = await getApplicationSupportDirectory();
    final db = await AppDb.open(p.join(dir.path, 'player.db'));
    final prefs = await SharedPreferences.getInstance();
    final s = AppState._(db, prefs, PlayerService(db, handler: handler), GifService(db), dir.path);
    s.gifs.sourceRoot = s.sourceRoot;
    s.player.addListener(s._onPlayerChanged);
    s.player
      ..library = (() => s.tracks)
      ..isPodcast = s.isSpoken
      ..chapterStarts = s.chapterStartsOf
      ..podcastProgress = s.podcastProgress
      ..podcastSpeed = prefs.getDouble('podcastSpeed') ?? 1.0
      ..onPodcastSpeedChanged = ((v) => prefs.setDouble('podcastSpeed', v))
      // 'mixMode2': a escolha antiga ('mixMode') é esquecida uma vez, para todo mundo começar em "Da mesma vibe"
      ..mixMode = MixMode.values.asNameMap()[prefs.getString('mixMode2')] ?? MixMode.vibe
      ..onMixModeChanged = ((m) => prefs.setString('mixMode2', m.name))
      ..onCrossfadeChanged = ((on) => prefs.setBool('crossfade', on))
      ..onCrossfadeTimesChanged = ((out, inn) {
        prefs.setInt('crossfadeOut', out.inSeconds);
        prefs.setInt('crossfadeIn', inn.inSeconds);
      })
      ..onPlayLogged = s._invalidateStats;
    s.player.crossfader.setTimes(
      Duration(seconds: (prefs.getInt('crossfadeOut') ?? defaultFadeOut.inSeconds).clamp(fadeOutRange.$1, fadeOutRange.$2)),
      Duration(seconds: (prefs.getInt('crossfadeIn') ?? defaultFadeIn.inSeconds).clamp(fadeInRange.$1, fadeInRange.$2)),
    );
    s.player.crossfader.enabled = prefs.getBool('crossfade') ?? false;
    handler?.onFavorite = () async {
      final t = s.player.current == null ? null : s.byId(s.player.current!.id);
      if (t != null) await s.toggleFavorite(t);
    };
    // quem já usava o app antes do backup existir: banco com dados = pode começar a copiar para a pasta
    if (prefs.getBool('backupReady') == null && (await db.playlists()).isNotEmpty) await prefs.setBool('backupReady', true);
    await s.reload(rereadGifs: true);
    s._startSummaryRetries();
    s.gifFetcher.allowLyrics = () => s.net.allows(NetFeature.lyrics);
    if (Platform.isAndroid) s.net.watch();
    // voltou a poder usar a internet (ex.: chegou no Wi-Fi): capas e informações que faltam
    s._wasOnline = s.net.online;
    s.net.addListener(s._onNetChanged);
    // teto de espaço: confere um pouco depois de abrir e sempre que chegam GIFs novos
    s._lastGifCount = s.gifs.count;
    s.gifs.addListener(s._onGifCountChanged);
    unawaited(Future<void>.delayed(const Duration(seconds: 60), () => s.autoClean()));
    // playlist do YouTube que ficou pela metade (o app foi fechado no meio): continua de onde parou
    if (s.sourceRoot != null) s.downloads.resumePending();
    // capas que faltam (inclusive as que falharam antes), em segundo plano
    unawaited(Future<void>.delayed(const Duration(seconds: 5), () => s.fetchMissingCovers()).catchError(_coversFailed));
    // músicas que ficaram sem artista/álbum: algumas por vez, depois das capas
    unawaited(Future<void>.delayed(const Duration(seconds: 40), () => s.retryMissingInfo()).catchError((Object e) {
      errorLog.info('Informações', 'Nova tentativa de artista/álbum falhou', e);
    }));
    // Android 13+: a notificação com os controles precisa desta permissão
    if (Platform.isAndroid) {
      unawaited(Permission.notification.request().catchError((Object e) {
        errorLog.warn('Notificação', 'Não deu para pedir a permissão de notificação', error: e);
        return PermissionStatus.denied;
      }));
    }
    return s;
  }

  String? get sourceRoot => prefs.getString('sourceRoot');
  String get undoLogPath => p.join(dataDir, 'ultima_organizacao.json');
  bool get canUndoOrganize => File(undoLogPath).existsSync();

  Future<void> setSourceRoot(String path) async {
    await prefs.setString('sourceRoot', path);
    gifs.sourceRoot = path;
    notifyListeners();
    await rescan();
  }

  /// Android 11+: pede "acesso a todos os arquivos" para ler e mover músicas.
  Future<bool> ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final r = await Permission.manageExternalStorage.request();
    if (r.isGranted) return true;
    final legacy = await Permission.storage.request();
    return legacy.isGranted;
  }

  /// Relê músicas e playlists do banco. A pasta de GIFs só é relida com [rereadGifs]
  /// (abertura, releitura da pasta, "Recarregar"): favoritar, editar ou mexer em playlists não muda os GIFs,
  /// e reler a pasta inteira a cada toque custava tempo à toa.
  Future<void> reload({bool rereadGifs = false}) async {
    final all = await db.allTracks();
    final root = sourceRoot;
    tracks = [for (final t in all) if (!isPodcastPath(root, t.path) && !isAudiobookPath(root, t.path)) t];
    podcasts = [for (final t in all) if (isPodcastPath(root, t.path)) t];
    audiobooks = [for (final t in all) if (isAudiobookPath(root, t.path)) t];
    ArtistNames.current = ArtistNames.fromTracks(tracks);
    MoodClues.tagsOf = gifFetcher.cachedTags;
    MoodClues.learnFrom(tracks);
    Styles.trackTags = gifFetcher.cachedTags;
    Styles.artistTags = artistTags.get;
    Styles.learnedPair = (a, b) => StyleLearning.current.stylePair(a, b);
    TrackSheet.aiOf = trackFacts.ai;
    TrackSheet.editsOf = trackFacts.edits;
    TrackSheet.lyricsOf = gifFetcher.cachedLyricScenes;
    Styles.invalidate();
    playlists = await db.playlists();
    await _relearn();
    if (rereadGifs) await gifs.refresh();
    notifyListeners();
    _scheduleBackup();
    if (rereadGifs) unawaited(refreshExperiences());
  }

  /// Refaz o que o app aprende com as playlists (músicas/artistas/estilos que você junta). Conta em memória.
  Future<void> _relearn() async {
    try {
      final membership = await db.playlistMembership();
      StyleLearning.current = StyleLearning.build(membership, {for (final pl in playlists) pl.id: pl.name}, tracks,
          addedFromSuggestions: _suggestionAdds());
    } catch (e) {
      errorLog.info('Estilos', 'Não deu para aprender com as playlists', e);
    }
    try {
      TrackSheet.habits = ListeningHabits(await db.listeningHabits());
    } catch (e) {
      errorLog.info('Momentos', 'Não deu para ler em que horário você ouve cada música', e);
    }
    TrackSheet.invalidate();
  }

  /// Cenas postas/tiradas à mão na aba "Momentos".
  Future<void> setSceneEdits(Track t, StyleEdits edits) async {
    trackFacts.putEdits(t, edits);
    TrackSheet.invalidate();
    notifyListeners();
    try {
      await trackFacts.save();
    } catch (e) {
      errorLog.warn('Momentos', 'Não deu para salvar as cenas da música', error: e);
    }
  }

  // ---------- playlists do momento ----------

  static const _expKey = 'experiencias';
  ExperienceState _exp = ExperienceState.empty;
  bool _expLoaded = false;

  /// As playlists do momento no ar agora (as vencidas já saem daqui, mesmo antes de renovar).
  List<Experience> get experiences {
    if (!_expLoaded) {
      _expLoaded = true;
      _exp = ExperienceState.decode(prefs.getString(_expKey));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return [for (final e in _exp.active) if (!e.expired(now)) e]..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));
  }

  Experience? experienceById(String id) => experiences.where((e) => e.id == id).firstOrNull;

  Timer? _expTimer;

  /// Tira as vencidas e cria novas (conta em memória, sem internet). Chamado ao abrir, ao reler e quando uma vence.
  Future<void> refreshExperiences() async {
    experiences; // carrega
    try {
      final stats = await playStats();
      final next = ExperienceEngine.refresh(_exp, tracks, stats: stats, aiThemes: _aiThemes());
      if (!identical(next, _exp)) {
        _exp = next;
        await prefs.setString(_expKey, _exp.encode());
        notifyListeners();
      }
    } catch (e) {
      errorLog.info('Momentos', 'Não deu para renovar as playlists do momento', e);
    }
    unawaited(_maybeFetchAiThemes());
    // acorda quando a próxima vencer
    _expTimer?.cancel();
    final list = experiences;
    if (list.isNotEmpty) {
      final wait = list.first.expiresAt - DateTime.now().millisecondsSinceEpoch;
      _expTimer = Timer(Duration(milliseconds: wait.clamp(60000, 86400000)), () => unawaited(refreshExperiences()));
    }
  }

  static const _aiThemesKey = 'iaTemas';

  /// Temas que a IA inventou nesta semana (ainda não usados).
  List<AiTheme> _aiThemes() {
    try {
      final raw = prefs.getString(_aiThemesKey);
      if (raw == null) return const [];
      final j = jsonDecode(raw) as Map;
      return [for (final t in (j['themes'] as List? ?? const [])) ?AiTheme.fromJson(t)];
    } catch (_) {
      return const [];
    }
  }

  bool _fetchingThemes = false;

  /// Uma vez por semana (no Wi-Fi, se a aba Internet pedir), a IA inventa 3 temas novos para a sua biblioteca.
  /// Só depois que a ficha de boa parte das músicas já está pronta, para a IA saber o que você tem.
  Future<void> _maybeFetchAiThemes() async {
    if (_fetchingThemes || geminiKey.isEmpty || !net.allows(NetFeature.ai) || tracks.length < 30) return;
    final last = prefs.getInt('iaTemasEm') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < const Duration(days: 7).inMilliseconds) return;
    final read = tracks.where(trackFacts.hasAi).length;
    if (read < tracks.length * .5 && read < 300) return; // a IA ainda está lendo as músicas
    _fetchingThemes = true;
    try {
      final avoid = [for (final id in _exp.recent) if (id.startsWith('ia:')) id.substring(3).replaceAll('-', ' ')];
      final ai = await GeminiClient(gifFetcher.client, geminiKey)
          .generateJson(ExperienceAi.weeklyPrompt(ExperienceAi.summarize(tracks), avoid: avoid), timeout: const Duration(minutes: 2));
      final themes = ExperienceAi.parseThemes(ai);
      await prefs.setInt('iaTemasEm', now);
      await prefs.setString(_aiThemesKey, jsonEncode({'themes': [for (final t in themes) t.toJson()]}));
      errorLog.info('Momentos', 'A IA inventou ${themes.length} temas: ${themes.map((t) => t.title).join(', ')}');
      if (themes.isNotEmpty) {
        _fetchingThemes = false;
        await refreshExperiences();
      }
    } on GeminiException catch (e) {
      errorLog.info('Momentos', 'A IA não inventou os temas da semana agora (${e.message})');
    } catch (e) {
      errorLog.info('Momentos', 'Não deu para pedir os temas da semana à IA', e);
    } finally {
      _fetchingThemes = false;
    }
  }

  /// "Inventar uma experiência": com internet a IA transforma o texto num tema; sem, o app casa as palavras.
  /// Devolve a playlist criada (já no ar) ou uma mensagem dizendo por que não deu.
  Future<(Experience?, String?)> inventExperience(String text) async {
    final t = text.trim();
    if (t.isEmpty) return (null, 'Escreva o momento, por exemplo "cavalgada no deserto ao pôr do sol".');
    AiTheme? theme;
    var byAi = false;
    if (geminiKey.isNotEmpty && net.online) {
      try {
        final ai = await GeminiClient(gifFetcher.client, geminiKey)
            .generateJson(ExperienceAi.inventPrompt(t, ExperienceAi.summarize(tracks)), timeout: const Duration(seconds: 45));
        theme = ExperienceAi.parseThemes(ai).firstOrNull;
        byAi = theme != null;
      } catch (e) {
        errorLog.info('Momentos', 'A IA não respondeu ao "Inventar"; montei pelas palavras', e);
      }
    }
    theme ??= ExperienceAi.offlineTheme(t);
    final stats = await playStats();
    var e = ExperienceEngine.invent(theme.toRecipe(), tracks,
        stats: stats, why: theme.why.isEmpty ? (byAi ? 'Montada pela IA a partir do que você pediu.' : '') : theme.why, missing: theme.missing);
    if (e == null && byAi) {
      // a IA viajou demais: tenta pelas palavras
      final off = ExperienceAi.offlineTheme(t);
      e = ExperienceEngine.invent(off.toRecipe(), tracks, stats: stats, why: off.why);
    }
    if (e == null) return (null, 'Não achei músicas suficientes para "$t". Tente outras palavras (lugar, clima, atividade).');
    _exp = ExperienceState([for (final x in _exp.active) if (x.id != e.id) x, e], [..._exp.recent, e.id]);
    await prefs.setString(_expKey, _exp.encode());
    notifyListeners();
    return (e, null);
  }

  /// "Salvar nas minhas playlists": vira uma playlist normal (com as músicas na mesma ordem) e sai do momento.
  Future<int?> saveExperience(Experience e) async {
    final taken = {for (final p in playlists) p.name.toLowerCase()};
    var name = e.title;
    for (var i = 2; taken.contains(name.toLowerCase()); i++) {
      name = '${e.title} ($i)';
    }
    final id = await db.createPlaylist(name);
    final ids = {for (final t in tracks) t.id};
    await db.setPlaylistOrder(id, [for (final t in e.trackIds) if (ids.contains(t)) t]);
    _exp = ExperienceState([for (final x in _exp.active) if (x.id != e.id) x], _exp.recent);
    await prefs.setString(_expKey, _exp.encode());
    await reload();
    unawaited(refreshExperiences()); // outra entra no lugar
    return id;
  }

  bool _fillingFacts = false;
  bool get fillingFacts => _fillingFacts;

  /// Lotes por vez (cada lote = [TrackSheet.batchSize] músicas): poupa a cota grátis do Gemini.
  static const factBatchesPerRun = 8;

  /// A IA preenche a ficha das músicas que ainda não leu: em lotes, em segundo plano, uma vez por música.
  /// Respeita a aba Internet (item "IA"). Para no limite do plano grátis e continua na próxima vez.
  /// [only]: só estas músicas (botão "Pedir à IA agora"), mesmo que a IA já tenha lido.
  Future<int> fillTrackFacts({List<Track>? only}) async {
    if (_fillingFacts || geminiKey.isEmpty) return 0;
    if (only == null && !net.allows(NetFeature.ai)) return 0;
    if (only != null && !net.online) return 0;
    _fillingFacts = true;
    var n = 0;
    try {
      final todo = only ??
          [
            for (final t in tracks)
              if (t.artist != unknownArtist && t.artist.trim().isNotEmpty && t.title.trim().isNotEmpty && !trackFacts.hasAi(t)) t
          ];
      final ai = GeminiClient(gifFetcher.client, geminiKey);
      for (var b = 0; b < factBatchesPerRun && b * TrackSheet.batchSize < todo.length; b++) {
        final batch = todo.skip(b * TrackSheet.batchSize).take(TrackSheet.batchSize).toList();
        final Map<String, dynamic> answer;
        try {
          answer = await ai.generateJson(TrackSheet.prompt(batch), timeout: const Duration(minutes: 2));
        } on GeminiException catch (e) {
          errorLog.info('Momentos', 'A IA não preencheu a ficha das músicas agora (${e.message})');
          break;
        }
        final got = TrackSheet.parseAnswer(answer, batch.length);
        for (var i = 0; i < batch.length; i++) {
          // sem resposta para a música: fica marcada como lida (vazia) para não pedir de novo
          trackFacts.putAi(batch[i], got[i] ?? AiFacts.empty);
        }
        n += batch.length;
        await trackFacts.save();
        TrackSheet.invalidate();
        notifyListeners();
      }
    } catch (e) {
      errorLog.info('Momentos', 'Não deu para preencher a ficha das músicas pela IA', e);
    } finally {
      _fillingFacts = false;
    }
    if (n > 0 && only == null) unawaited(refreshExperiences()); // fichas novas: talvez caibam temas que antes não cabiam
    return n;
  }

  static const _sugAddedKey = 'sugestoesAdicionadas';

  Map<int, Set<int>> _suggestionAdds() {
    final out = <int, Set<int>>{};
    for (final s in prefs.getStringList(_sugAddedKey) ?? const <String>[]) {
      final parts = s.split(':');
      final t = int.tryParse(parts.first), pl = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (t != null && pl != null) (out[t] ??= {}).add(pl);
    }
    return out;
  }

  /// Uma sugestão do fim da playlist entrou pelo ＋: guarda para a aba "Estilo" mostrar e o aprendizado contar.
  Future<void> addSuggestionToPlaylist(int playlistId, Track t) async {
    final list = [...prefs.getStringList(_sugAddedKey) ?? const <String>[], '${t.id}:$playlistId'];
    await prefs.setStringList(_sugAddedKey, list.length > 500 ? list.sublist(list.length - 500) : list);
    await addToPlaylist(playlistId, t);
  }

  /// Estilos postos/tirados à mão na aba "Estilo".
  Future<void> setStyleEdits(Track t, StyleEdits edits) async {
    if (t.id == null) return;
    await db.setStylesEdit(t.id!, edits.encode());
    await reload();
  }

  /// Réguas arrastadas à mão (null nas duas = volta ao automático). Sem clima escolhido no selo,
  /// o selo passa a seguir as réguas; se ele mudar, os GIFs automáticos são refeitos.
  Future<void> setVibe(Track t, int? energy, int? humor) async {
    final id = t.id;
    if (id == null) return;
    final before = (byId(id) ?? t).effectiveMood;
    await db.setVibe(id, energy, humor);
    await reload();
    final updated = byId(id);
    if (updated == null) return;
    player.replaceTrack(updated);
    if (updated.effectiveMood != before) {
      if (player.mixSeedId == id) unawaited(player.refreshMix());
      unawaited(gifFetcher.refetchFor(updated).catchError(_gifFetchFailed));
    }
  }

  bool _fetchingArtistTags = false;

  /// Tags do Last.fm de cada artista que ainda não tem (uma vez por artista, em segundo plano):
  /// dão estilos às músicas que ainda não têm tags próprias. Sem chave ou sem internet: tenta na próxima leitura.
  Future<int> fillArtistTags() async {
    if (_fetchingArtistTags || lastFmKey.isEmpty || !net.allows(NetFeature.info)) return 0;
    _fetchingArtistTags = true;
    var n = 0;
    try {
      final artists = <String>{
        for (final t in tracks)
          if (t.artist != unknownArtist && t.artist.trim().isNotEmpty && !artistTags.has(t.artist)) t.artist
      };
      if (artists.isEmpty) return 0;
      final client = LastFmClient(gifFetcher.client, lastFmKey);
      for (final a in artists) {
        final r = await client.artistTopTags(a);
        if (r.status == TagStatus.network || r.status == TagStatus.noKey || r.status == TagStatus.invalidKey) break;
        artistTags.put(a, r.status == TagStatus.ok ? r.tags : const []);
        n++;
        if (n % 25 == 0) await artistTags.save();
      }
    } catch (e) {
      errorLog.info('Estilos', 'Não deu para buscar as tags dos artistas', e);
    } finally {
      if (n > 0) {
        await artistTags.save();
        Styles.invalidate();
        await _relearn();
        notifyListeners();
      }
      _fetchingArtistTags = false;
    }
    return n;
  }

  Timer? _backupTimer;

  /// Copia playlists/favoritos/climas para a pasta Playlists dentro da pasta de músicas pouco depois de cada mudança.
  /// Só depois de [_restoreIfFresh] ter rodado: um banco recém-criado (vazio) nunca apaga o backup.
  void _scheduleBackup() {
    final root = sourceRoot;
    if (root == null || prefs.getBool('backupReady') != true) return;
    _backupTimer?.cancel();
    _backupTimer = Timer(const Duration(seconds: 2), () {
      LibraryBackup.save(db, root).catchError((Object e) {
        errorLog.warn('Playlists', 'Não deu para salvar a cópia das playlists na pasta $root/${LibraryBackup.folderName}', error: e);
      });
    });
  }

  /// App instalado de novo (banco zerado): recria playlists, favoritos e climas a partir da pasta Playlists.
  Future<void> _restoreIfFresh(String root) async {
    if (prefs.getBool('backupReady') == true || tracks.isEmpty) return;
    try {
      if ((await db.playlists()).isEmpty && LibraryBackup.exists(root)) {
        final r = await LibraryBackup.restore(db, root);
        if (r.any) {
          errorLog.info('Playlists',
              'Recriadas ${r.playlists} playlists, ${r.favorites} favoritas e ${r.moods} climas a partir da pasta ${LibraryBackup.folderName}'
              '${r.missing > 0 ? ' (${r.missing} músicas não encontradas)' : ''}');
        }
      }
    } catch (e) {
      errorLog.warn('Playlists', 'Não deu para recriar as playlists a partir da pasta ${LibraryBackup.folderName}', error: e, balloon: true);
      return; // não marca como pronto: na próxima leitura tenta de novo, e o backup não é sobrescrito
    }
    await prefs.setBool('backupReady', true);
    await reload();
  }

  Future<void> rescan() async {
    final root = sourceRoot;
    if (root == null || scanning) return;
    scanning = true;
    scanProgress = 0;
    final before = {for (final t in tracks) t.id};
    notifyListeners();
    try {
      // limpeza de nomes melhorou: relê tudo uma vez
      final force = (prefs.getInt('scanVersion') ?? 1) < scanVersion;
      var shown = -1;
      await LibraryScanner(db, metadata).scan(root, force: force, onProgress: (d, t) {
        scanProgress = t == 0 ? 1 : d / t;
        // avisa as telas só quando a barra anda 1% (antes era a cada arquivo: milhares de redesenhos)
        final pct = (scanProgress * 100).floor();
        if (pct == shown) return;
        shown = pct;
        notifyListeners();
      });
      await prefs.setInt('scanVersion', scanVersion);
    } finally {
      scanning = false;
      await reload(rereadGifs: true);
    }
    await _restoreIfFresh(root);
    _suggestPodcasts();
    // músicas novas na biblioteca: busca GIFs sozinho, em segundo plano
    final added = tracks.where((t) => !before.contains(t.id)).toList();
    unawaited(_afterScan(added));
  }

  /// Primeiro descobre os gêneros que faltam (a regra dos GIFs usa o gênero), depois baixa os GIFs das novas.
  Future<void> _afterScan(List<Track> added) async {
    await fillMissingGenres().catchError((Object e) {
      errorLog.warn('Biblioteca', 'Não deu para completar os gêneros pelo MusicBrainz', error: e);
      return 0;
    });
    unawaited(fetchMissingCovers().catchError(_coversFailed));
    unawaited(fillArtistTags().then((_) => fillTrackFacts()));
    if (added.isEmpty || !autoGifs) return;
    final ids = added.map((t) => t.id).toSet();
    await fetchGifsForAll(only: tracks.where((t) => ids.contains(t.id)).toList());
  }

  /// Capas de álbum que faltam (Cover Art Archive), uma vez por álbum.
  Future<int> fetchMissingCovers() async {
    if (!net.allows(NetFeature.covers)) return 0;
    while (fillingGenres) {
      await Future<void>.delayed(const Duration(seconds: 2)); // o MusicBrainz aceita 1 pedido por segundo
    }
    // v2: a versão antiga marcava como "tentado" até quando o MusicBrainz falhava; tenta tudo de novo uma vez
    final tried = (prefs.getStringList('coverTried2') ?? const []).toSet();
    final n = await covers.fetchMissing(tracks, tried, onEach: notifyListeners);
    await prefs.setStringList('coverTried2', tried.toList());
    if (n > 0) notifyListeners();
    unawaited(embedPendingCovers());
    return n;
  }

  static const _coverEmbedKey = 'capaEmbutirPendente';
  bool _embeddingCovers = false;

  /// Música baixada do YouTube que ainda vai receber a capa do álbum dentro do arquivo.
  /// Fica guardado: se o app fechar antes, termina na próxima abertura.
  Future<void> queueCoverEmbed(String path) async {
    final list = prefs.getStringList(_coverEmbedKey) ?? <String>[];
    if (!list.contains(path)) await prefs.setStringList(_coverEmbedKey, [...list, path]);
  }

  /// Embute a capa já baixada do Cover Art Archive nas músicas pendentes, uma por vez, fora da tela.
  /// Sem capa por enquanto (sem internet): tenta de novo depois. Álbum sem capa no Cover Art Archive: desiste.
  Future<int> embedPendingCovers() async {
    if (_embeddingCovers) return 0;
    final pending = prefs.getStringList(_coverEmbedKey) ?? const <String>[];
    if (pending.isEmpty) return 0;
    _embeddingCovers = true;
    var n = 0;
    final keep = <String>[];
    try {
      final tried = (prefs.getStringList('coverTried2') ?? const []).toSet();
      final playing = player.current?.path;
      for (final path in pending) {
        if (!File(path).existsSync()) continue; // apagada ou movida
        final t = tracks.where((t) => p.equals(t.path, path)).firstOrNull;
        // ainda não entrou na Biblioteca, ou está tocando agora: fica para a próxima
        if (t == null || (playing != null && p.equals(playing, path))) {
          keep.add(path);
          continue;
        }
        final cover = covers.fileFor(t);
        if (cover == null) {
          if (!tried.contains(CoverService.fileKey(t))) keep.add(path);
          continue;
        }
        try {
          if (await embedCoverInBackground(path, await cover.readAsBytes())) n++;
        } catch (e) {
          errorLog.info('Capas', 'Não deu para embutir a capa em ${p.basename(path)}', e);
        }
      }
    } finally {
      // o que entrou na lista enquanto isso continua lá
      final now = prefs.getStringList(_coverEmbedKey) ?? const <String>[];
      await prefs.setStringList(_coverEmbedKey, [...keep, ...now.where((x) => !pending.contains(x))]);
      _embeddingCovers = false;
    }
    return n;
  }

  bool fillingGenres = false;

  /// Gênero real automático, uma vez por artista: MusicBrainz e, se não achar, tags do Last.fm.
  /// Conta como vazio o gênero genérico que vem no arquivo ("Music" é a categoria do vídeo no YouTube).
  /// O gênero achado fica guardado por artista: músicas novas do mesmo artista recebem sem consultar de novo.
  Future<int> fillMissingGenres() async {
    if (fillingGenres || !net.allows(NetFeature.info)) return 0;
    fillingGenres = true;
    // v2: as versões antigas não procuravam onde estava "Music" e não tinham o Last.fm como segunda opção
    final tried = (prefs.getStringList('genreTried2') ?? const []).toSet();
    final known = _artistGenres();
    final byArtist = <String, List<Track>>{};
    var n = 0, changed = false;
    try {
      for (final t in tracks) {
        if (!isGenericGenre(t.genre)) continue;
        var current = t.genre;
        if (current.isNotEmpty) {
          // "Music", "Other"...: some da tela mesmo que não ache o gênero real
          await db.fillGenre(t.id!, '', current: current);
          current = '';
          changed = true;
        }
        if (t.artist == unknownArtist || t.artist.trim().isEmpty) continue;
        final g = known[t.artist.toLowerCase()];
        if (g != null) {
          await db.fillGenre(t.id!, g);
          n++;
        } else if (!tried.contains(t.artist)) {
          (byArtist[t.artist] ??= []).add(t);
        }
      }
      if (byArtist.isNotEmpty) {
        notifyListeners();
        final mb = MusicBrainzClient();
        final finder = GenreFinder(
          musicBrainz: mb.artistGenre,
          lastFmArtist: (a) => LastFmClient(gifFetcher.client, lastFmKey).artistTopTags(a),
          cachedTrackTags: gifFetcher.cachedTags,
        );
        for (final e in byArtist.entries) {
          final r = await finder.find(e.key, e.value);
          if (!r.reached) {
            errorLog.info('Biblioteca', 'Sem resposta do MusicBrainz/Last.fm (gênero de ${e.key}); tenta na próxima leitura');
            break; // sem internet: tenta na próxima leitura
          }
          tried.add(e.key);
          final genre = r.genre;
          if (genre == null) continue;
          known[e.key.toLowerCase()] = genre;
          for (final t in e.value) {
            await db.fillGenre(t.id!, genre);
            n++;
          }
        }
      }
    } finally {
      await prefs.setStringList('genreTried2', tried.toList());
      await prefs.setString('artistGenres', jsonEncode(known));
      fillingGenres = false;
      if (n > 0 || changed || byArtist.isNotEmpty) await reload();
    }
    return n;
  }

  Map<String, String> _artistGenres() {
    try {
      return (jsonDecode(prefs.getString('artistGenres') ?? '{}') as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (e) {
      errorLog.info('Biblioteca', 'Gêneros guardados por artista ilegíveis; vão ser buscados de novo', e);
      return {};
    }
  }

  /// Salva a tela "Editar música": banco, tags do arquivo (opcional) e pasta (opcional).
  /// Retorna um aviso para mostrar, ou null se deu tudo certo.
  Future<String?> editTrack(Track t,
      {required String title, required String artist, required String album, required String genre, int? year, bool writeTags = true, bool move = true}) async {
    String? warning;
    final before = byId(t.id) ?? t;
    // a tela pode ter aberto antes de a música mudar de pasta: usa sempre o caminho atual
    var path = before.path;
    if (writeTags) {
      try {
        FileMetadataReader.fixMp4Date(path); // .m4a do YouTube com a data "20180724" quebrava a gravação
        updateMetadata(File(path), (m) {
          m.setTitle(title);
          m.setArtist(artist);
          m.setAlbum(album);
          m.setGenres(genre.isEmpty ? const [] : [genre]);
          if (year != null) m.setYear(DateTime(year));
        });
      } catch (e) {
        warning = 'Salvo no app, mas não deu para gravar nas tags deste arquivo.';
        errorLog.warn('Editar música', 'Tags não gravadas em ${p.basename(path)}', error: e);
      }
    }
    await db.editTrack(t.id!, title: title, artist: artist, album: album, genre: genre, year: year);
    final root = sourceRoot;
    if (move && root != null) {
      // episódio continua em Podcasts/<Programa>/ (nunca vai para Artista/Álbum)
      final target = isPodcastPath(root, path)
          ? podcastTargetPath(root, artist, '${safeFolderName(title)}${p.extension(path).toLowerCase()}')
          : isAudiobookPath(root, path)
              ? audiobookTargetPath(root, artist, '${safeFolderName(album.isEmpty ? title : album)}${p.extension(path).toLowerCase()}')
              : targetPathFor(root, path, artist, album, title: title);
      if (!p.equals(target, path)) {
        if (File(target).existsSync()) {
          warning = 'Já existe um arquivo com esse nome em ${p.relative(p.dirname(target), from: root)}. Não movi.';
        } else {
          await Directory(p.dirname(target)).create(recursive: true);
          await Organizer.moveFile(File(path), target);
          await db.moveTrack(path, target);
          podcastProgress.moved(path, target);
          if (isAudiobookPath(root, path)) {
            _bookMoved(path, target);
          } else {
            _podcastMoved(path, target);
          }
          removeEmptyParents(root, [path]);
          path = target;
        }
      }
    }
    // a releitura não deve achar que mudou
    try {
      await db.db.update('tracks', {'modified_at': File(path).statSync().modified.millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [t.id]);
    } catch (e) {
      errorLog.info('Editar música', 'Não deu para anotar a data nova de ${p.basename(path)} (a próxima leitura relê o arquivo)', e);
    }
    await reload();
    final updated = byId(t.id);
    if (updated != null) {
      player.replaceTrack(updated);
      _visualsAfterRename(before, updated);
    }
    unawaited(fetchMissingCovers().catchError(_coversFailed)); // álbum novo: busca a capa
    return warning;
  }

  /// Corrigiu o artista ou o título: os GIFs automáticos foram buscados com o nome errado (tags do Last.fm,
  /// letra, clima e pesquisas eram de outra música). Refaz os GIFs salvos (os escolhidos à mão ficam),
  /// a roda do GIPHY e as fotos do artista com o nome certo.
  void _visualsAfterRename(Track before, Track after) {
    if (isSpoken(after)) return;
    final (oldTitle, oldArtist) = GifFetcher.namesFor(before);
    final (newTitle, newArtist) = GifFetcher.namesFor(after);
    if (oldTitle.toLowerCase() == newTitle.toLowerCase() && oldArtist.toLowerCase() == newArtist.toLowerCase()) return;
    MoodClues.invalidate(); // o clima automático vem das tags do nome certo
    Styles.invalidate();
    _playerVisuals.removeWhere((k, _) => k.startsWith('${after.id}|'));
    _visualsFailedAt.removeWhere((k, _) => k.startsWith('${after.id}|'));
    visualsEpoch++;
    notifyListeners();
    if (newArtist.toLowerCase() != oldArtist.toLowerCase()) {
      _fetchPhotos(ArtistNames.current.main(after.artist)).then((n) {
        if (n == 0) return;
        visualsEpoch++;
        notifyListeners();
      }).catchError((Object e) {
        errorLog.info('Fotos', 'Busca de fotos do artista falhou', e);
      });
    }
    if (autoGifs) unawaited(gifFetcher.refetchFor(after).catchError(_gifFetchFailed));
  }

  /// Apaga a música do celular (e as pastas de álbum/artista que ficarem vazias).
  /// Devolve false (e avisa no balão) se o Android não deixou apagar o arquivo.
  Future<bool> deleteTrack(Track t) async {
    await player.forgetTrack(t.id); // sai da fila (e solta o arquivo, se estava tocando) antes de apagar
    final f = File(t.path);
    try {
      if (f.existsSync()) await f.delete();
    } on FileSystemException catch (e) {
      errorLog.warn('Apagar música', 'Não deu para apagar "${p.basename(t.path)}"', error: e, balloon: true);
      return false;
    }
    await db.deleteTrack(t.id!);
    if (isAudiobook(t)) bookService.deleteFiles(t.path);
    final root = sourceRoot;
    if (root != null) removeEmptyParents(root, [t.path]);
    await reload();
    return true;
  }

  /// Limpa músicas repetidas: para cada grupo, fica [keep] e as outras cópias são apagadas do celular.
  /// Favorito, playlists, histórico e GIFs fixados passam para a cópia que fica. Devolve quantos arquivos apagou.
  Future<int> removeDuplicates(Map<Track, List<Track>> plan) async {
    var removed = 0;
    final root = sourceRoot;
    for (final entry in plan.entries) {
      final keep = entry.key;
      var fav = keep.favorite;
      for (final t in entry.value) {
        if (t.id == null || t.id == keep.id) continue;
        await player.forgetTrack(t.id);
        fav = fav || t.favorite;
        await db.replaceInPlaylists(t.id!, keep.id!);
        await db.mergeTrackHistory(t.id!, keep.id!);
        try {
          final f = File(t.path);
          if (f.existsSync()) await f.delete();
        } catch (e) {
          // não deu para apagar o arquivo: deixa no banco também e avisa
          errorLog.warn('Repetidas', 'Não apagou ${p.basename(t.path)}', error: e, balloon: true);
          continue;
        }
        await db.deleteTrack(t.id!);
        if (root != null) removeEmptyParents(root, [t.path]);
        removed++;
      }
      if (fav && !keep.favorite) await db.setFavorite(keep.id!, true);
    }
    await reload();
    return removed;
  }

  Organizer organizer({bool cleanNames = true}) =>
      Organizer(sourceRoot: sourceRoot!, mb: MusicBrainzClient(), metadata: metadata, cleanNames: cleanNames);

  /// Depois de mover arquivos, atualiza o banco sem perder favoritas/playlists/histórico.
  Future<void> applyMoves(List<MoveRecord> moves, {bool undo = false}) async {
    for (final m in moves) {
      if (undo) {
        await db.moveTrack(m.to, m.from);
      } else {
        await db.moveTrack(m.from, m.to, artist: m.artist, album: m.album, title: m.title.isEmpty ? null : m.title);
      }
    }
    await rescan();
    final byId = {for (final t in tracks) t.id: t};
    for (final q in player.queue) {
      final u = byId[q.id];
      if (u != null && u.path != q.path) player.replaceTrack(u);
    }
  }

  int? _lastTrackId;

  void _onPlayerChanged() {
    final t = player.current;
    if (t == null || t.id == _lastTrackId) return;
    _lastTrackId = t.id;
    final fresh = byId(t.id) ?? t;
    player.handler?.setFavorite(fresh.favorite);
    // arte inicial = primeiro GIF da música (depois o carrossel avisa a cada troca)
    gifs.gifsFor(fresh).then((g) => nowShowingGif(fresh, g.isEmpty ? null : g.first)).catchError((Object e) {
      errorLog.info('Notificação', 'Não deu para trocar a imagem da notificação', e); // arte é secundária: nunca derruba o player
    });
    // podcast: sem busca de GIFs/fotos de artista de música (o "artista" é o programa); resumo se faltar
    if (isAudiobook(fresh)) {
      ensureBook(fresh);
      return;
    }
    if (isPodcast(fresh)) {
      _ensureSummary(fresh);
      return;
    }
    // fotos do artista: baixadas sozinhas, como os GIFs
    _fetchPhotos(ArtistNames.current.main(fresh.artist)).then((n) {
      if (n == 0) return;
      visualsEpoch++; // a roda do Tocando agora ganha as fotos novas
      notifyListeners();
    }).catchError((Object e) {
      errorLog.info('Fotos', 'Busca de fotos do artista falhou', e);
    });
    if (InfoRetry.missing(fresh) && _infoDue(fresh)) {
      // sem artista/álbum: tenta as informações primeiro; se vierem, o editar já refaz os GIFs com o nome certo
      unawaited(retryInfo(fresh).then((renamed) {
        if (!renamed) _autoGifsFor(t.id, byId(t.id) ?? fresh);
      }).catchError((Object e) {
        errorLog.info('Informações', 'Nova tentativa de buscar artista/álbum falhou', e);
        _autoGifsFor(t.id, fresh);
      }));
      return;
    }
    _autoGifsFor(t.id, fresh);
  }

  /// Fotos do artista, se a aba Internet deixa.
  Future<int> _fetchPhotos(String artist) => net.allows(NetFeature.photos) ? artistPhotos.fetch(artist) : Future.value(0);

  void _autoGifsFor(int? id, Track fresh) {
    if (!autoGifs || id == _lastAutoFetchId || !net.allows(NetFeature.gifs)) return;
    _lastAutoFetchId = id;
    gifFetcher.fetchFor(fresh).catchError(_gifFetchFailed);
  }

  // ---------- informações que faltaram (artista/álbum) ----------
  (int, DateTime?) _infoTries(Track t) {
    final raw = prefs.getString('infoTry:${t.path}');
    final parts = raw?.split('|');
    if (parts == null || parts.length != 2) return (0, null);
    final ms = int.tryParse(parts[1]);
    return (int.tryParse(parts[0]) ?? 0, ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms));
  }

  bool _infoDue(Track t) {
    final (tries, last) = _infoTries(t);
    return InfoRetry.due(tries, last, DateTime.now());
  }

  bool _retryingInfo = false;

  /// Tenta de novo achar artista/álbum de uma música que ficou sem (MusicBrainz, com a pasta e o nome do
  /// arquivo como pista). Se achar, grava como o Editar faz: tags, pasta Artista/Álbum e GIFs refeitos.
  /// Devolve true se o artista ou o título mudou (aí os GIFs já foram refeitos). Sem internet não conta como tentativa (tenta na próxima vez que tocar).
  Future<bool> retryInfo(Track t) async {
    if (_retryingInfo || isSpoken(t) || !net.allows(NetFeature.info)) return false;
    _retryingInfo = true;
    try {
      final hints = InfoRetry.hints(t, root: sourceRoot);
      final (tries, _) = _infoTries(t);
      SongInfo? found;
      var reached = true;
      if (hints.isNotEmpty) {
        try {
          found = await MusicBrainzClient().lookupSmart(t.title, artist: hints.first, moreHints: hints.skip(1).toList());
        } catch (e) {
          reached = false; // sem internet / MusicBrainz ocupado
          errorLog.info('Informações', 'MusicBrainz não respondeu (${t.title}); tento de novo depois', e);
        }
      }
      final change = InfoRetry.decide(t, found, hints);
      if (reached || change != null) {
        await prefs.setString('infoTry:${t.path}', '${tries + 1}|${DateTime.now().millisecondsSinceEpoch}');
      }
      if (change == null) return false;
      if (change.artist == t.artist && change.album == t.album && change.title == t.title) return false;
      final warning = await editTrack(t, title: change.title, artist: change.artist, album: change.album, genre: t.genre, year: t.year);
      if (warning != null) errorLog.info('Informações', warning);
      return change.artist.toLowerCase() != t.artist.toLowerCase() || change.title.toLowerCase() != t.title.toLowerCase();
    } finally {
      _retryingInfo = false;
    }
  }

  /// Ao abrir o app: tenta de novo as informações de poucas músicas que ficaram sem (no máximo [max],
  /// uma por vez, no ritmo do MusicBrainz). As outras esperam a vez delas ou tocar.
  Future<void> retryMissingInfo({int max = 5}) async {
    var done = 0;
    for (final t in List.of(tracks)) {
      if (done >= max) break;
      if (isSpoken(t) || !InfoRetry.missing(t) || !_infoDue(t)) continue;
      if (InfoRetry.hints(t, root: sourceRoot).isEmpty) continue; // sem pista nenhuma: só tentaria adivinhar
      done++;
      await retryInfo(t);
    }
  }

  /// O carrossel avisa qual GIF está passando; ele vira a arte da notificação e da tela de bloqueio.
  Future<void> nowShowingGif(Track t, String? gif) async {
    if (player.current?.id != t.id) return;
    if (gif != null && gif.startsWith('http')) return; // GIF do GIPHY (não salvo): mantém a arte anterior
    // sem GIF: usa a capa do álbum
    await player.handler?.setArtwork(t.path, gif ?? covers.fileFor(t)?.path, cacheDir: dataDir);
  }

  /// Baixa GIFs para todas as músicas que ainda não têm 9.
  /// Com [only], baixa só para essas (ex.: músicas que acabaram de entrar na biblioteca).
  Future<int> fetchGifsForAll({List<Track>? only}) async {
    if (!net.allows(NetFeature.gifs)) return 0;
    if (bulkGifProgress != null) {
      if (only != null) _pending.addAll(only);
      return 0;
    }
    final list = List.of(only ?? tracks);
    var total = 0;
    _cancelBulk = false;
    bulkGifProgress = (0, list.length);
    notifyListeners();
    try {
      for (var i = 0; i < list.length; i++) {
        if (_cancelBulk) break;
        total += await gifFetcher.fetchFor(list[i], bulk: true).catchError(_gifFetchFailed);
        bulkGifProgress = (i + 1, list.length);
        notifyListeners();
      }
    } finally {
      bulkGifProgress = null;
      notifyListeners();
    }
    if (_pending.isNotEmpty && !_cancelBulk) {
      final next = List.of(_pending);
      _pending.clear();
      total += await fetchGifsForAll(only: next);
    }
    return total;
  }

  void cancelBulkGifs() => _cancelBulk = true;

  Future<void> toggleFavorite(Track t) async {
    await db.setFavorite(t.id!, !t.favorite);
    await reload();
    if (player.current?.id == t.id) player.handler?.setFavorite(!t.favorite);
    // curtiu: a fila (aleatório / mix) passa a trazer mais parecidas
    if (!t.favorite && player.adaptive) await player.pullSimilarForward(t, tracks);
  }

  /// Clima escolhido no selo do GIF. A música entra na playlist com o nome do clima (ex.: "Triste"),
  /// sai da playlist do clima antigo, ganha GIFs novos e, se guia o mix, o mix é refeito.
  /// [mood] null = automático (pistas: tags do Last.fm, título, escolhas, gênero).
  Future<void> setMood(Track t, Mood? mood) async {
    final id = t.id;
    if (id == null) return;
    final old = (byId(id) ?? t).chosenMood;
    if (old == mood) return;
    await db.setMood(id, mood?.name ?? '');
    if (old != null) {
      final pl = _playlistNamed(old.label);
      if (pl != null) await db.removeFromPlaylist(pl.id, id);
    }
    if (mood != null) {
      final pl = _playlistNamed(mood.label);
      final plId = pl?.id ?? await db.createPlaylist(mood.label);
      final inside = await db.playlistTracks(plId);
      if (!inside.any((x) => x.id == id)) await db.addToPlaylist(plId, id);
    }
    await reload();
    final updated = byId(id);
    if (updated == null) return;
    player.replaceTrack(updated);
    if (player.mixSeedId == id) unawaited(player.refreshMix());
    unawaited(gifFetcher.refetchFor(updated).catchError(_gifFetchFailed));
  }

  Playlist? _playlistNamed(String name) {
    for (final pl in playlists) {
      if (pl.name.trim().toLowerCase() == name.toLowerCase()) return pl;
    }
    return null;
  }

  /// Música pelo id. Usa um índice refeito só quando a lista de músicas muda
  /// (as telas chamam isto para cada linha; a busca linear deixava listas grandes lentas).
  Track? byId(int? id) {
    if (id == null) return null;
    if (!identical(_indexed, tracks) || !identical(_indexedPods, podcasts) || !identical(_indexedBooks, audiobooks)) {
      _indexed = tracks;
      _indexedPods = podcasts;
      _indexedBooks = audiobooks;
      _byId = {for (final t in [...tracks, ...podcasts, ...audiobooks]) if (t.id != null) t.id!: t};
    }
    return _byId[id];
  }

  List<Track>? _indexed;
  List<Track>? _indexedPods;
  List<Track>? _indexedBooks;
  Map<int, Track> _byId = const {};

  Future<Recommender> recommender() async => Recommender(tracks, await db.plays());

  /// Resumo do histórico (plays e última vez por música), guardado até a próxima música ser registrada.
  // ---------- espaço (teto dos GIFs) ----------

  /// Teto em MB para GIFs + fotos dos artistas. 0 = sem limite.
  int get storageCapMb => prefs.getInt('storageCapMb') ?? defaultStorageCapMb;

  Future<void> setStorageCapMb(int mb) async {
    await prefs.setInt('storageCapMb', mb);
    notifyListeners();
    unawaited(autoClean());
  }

  bool _wasOnline = true;
  void _onNetChanged() {
    final on = net.online;
    if (on && !_wasOnline) {
      unawaited(fetchMissingCovers().catchError(_coversFailed));
      unawaited(fillArtistTags().then((_) => fillTrackFacts()));
    }
    _wasOnline = on;
    notifyListeners();
  }

  int _lastGifCount = 0;
  Timer? _cleanTimer;

  /// Chegaram GIFs novos: confere o teto 3 min depois (vários downloads seguidos viram uma conferência só).
  void _onGifCountChanged() {
    final n = gifs.count;
    final grew = n > _lastGifCount;
    _lastGifCount = n;
    if (!grew) return;
    _cleanTimer?.cancel();
    _cleanTimer = Timer(const Duration(minutes: 3), () => unawaited(autoClean()));
  }

  /// Apaga GIFs sem música e o cache e, se passou do teto, os GIFs automáticos das músicas
  /// ouvidas há mais tempo (nunca das favoritas, da que está tocando nem os escolhidos à mão).
  Future<CleanResult> autoClean() async {
    if (gifs.gifRoot == null) return const CleanResult(0, 0, 0);
    try {
      final stats = await playStats();
      final current = player.current?.id;
      final r = await storage.clean(
        capBytes: storageCapMb * 1024 * 1024,
        tracks: tracks,
        lastPlayed: stats.lastPlayed,
        protect: {?current},
      );
      if (r.deletedGifs > 0 || r.trimmedTracks > 0) {
        errorLog.info('Espaço', 'Limpeza: ${formatBytes(r.freedBytes)} liberados, ${r.deletedGifs} GIFs apagados'
            '${r.trimmedTracks > 0 ? ', ${r.trimmedTracks} músicas voltam a baixar GIFs quando tocarem' : ''}');
        await gifs.refresh();
        _lastGifCount = gifs.count;
        notifyListeners();
      }
      return r;
    } catch (e) {
      errorLog.warn('Espaço', 'Não deu para conferir o espaço dos GIFs', error: e);
      return const CleanResult(0, 0, 0);
    }
  }

  PlayStats? _stats;
  Future<PlayStats>? _statsLoading;

  /// Muda quando o histórico muda (as telas recalculam ordem por plays e coleções automáticas).
  final ValueNotifier<int> statsVersion = ValueNotifier(0);

  PlayStats get playStatsNow => _stats ?? PlayStats.empty;

  Future<PlayStats> playStats() {
    final s = _stats;
    if (s != null) return Future.value(s);
    return _statsLoading ??= db.playStats().then((v) {
      _stats = v;
      _statsLoading = null;
      return v;
    });
  }

  void _invalidateStats() {
    _stats = null;
    statsVersion.value++;
  }

  Future<void> createPlaylist(String name) async {
    await db.createPlaylist(name);
    await reload();
  }

  Future<void> addToPlaylist(int playlistId, Track t) async {
    await db.addToPlaylist(playlistId, t.id!);
    await reload();
  }
}
