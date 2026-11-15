import 'dart:async';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'audio_handler.dart';
import 'cover_service.dart';
import 'gif_fetcher.dart';
import 'gif_service.dart';
import 'library_scanner.dart';
import 'metadata.dart';
import 'models.dart';
import 'mood.dart';
import 'organizer.dart';
import 'player_service.dart';
import 'recommender.dart';

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

  /// Baixar GIFs sozinho quando uma música começa a tocar.
  bool get autoGifs => prefs.getBool('autoGifs') ?? true;
  Future<void> setAutoGifs(bool v) async {
    await prefs.setBool('autoGifs', v);
    notifyListeners();
  }

  /// Chave da API do Last.fm (fica só no celular, nunca no código). Vazia = GIFs pelo gênero.
  String get lastFmKey => prefs.getString('lastFmKey') ?? '';
  Future<void> setLastFmKey(String v) async {
    await prefs.setString('lastFmKey', v.trim());
    notifyListeners();
    // a música que está tocando já ganha os GIFs pelas tags
    final t = player.current == null ? null : byId(player.current!.id);
    if (t != null && autoGifs) unawaited(gifFetcher.fetchFor(t).catchError((_) => 0));
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
      ..onMixModeChanged = ((m) => prefs.setString('mixMode', m.name));
    handler?.onFavorite = () async {
      final t = s.player.current == null ? null : s.byId(s.player.current!.id);
      if (t != null) await s.toggleFavorite(t);
    };
    await s.reload();
    // Android 13+: a notificação com os controles precisa desta permissão
    if (Platform.isAndroid) unawaited(Permission.notification.request().catchError((_) => PermissionStatus.denied));
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

  Future<void> reload() async {
    tracks = await db.allTracks();
    playlists = await db.playlists();
    await gifs.refresh();
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
      await LibraryScanner(db, metadata).scan(root, force: force, onProgress: (d, t) {
        scanProgress = t == 0 ? 1 : d / t;
        notifyListeners();
      });
      await prefs.setInt('scanVersion', scanVersion);
    } finally {
      scanning = false;
      await reload();
    }
    // músicas novas na biblioteca: busca GIFs sozinho, em segundo plano
    final added = tracks.where((t) => !before.contains(t.id)).toList();
    unawaited(_afterScan(added));
  }

  /// Primeiro descobre os gêneros que faltam (a regra dos GIFs usa o gênero), depois baixa os GIFs das novas.
  Future<void> _afterScan(List<Track> added) async {
    await fillMissingGenres().catchError((_) => 0);
    unawaited(fetchMissingCovers().catchError((_) => 0));
    if (added.isEmpty || !autoGifs) return;
    final ids = added.map((t) => t.id).toSet();
    await fetchGifsForAll(only: tracks.where((t) => ids.contains(t.id)).toList());
  }

  /// Capas de álbum que faltam (Cover Art Archive), uma vez por álbum.
  Future<int> fetchMissingCovers() async {
    while (fillingGenres) {
      await Future<void>.delayed(const Duration(seconds: 2)); // o MusicBrainz aceita 1 pedido por segundo
    }
    final tried = (prefs.getStringList('coverTried') ?? const []).toSet();
    final n = await covers.fetchMissing(tracks, tried, onEach: notifyListeners);
    await prefs.setStringList('coverTried', tried.toList());
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
        } catch (_) {
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
      } catch (_) {
        warning = 'Salvo no app, mas não deu para gravar nas tags deste arquivo.';
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
    } catch (_) {}
    await reload();
    final updated = byId(t.id);
    if (updated != null) player.replaceTrack(updated);
    return warning;
  }

  /// Apaga a música do celular (e as pastas de álbum/artista que ficarem vazias).
  Future<void> deleteTrack(Track t) async {
    if (player.current?.id == t.id) await player.next();
    final f = File(t.path);
    if (f.existsSync()) await f.delete();
    await db.deleteTrack(t.id!);
    final root = sourceRoot;
    if (root != null) removeEmptyParents(root, [t.path]);
    await reload();
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
    gifs.gifsFor(fresh).then((g) => nowShowingGif(fresh, g.isEmpty ? null : g.first));
    if (!autoGifs || t.id == _lastAutoFetchId) return;
    _lastAutoFetchId = t.id;
    gifFetcher.fetchFor(fresh).catchError((_) => 0);
  }

  /// O carrossel avisa qual GIF está passando; ele vira a arte da notificação e da tela de bloqueio.
  Future<void> nowShowingGif(Track t, String? gif) async {
    if (player.current?.id != t.id) return;
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
        total += await gifFetcher.fetchFor(list[i], bulk: true).catchError((_) => 0);
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
    unawaited(gifFetcher.refetchFor(updated).catchError((_) => 0));
  }

  Playlist? _playlistNamed(String name) {
    for (final pl in playlists) {
      if (pl.name.trim().toLowerCase() == name.toLowerCase()) return pl;
    }
    return null;
  }

  Track? byId(int? id) {
    for (final t in tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<Recommender> recommender() async => Recommender(tracks, await db.plays());

  Future<void> createPlaylist(String name) async {
    await db.createPlaylist(name);
    await reload();
  }

  Future<void> addToPlaylist(int playlistId, Track t) async {
    await db.addToPlaylist(playlistId, t.id!);
    await reload();
  }
}
