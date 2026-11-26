import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'db.dart';
import 'models.dart';

/// Cópia das playlists, favoritos e climas escolhidos numa pasta da própria biblioteca
/// (pasta de músicas/Playlists). O banco do app some quando o app é desinstalado; esta pasta não.
/// Ao instalar de novo e escolher a mesma pasta de músicas, o app recria tudo a partir dela.
///
/// - Uma .m3u por playlist (abre em qualquer player, caminhos relativos à pasta Playlists).
/// - .nostalgic-mplayer.json com tudo (playlists, favoritos, climas), usado na restauração.
class LibraryBackup {
  static const folderName = 'Playlists';
  static const dataFileName = '.nostalgic-mplayer.json';

  static String folderOf(String root) => p.join(root, folderName);
  static File dataFileOf(String root) => File(p.join(folderOf(root), dataFileName));

  static bool exists(String root) {
    final dir = Directory(folderOf(root));
    if (dataFileOf(root).existsSync()) return true;
    return dir.existsSync() && dir.listSync().any((e) => e is File && _isM3u(e.path));
  }

  /// Grava o retrato atual do banco na pasta.
  static Future<void> save(AppDb db, String root) async {
    final dir = Directory(folderOf(root));
    await dir.create(recursive: true);
    final tracks = await db.allTracks();
    final lists = <Map<String, Object?>>[];
    final written = <String>[];
    final used = <String>{};
    for (final pl in (await db.playlists()).reversed) {
      final items = await db.playlistTracks(pl.id);
      lists.add({'name': pl.name, 'tracks': [for (final t in items) _ref(t, root)]});
      final file = _uniqueName(pl.name, used);
      await _writeM3u(File(p.join(dir.path, file)), items);
      written.add(file);
    }
    // .m3u de playlists que foram apagadas ou renomeadas (só as que o próprio app escreveu antes)
    for (final old in _previousM3u(root)) {
      if (written.contains(old)) continue;
      final f = File(p.join(dir.path, old));
      if (f.existsSync()) await f.delete();
    }
    final data = {
      'app': 'Nostalgic MPlayer',
      'version': 1,
      'savedAt': DateTime.now().toIso8601String(),
      'playlists': lists,
      'favorites': [for (final t in tracks) if (t.favorite) _ref(t, root)],
      'moods': [for (final t in tracks) if (t.mood.isNotEmpty) {..._ref(t, root), 'mood': t.mood}],
      // aba "Estilo": estilos postos/tirados e réguas arrastadas à mão
      'styles': [
        for (final t in tracks)
          if (t.stylesEdit.isNotEmpty || t.energy != null)
            {..._ref(t, root), if (t.stylesEdit.isNotEmpty) 'edit': t.stylesEdit, if (t.energy != null) 'energy': t.energy, if (t.humor != null) 'humor': t.humor}
      ],
      'm3u': written,
    };
    final tmp = File('${dataFileOf(root).path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(data));
    await tmp.rename(dataFileOf(root).path);
  }

  /// Recria playlists, favoritos e climas a partir da pasta. Chamar com o banco recém-criado
  /// (depois da primeira leitura das músicas). Sem o .json, importa as .m3u que houver na pasta.
  static Future<RestoreResult> restore(AppDb db, String root) async {
    final tracks = await db.allTracks();
    final finder = _Finder(tracks, root);
    final r = RestoreResult();
    final existing = {for (final pl in await db.playlists()) pl.name.trim().toLowerCase()};
    final dataFile = dataFileOf(root);
    if (dataFile.existsSync()) {
      final data = jsonDecode(await dataFile.readAsString()) as Map<String, dynamic>;
      for (final pl in (data['playlists'] as List? ?? const [])) {
        final name = '${pl['name']}';
        final ids = <int>[];
        for (final ref in (pl['tracks'] as List? ?? const [])) {
          final t = finder.find(ref as Map);
          if (t == null) {
            r.missing++;
          } else if (!ids.contains(t.id)) {
            ids.add(t.id!);
          }
        }
        if (existing.contains(name.trim().toLowerCase())) continue;
        final id = await db.createPlaylist(name);
        await db.setPlaylistOrder(id, ids);
        r.playlists++;
      }
      for (final ref in (data['favorites'] as List? ?? const [])) {
        final t = finder.find(ref as Map);
        if (t == null) continue;
        await db.setFavorite(t.id!, true);
        r.favorites++;
      }
      for (final ref in (data['moods'] as List? ?? const [])) {
        final t = finder.find(ref as Map);
        final mood = '${ref['mood'] ?? ''}';
        if (t == null || mood.isEmpty) continue;
        await db.setMood(t.id!, mood);
        r.moods++;
      }
      for (final ref in (data['styles'] as List? ?? const [])) {
        final t = finder.find(ref as Map);
        if (t == null) continue;
        final edit = ref['edit'];
        if (edit is String && edit.isNotEmpty) await db.setStylesEdit(t.id!, edit);
        final e = ref['energy'], h = ref['humor'];
        if (e is int && h is int) await db.setVibe(t.id!, e, h);
      }
      return r;
    }
    final dir = Directory(folderOf(root));
    if (!dir.existsSync()) return r;
    final files = dir.listSync().whereType<File>().where((f) => _isM3u(f.path)).toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = p.basenameWithoutExtension(f.path);
      if (existing.contains(name.trim().toLowerCase())) continue;
      final ids = <int>[];
      for (final line in await f.readAsLines()) {
        final l = line.trim();
        if (l.isEmpty || l.startsWith('#')) continue;
        final abs = p.normalize(p.isAbsolute(l) ? l : p.join(dir.path, l));
        final t = finder.find({'path': p.relative(abs, from: root)});
        if (t == null) {
          r.missing++;
        } else if (!ids.contains(t.id)) {
          ids.add(t.id!);
        }
      }
      final id = await db.createPlaylist(name);
      await db.setPlaylistOrder(id, ids);
      r.playlists++;
    }
    return r;
  }

  static Map<String, Object?> _ref(Track t, String root) =>
      {'path': p.relative(t.path, from: root), 'artist': t.artist, 'title': t.title};

  static Future<void> _writeM3u(File f, List<Track> items) async {
    final b = StringBuffer('#EXTM3U\n');
    for (final t in items) {
      b
        ..writeln('#EXTINF:${t.durationMs ~/ 1000},${t.artist} - ${t.title}')
        ..writeln(p.relative(t.path, from: f.parent.path).replaceAll(r'\', '/'));
    }
    await f.writeAsString(b.toString());
  }

  static List<String> _previousM3u(String root) {
    try {
      final data = jsonDecode(dataFileOf(root).readAsStringSync()) as Map<String, dynamic>;
      return [for (final n in (data['m3u'] as List? ?? const [])) '$n'];
    } catch (_) {
      return const []; // primeira vez (ou arquivo estragado): não apaga nada
    }
  }

  static String _uniqueName(String name, Set<String> used) {
    var base = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (base.isEmpty || base.startsWith('.')) base = 'Playlist$base';
    var file = '$base.m3u';
    for (var i = 2; used.contains(file.toLowerCase()); i++) {
      file = '$base ($i).m3u';
    }
    used.add(file.toLowerCase());
    return file;
  }

  static bool _isM3u(String path) {
    final e = p.extension(path).toLowerCase();
    return e == '.m3u' || e == '.m3u8';
  }
}

class RestoreResult {
  int playlists = 0, favorites = 0, moods = 0, missing = 0;
  bool get any => playlists + favorites + moods > 0;
}

/// Acha a música do backup no banco novo: pelo caminho; se o arquivo mudou de lugar, por artista + título.
class _Finder {
  final String root;
  final Map<String, Track> _byPath = {};
  final Map<String, Track> _byName = {};
  final Map<String, Track> _byFile = {};

  _Finder(List<Track> tracks, this.root) {
    for (final t in tracks) {
      if (t.id == null) continue;
      _byPath[_norm(p.relative(t.path, from: root))] = t;
      _byName.putIfAbsent(_key(t.artist, t.title), () => t);
      _byFile.putIfAbsent(p.basename(t.path).toLowerCase(), () => t);
    }
  }

  Track? find(Map ref) {
    final path = ref['path'] as String?;
    if (path != null) {
      final t = _byPath[_norm(path)];
      if (t != null) return t;
    }
    final artist = ref['artist'] as String?, title = ref['title'] as String?;
    if (artist != null && title != null) {
      final t = _byName[_key(artist, title)];
      if (t != null) return t;
    }
    return path == null ? null : _byFile[p.basename(path.replaceAll(r'\', '/')).toLowerCase()];
  }

  static String _norm(String path) => p.normalize(path).replaceAll(r'\', '/').toLowerCase();
  static String _key(String artist, String title) => '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';
}
