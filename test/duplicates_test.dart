import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:player_nostalgico/duplicates.dart';
import 'package:player_nostalgico/models.dart';

Track t(String title, String artist, {String album = 'A', String path = '', bool fav = false, int added = 0}) => Track(
    path: path.isEmpty ? '/m/$artist/$album/$title.mp3' : path,
    title: title,
    artist: artist,
    album: album,
    favorite: fav,
    addedAt: added,
    modifiedAt: 0);

void main() {
  test('mesma música com grafias diferentes', () {
    expect(songKey('Nirvana', 'Where Did You Sleep Last Night'), songKey('NIRVANA', 'Where did you sleep last night?'));
    expect(songKey('Linkin Park', 'Numb'), songKey('Linkin Park & Jay-Z', 'Numb (feat. Jay-Z)'));
    expect(songKey('The Beatles', 'Help!'), songKey('Beatles', 'Help! (Remastered 2009)'));
    expect(songKey('Beyoncé', 'Halo'), songKey('Beyonce', 'Halo'));
  });

  test('ao vivo, remix e acústica são outra versão', () {
    final base = songKey('Nirvana', 'Where Did You Sleep Last Night');
    expect(songKey('Nirvana', 'Where Did You Sleep Last Night [Live]'), isNot(base));
    expect(songKey('Nirvana', 'Where Did You Sleep Last Night (Live)'), songKey('Nirvana', 'Where Did You Sleep Last Night [Live]'));
    expect(songKey('Linkin Park', 'Numb (Remix)'), isNot(songKey('Linkin Park', 'Numb')));
    expect(songKey('Linkin Park', 'Numb (Acoustic)'), isNot(songKey('Linkin Park', 'Numb')));
  });

  test('agrupa repetidas e põe a melhor cópia primeiro', () {
    final groups = findDuplicateGroups([
      t('Where Did You Sleep Last Night', 'Nirvana', album: unknownAlbum, added: 1),
      t('Where Did You Sleep Last Night', 'Nirvana', album: 'MTV Unplugged in New York', added: 3),
      t('Where Did You Sleep Last Night', 'Nirvana', album: unknownAlbum, path: '/m/x (2).mp3', added: 2),
      t('Where Did You Sleep Last Night [Live]', 'Nirvana'),
      t('When the Sun Hits', 'Slowdive'),
      t('Numb', 'Linkin Park'),
      t('When the Sun Hits', 'Slowdive', album: unknownAlbum),
    ]);
    expect(groups.length, 2);
    final nirvana = groups.firstWhere((g) => g.first.artist == 'Nirvana');
    expect(nirvana.length, 3);
    expect(nirvana.first.album, 'MTV Unplugged in New York');
    expect(nirvana.last.path, '/m/x (2).mp3');
    expect(groups.firstWhere((g) => g.first.artist == 'Slowdive').first.album, 'A');
  });

  test('favorita ganha de cópia sem favorito', () {
    final r = rankCopies([t('Numb', 'Linkin Park', added: 1), t('Numb', 'Linkin Park', fav: true, added: 2)], kbps: (_) => 192);
    expect(r.first.favorite, isTrue);
  });

  test('playlists passam para a cópia que fica, sem repetir', () async {
    sqfliteFfiInit();
    final db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
    final keep = await db.upsertTrack(t('Numb', 'Linkin Park', path: '/a.mp3'));
    final dup = await db.upsertTrack(t('Numb', 'Linkin Park', path: '/b.mp3'));
    final other = await db.upsertTrack(t('Duality', 'Slipknot', path: '/c.mp3'));
    final p1 = await db.createPlaylist('Só a cópia');
    final p2 = await db.createPlaylist('As duas');
    await db.addToPlaylist(p1, other);
    await db.addToPlaylist(p1, dup);
    await db.addToPlaylist(p2, keep);
    await db.addToPlaylist(p2, dup);
    await db.replaceInPlaylists(dup, keep);
    expect((await db.playlistTracks(p1)).map((x) => x.path), ['/c.mp3', '/a.mp3']);
    expect((await db.playlistTracks(p2)).map((x) => x.path), ['/a.mp3']);
    await db.db.close();
  });
}
