import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'gif_fetcher.dart';
import 'gif_service.dart';
import 'library_scanner.dart';
import 'metadata.dart';
import 'models.dart';
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
  late final GifFetcher gifFetcher = GifFetcher(gifs, client: http.Client());
  int? _lastAutoFetchId;

  /// Baixar GIFs sozinho quando uma música começa a tocar.
  bool get autoGifs => prefs.getBool('autoGifs') ?? true;
  Future<void> setAutoGifs(bool v) async {
    await prefs.setBool('autoGifs', v);
    notifyListeners();
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

  static Future<AppState> create() async {
    final dir = await getApplicationSupportDirectory();
    final db = await AppDb.open(p.join(dir.path, 'player.db'));
    final prefs = await SharedPreferences.getInstance();
    final s = AppState._(db, prefs, PlayerService(db), GifService(db), dir.path);
    s.gifs.sourceRoot = s.sourceRoot;
    s.player.addListener(s._onPlayerChanged);
    await s.reload();
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
    if (added.isNotEmpty && autoGifs) unawaited(fetchGifsForAll(only: added));
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

  void _onPlayerChanged() {
    final t = player.current;
    if (t == null || t.id == _lastAutoFetchId || !autoGifs) return;
    _lastAutoFetchId = t.id;
    final fresh = byId(t.id) ?? t;
    gifFetcher.fetchFor(fresh).catchError((_) => 0);
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
