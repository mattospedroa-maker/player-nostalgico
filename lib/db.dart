import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Banco local (SQLite). Guarda faixas, playlists, histórico e GIFs fixados.
class AppDb {
  final Database db;
  AppDb._(this.db);

  static Future<AppDb> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE tracks(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              path TEXT NOT NULL UNIQUE,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              album TEXT NOT NULL,
              genre TEXT NOT NULL DEFAULT '',
              year INTEGER,
              duration_ms INTEGER NOT NULL DEFAULT 0,
              favorite INTEGER NOT NULL DEFAULT 0,
              added_at INTEGER NOT NULL,
              modified_at INTEGER NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE playlists(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE playlist_tracks(
              playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
              track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
              position INTEGER NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE plays(
              track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
              played_at INTEGER NOT NULL,
              seconds INTEGER NOT NULL,
              skipped INTEGER NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE track_gifs(
              track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
              gif_path TEXT NOT NULL,
              PRIMARY KEY(track_id, gif_path)
            )''');
          await db.execute('CREATE INDEX plays_track ON plays(track_id)');
        },
      ),
    );
    return AppDb._(db);
  }

  // ---------- faixas ----------
  Future<List<Track>> allTracks() async =>
      (await db.query('tracks', orderBy: 'artist COLLATE NOCASE, album COLLATE NOCASE, title COLLATE NOCASE'))
          .map(Track.fromMap)
          .toList();

  Future<Map<String, Track>> tracksByPath() async => {for (final t in await allTracks()) t.path: t};

  Future<int> upsertTrack(Track t) async {
    final existing = await db.query('tracks', columns: ['id', 'favorite', 'added_at'], where: 'path = ?', whereArgs: [t.path]);
    if (existing.isEmpty) return db.insert('tracks', t.toMap()..remove('id'));
    final id = existing.first['id'] as int;
    final m = t.toMap()
      ..remove('id')
      ..['favorite'] = existing.first['favorite']
      ..['added_at'] = existing.first['added_at'];
    await db.update('tracks', m, where: 'id = ?', whereArgs: [id]);
    return id;
  }

  Future<void> deleteTracksNotIn(Set<String> paths) async {
    final all = await db.query('tracks', columns: ['id', 'path']);
    final batch = db.batch();
    for (final r in all) {
      if (!paths.contains(r['path'])) batch.delete('tracks', where: 'id = ?', whereArgs: [r['id']]);
    }
    await batch.commit(noResult: true);
  }

  /// Atualiza o caminho (e artista/álbum) depois que o organizador moveu o arquivo.
  Future<void> moveTrack(String oldPath, String newPath, {String? artist, String? album, String? title}) async {
    await db.update(
      'tracks',
      {'path': newPath, 'artist': ?artist, 'album': ?album, 'title': ?title},
      where: 'path = ?',
      whereArgs: [oldPath],
    );
  }

  Future<void> setFavorite(int trackId, bool fav) =>
      db.update('tracks', {'favorite': fav ? 1 : 0}, where: 'id = ?', whereArgs: [trackId]);

  // ---------- playlists ----------
  Future<List<Playlist>> playlists() async {
    final rows = await db.rawQuery('''
      SELECT p.id, p.name, COUNT(pt.track_id) AS n
      FROM playlists p LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
      GROUP BY p.id ORDER BY p.created_at DESC''');
    return rows.map((r) => Playlist(id: r['id'] as int, name: r['name'] as String, trackCount: r['n'] as int)).toList();
  }

  Future<int> createPlaylist(String name) =>
      db.insert('playlists', {'name': name, 'created_at': DateTime.now().millisecondsSinceEpoch});

  Future<void> renamePlaylist(int id, String name) =>
      db.update('playlists', {'name': name}, where: 'id = ?', whereArgs: [id]);

  Future<void> deletePlaylist(int id) => db.delete('playlists', where: 'id = ?', whereArgs: [id]);

  Future<List<Track>> playlistTracks(int id) async => (await db.rawQuery('''
      SELECT t.* FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id
      WHERE pt.playlist_id = ? ORDER BY pt.position''', [id])).map(Track.fromMap).toList();

  Future<void> addToPlaylist(int playlistId, int trackId) async {
    final r = await db.rawQuery('SELECT COALESCE(MAX(position), -1) + 1 AS p FROM playlist_tracks WHERE playlist_id = ?', [playlistId]);
    await db.insert('playlist_tracks', {'playlist_id': playlistId, 'track_id': trackId, 'position': r.first['p'] as int});
  }

  Future<void> setPlaylistOrder(int playlistId, List<int> trackIds) async {
    await db.transaction((tx) async {
      await tx.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [playlistId]);
      for (var i = 0; i < trackIds.length; i++) {
        await tx.insert('playlist_tracks', {'playlist_id': playlistId, 'track_id': trackIds[i], 'position': i});
      }
    });
  }

  // ---------- histórico ----------
  Future<void> logPlay(int trackId, int seconds, bool skipped) => db.insert('plays', {
        'track_id': trackId,
        'played_at': DateTime.now().millisecondsSinceEpoch,
        'seconds': seconds,
        'skipped': skipped ? 1 : 0,
      });

  Future<List<Play>> plays({int? sinceMs}) async {
    final rows = await db.query('plays',
        where: sinceMs == null ? null : 'played_at >= ?', whereArgs: sinceMs == null ? null : [sinceMs], orderBy: 'played_at');
    return rows
        .map((r) => Play(
              trackId: r['track_id'] as int,
              playedAt: r['played_at'] as int,
              secondsListened: r['seconds'] as int,
              skipped: (r['skipped'] as int) == 1,
            ))
        .toList();
  }

  // ---------- GIFs fixados ----------
  Future<List<String>> pinnedGifs(int trackId) async =>
      (await db.query('track_gifs', where: 'track_id = ?', whereArgs: [trackId])).map((r) => r['gif_path'] as String).toList();

  Future<void> pinGif(int trackId, String gifPath) =>
      db.insert('track_gifs', {'track_id': trackId, 'gif_path': gifPath}, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> deleteGifEverywhere(String gifPath) => db.delete('track_gifs', where: 'gif_path = ?', whereArgs: [gifPath]);

  Future<void> unpinGif(int trackId, String gifPath) =>
      db.delete('track_gifs', where: 'track_id = ? AND gif_path = ?', whereArgs: [trackId, gifPath]);
}
