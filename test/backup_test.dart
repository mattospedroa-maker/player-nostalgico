import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/backup.dart';
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Track t(String root, String rel, String artist, String title) =>
    Track(path: p.join(root, rel), title: title, artist: artist, album: 'A', durationMs: 200000, addedAt: 0, modifiedAt: 0);

void main() {
  sqfliteFfiInit();
  late Directory tmp;
  late String root;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('backup_test');
    root = p.join(tmp.path, 'Musicas');
    Directory(root).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppDb> freshDb(String name) => AppDb.open(p.join(tmp.path, name), factory: databaseFactoryFfi);

  Future<Map<String, int>> fill(AppDb db) async => {
        'numb': await db.upsertTrack(t(root, 'Linkin Park/Meteora/Numb.mp3', 'Linkin Park', 'Numb')),
        'duality': await db.upsertTrack(t(root, 'Slipknot/Vol 3/Duality.mp3', 'Slipknot', 'Duality')),
        'halo': await db.upsertTrack(t(root, 'Beyonce/IAS/Halo.mp3', 'Beyonce', 'Halo')),
      };

  test('app reinstalado recria playlists, favoritos e climas a partir da pasta', () async {
    final old = await freshDb('velho.db');
    final ids = await fill(old);
    final treino = await old.createPlaylist('Treino');
    await old.setPlaylistOrder(treino, [ids['duality']!, ids['numb']!]);
    final calma = await old.createPlaylist('Calma');
    await old.setPlaylistOrder(calma, [ids['halo']!]);
    await old.setFavorite(ids['numb']!, true);
    await old.setMood(ids['halo']!, 'calm');
    await LibraryBackup.save(old, root);
    await old.db.close();

    // .m3u normais, com caminho relativo à pasta Playlists
    final m3u = File(p.join(root, 'Playlists', 'Treino.m3u')).readAsLinesSync();
    expect(m3u.first, '#EXTM3U');
    expect(m3u.where((l) => !l.startsWith('#')), ['../Slipknot/Vol 3/Duality.mp3', '../Linkin Park/Meteora/Numb.mp3']);

    // instalação nova: banco vazio, mesma pasta de músicas (Halo mudou de pasta)
    final db = await freshDb('novo.db');
    await db.upsertTrack(t(root, 'Linkin Park/Meteora/Numb.mp3', 'Linkin Park', 'Numb'));
    await db.upsertTrack(t(root, 'Slipknot/Vol 3/Duality.mp3', 'Slipknot', 'Duality'));
    await db.upsertTrack(t(root, 'Beyonce/Outro/Halo.mp3', 'Beyonce', 'Halo'));
    final r = await LibraryBackup.restore(db, root);
    expect(r.playlists, 2);
    expect(r.missing, 0);
    final pls = await db.playlists();
    expect(pls.map((x) => x.name).toSet(), {'Treino', 'Calma'});
    final tr = pls.firstWhere((x) => x.name == 'Treino');
    expect((await db.playlistTracks(tr.id)).map((x) => x.title), ['Duality', 'Numb']);
    final all = await db.allTracks();
    expect(all.where((x) => x.favorite).map((x) => x.title), ['Numb']);
    expect(all.firstWhere((x) => x.title == 'Halo').mood, 'calm');
    await db.db.close();
  });

  test('playlist apagada some da pasta; .m3u de outro app fica', () async {
    final db = await freshDb('a.db');
    final ids = await fill(db);
    final a = await db.createPlaylist('Apagar');
    await db.addToPlaylist(a, ids['numb']!);
    File(p.join(root, 'Playlists', 'Minha.m3u'))
      ..createSync(recursive: true)
      ..writeAsStringSync('../Beyonce/IAS/Halo.mp3\n');
    await LibraryBackup.save(db, root);
    expect(File(p.join(root, 'Playlists', 'Apagar.m3u')).existsSync(), isTrue);
    await db.deletePlaylist(a);
    await LibraryBackup.save(db, root);
    expect(File(p.join(root, 'Playlists', 'Apagar.m3u')).existsSync(), isFalse);
    expect(File(p.join(root, 'Playlists', 'Minha.m3u')).existsSync(), isTrue);
    await db.db.close();
  });

  test('sem o arquivo do app, importa as .m3u da pasta', () async {
    File(p.join(root, 'Playlists', 'Antiga.m3u'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#EXTM3U\n#EXTINF:200,Beyonce - Halo\n../Beyonce/IAS/Halo.mp3\n../Nao/Existe.mp3\n');
    final db = await freshDb('b.db');
    await fill(db);
    final r = await LibraryBackup.restore(db, root);
    expect(r.playlists, 1);
    expect(r.missing, 1);
    final pl = (await db.playlists()).single;
    expect(pl.name, 'Antiga');
    expect((await db.playlistTracks(pl.id)).map((x) => x.title), ['Halo']);
    await db.db.close();
  });
}
