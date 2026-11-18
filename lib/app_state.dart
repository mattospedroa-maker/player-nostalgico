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
import 'cover_service.dart';
import 'crossfade.dart';
import 'db.dart';
import 'download_service.dart';
import 'error_log.dart';
import 'filename_parser.dart';
import 'gif_fetcher.dart';
import 'gif_providers.dart';
import 'gif_service.dart';
import 'library_scanner.dart';
import 'metadata.dart';
import 'models.dart';
import 'mood.dart';
import 'organizer.dart';
import 'play_stats.dart';
import 'player_service.dart';
import 'recommender.dart';
import 'visual_search.dart';

/// Estado central do app: pasta-fonte, biblioteca, playlists e serviços.
/// Suba quando a leitura de nomes/tags mudar, para reler a biblioteca toda.
const scanVersion = 2;

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
    if (t != null && autoGifs) unawaited(gifFetcher.fetchFor(t).catchError(_gifFetchFailed));
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
    if (gifSource == GifSource.anime || giphyKey.isEmpty || t.id == null) return Future.value(const []);
    final key = '${t.id}|${t.mood}|${gifSource.name}|v2'; // v2: sorteio por música (menos repetição no álbum)
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

  List<Track> tracks = const [];
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
      ..mixMode = MixMode.values.asNameMap()[prefs.getString('mixMode')] ?? MixMode.vibe
      ..onMixModeChanged = ((m) => prefs.setString('mixMode', m.name))
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
    await s.reload(rereadGifs: true);
    // capas que faltam (inclusive as que falharam antes), em segundo plano
    unawaited(Future<void>.delayed(const Duration(seconds: 5), () => s.fetchMissingCovers()).catchError(_coversFailed));
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
    tracks = await db.allTracks();
    ArtistNames.current = ArtistNames.fromTracks(tracks);
    playlists = await db.playlists();
    if (rereadGifs) await gifs.refresh();
    notifyListeners();
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
    if (added.isEmpty || !autoGifs) return;
    final ids = added.map((t) => t.id).toSet();
    await fetchGifsForAll(only: tracks.where((t) => ids.contains(t.id)).toList());
  }

  /// Capas de álbum que faltam (Cover Art Archive), uma vez por álbum.
  Future<int> fetchMissingCovers() async {
    while (fillingGenres) {
      await Future<void>.delayed(const Duration(seconds: 2)); // o MusicBrainz aceita 1 pedido por segundo
    }
    // v2: a versão antiga marcava como "tentado" até quando o MusicBrainz falhava; tenta tudo de novo uma vez
    final tried = (prefs.getStringList('coverTried2') ?? const []).toSet();
    final n = await covers.fetchMissing(tracks, tried, onEach: notifyListeners);
    await prefs.setStringList('coverTried2', tried.toList());
    if (n > 0) notifyListeners();
    return n;
  }

  bool fillingGenres = false;

  /// Gênero/subgênero automático: pergunta ao MusicBrainz uma vez por artista (só onde está vazio).
  Future<int> fillMissingGenres() async {
    if (fillingGenres) return 0;
    final tried = (prefs.getStringList('genreTried') ?? const []).toSet();
    final byArtist = <String, List<Track>>{};
    for (final t in tracks) {
      if (t.genre.isEmpty && t.artist != unknownArtist && t.artist.trim().isNotEmpty && !tried.contains(t.artist)) {
        (byArtist[t.artist] ??= []).add(t);
      }
    }
    if (byArtist.isEmpty) return 0;
    fillingGenres = true;
    notifyListeners();
    var n = 0;
    final mb = MusicBrainzClient();
    try {
      for (final e in byArtist.entries) {
        String? genre;
        try {
          genre = await mb.artistGenre(e.key);
        } catch (err) {
          errorLog.info('Biblioteca', 'MusicBrainz não respondeu (gênero do artista)', err);
          break; // sem internet: tenta na próxima leitura
        }
        tried.add(e.key);
        if (genre == null) continue;
        for (final t in e.value) {
          await db.fillGenre(t.id!, genre);
          n++;
        }
      }
    } finally {
      await prefs.setStringList('genreTried', tried.toList());
      fillingGenres = false;
      await reload();
    }
    return n;
  }

  /// Salva a tela "Editar música": banco, tags do arquivo (opcional) e pasta (opcional).
  /// Retorna um aviso para mostrar, ou null se deu tudo certo.
  Future<String?> editTrack(Track t,
      {required String title, required String artist, required String album, required String genre, int? year, bool writeTags = true, bool move = true}) async {
    String? warning;
    var path = t.path;
    if (writeTags) {
      try {
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
      final target = targetPathFor(root, path, artist, album, title: title);
      if (!p.equals(target, path)) {
        if (File(target).existsSync()) {
          warning = 'Já existe um arquivo com esse nome em ${p.relative(p.dirname(target), from: root)}. Não movi.';
        } else {
          await Directory(p.dirname(target)).create(recursive: true);
          await Organizer.moveFile(File(path), target);
          await db.moveTrack(path, target);
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
    if (updated != null) player.replaceTrack(updated);
    unawaited(fetchMissingCovers().catchError(_coversFailed)); // álbum novo: busca a capa
    return warning;
  }

  /// Apaga a música do celular (e as pastas de álbum/artista que ficarem vazias).
  /// Devolve false (e avisa no balão) se o Android não deixou apagar o arquivo.
  Future<bool> deleteTrack(Track t) async {
    if (player.current?.id == t.id) await player.next(); // solta o arquivo antes de apagar
    final f = File(t.path);
    try {
      if (f.existsSync()) await f.delete();
    } on FileSystemException catch (e) {
      errorLog.warn('Apagar música', 'Não deu para apagar "${p.basename(t.path)}"', error: e, balloon: true);
      return false;
    }
    await db.deleteTrack(t.id!);
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
        if (player.current?.id == t.id) await player.next();
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
    // fotos do artista: baixadas sozinhas, como os GIFs
    artistPhotos.fetch(ArtistNames.current.main(fresh.artist)).then((n) {
      if (n == 0) return;
      visualsEpoch++; // a roda do Tocando agora ganha as fotos novas
      notifyListeners();
    }).catchError((Object e) {
      errorLog.info('Fotos', 'Busca de fotos do artista falhou', e);
    });
    if (!autoGifs || t.id == _lastAutoFetchId) return;
    _lastAutoFetchId = t.id;
    gifFetcher.fetchFor(fresh).catchError(_gifFetchFailed);
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
  /// [mood] null = automático (pelo gênero).
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
    if (!identical(_indexed, tracks)) {
      _indexed = tracks;
      _byId = {for (final t in tracks) if (t.id != null) t.id!: t};
    }
    return _byId[id];
  }

  List<Track>? _indexed;
  Map<int, Track> _byId = const {};

  Future<Recommender> recommender() async => Recommender(tracks, await db.plays());

  /// Resumo do histórico (plays e última vez por música), guardado até a próxima música ser registrada.
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
