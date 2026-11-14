import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'gif_service.dart';
import 'library_scanner.dart';
import 'metadata.dart';
import 'models.dart';
import 'organizer.dart';
import 'player_service.dart';
import 'recommender.dart';

/// Estado central do app: pasta-fonte, biblioteca, playlists e serviços.
class AppState extends ChangeNotifier {
  final AppDb db;
  final SharedPreferences prefs;
  final PlayerService player;
  final GifService gifs;
  final MetadataReader metadata = const FileMetadataReader();
  final String dataDir;

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
    notifyListeners();
    try {
      await LibraryScanner(db, metadata).scan(root, onProgress: (d, t) {
        scanProgress = t == 0 ? 1 : d / t;
        notifyListeners();
      });
    } finally {
      scanning = false;
      await reload();
    }
  }

  Organizer organizer() => Organizer(sourceRoot: sourceRoot!, mb: MusicBrainzClient(), metadata: metadata);

  /// Depois de mover arquivos, atualiza o banco sem perder favoritas/playlists/histórico.
  Future<void> applyMoves(List<MoveRecord> moves, {bool undo = false}) async {
    for (final m in moves) {
      if (undo) {
        await db.moveTrack(m.to, m.from);
      } else {
        await db.moveTrack(m.from, m.to, artist: m.artist, album: m.album);
      }
    }
    await rescan();
    final byId = {for (final t in tracks) t.id: t};
    for (final q in player.queue) {
      final u = byId[q.id];
      if (u != null && u.path != q.path) player.replaceTrack(u);
    }
  }

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
