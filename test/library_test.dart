import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/library_scanner.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/recommender.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeMeta implements MetadataReader {
  @override
  Future<TagInfo?> read(String path) async =>
      p.basename(path) == 'tagged.mp3' ? const TagInfo(title: 'Melt', artist: 'ryo', album: 'supercell', genre: 'J-Pop') : null;
  @override
  Future<Uint8List?> cover(String path) async => null;
}

void main() {
  sqfliteFfiInit();
  late Directory root;
  late AppDb db;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lib_test');
    db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
  });
  tearDown(() async {
    await db.db.close();
    root.deleteSync(recursive: true);
  });

  File touch(String rel) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  test('varre a pasta, usa tags ou nome do arquivo, ignora GIFs e mantém favorita ao mover', () async {
    touch('tagged.mp3');
    touch('Lucky Star/Motteke - Sailor Fuku.flac');
    touch('GIFs/a.mp3');
    touch('capa.jpg');
    final scanner = LibraryScanner(db, FakeMeta());
    await scanner.scan(root.path);
    final ts = await db.allTracks();
    expect(ts.length, 2);
    final melt = ts.firstWhere((t) => t.title == 'Melt');
    expect(melt.artist, 'ryo');
    final mot = ts.firstWhere((t) => t.title == 'Sailor Fuku');
    expect(mot.artist, 'Motteke');
    expect(mot.album, 'Lucky Star');

    await db.setFavorite(melt.id!, true);
    final pl = await db.createPlaylist('Vocaloid');
    await db.addToPlaylist(pl, melt.id!);

    // organizador moveu o arquivo
    final newPath = p.join(root.path, 'ryo', 'supercell', 'tagged.mp3');
    File(newPath).parent.createSync(recursive: true);
    File(melt.path).renameSync(newPath);
    await db.moveTrack(melt.path, newPath);
    await scanner.scan(root.path);

    final after = (await db.allTracks()).firstWhere((t) => t.title == 'Melt');
    expect(after.path, newPath);
    expect(after.favorite, isTrue);
    expect((await db.playlistTracks(pl)).single.id, after.id);
  });

  test('GIFs: fixados primeiro, depois os da subpasta do artista, depois gerais', () async {
    touch('GIFs/geral.gif');
    touch('GIFs/ryo/miku1.gif');
    touch('GIFs/Outro Artista/nao.gif');
    touch('GIFs/fixo.webp');
    final id = await db.upsertTrack(const Track(path: '/x/melt.mp3', title: 'Melt', artist: 'ryo', album: 'supercell', addedAt: 0, modifiedAt: 0));
    await db.pinGif(id, p.join(root.path, 'GIFs', 'fixo.webp'));
    final gifs = GifService(db)..sourceRoot = root.path;
    await gifs.refresh();
    final list = await gifs.gifsFor((await db.allTracks()).single);
    expect(list.map(p.basename).toList(), ['fixo.webp', 'miku1.gif', 'geral.gif']);
  });

  test('recomendação usa histórico, favoritas e pula as puladas', () {
    Track t(int id, String artist, {bool fav = false}) =>
        Track(id: id, path: '/$id', title: 't$id', artist: artist, album: 'a', favorite: fav, addedAt: 0, modifiedAt: 0);
    final tracks = [t(1, 'Ghost'), t(2, 'Ghost'), t(3, 'supercell', fav: true), t(4, 'Outro'), t(5, 'Ghost')];
    final now = DateTime(2026, 11, 14, 21);
    final ms = now.subtract(const Duration(days: 2)).millisecondsSinceEpoch;
    final plays = [
      Play(trackId: 1, playedAt: ms, secondsListened: 200, skipped: false),
      Play(trackId: 1, playedAt: ms + 1, secondsListened: 200, skipped: false),
      Play(trackId: 5, playedAt: ms + 2, secondsListened: 5, skipped: true),
      Play(trackId: 5, playedAt: ms + 3, secondsListened: 5, skipped: true),
    ];
    final mix = Recommender(tracks, plays, now: now).mix();
    final ids = mix.map((r) => r.track.id).toList();
    expect(ids.take(3), containsAll([1, 2, 3]));
    expect(ids, isNot(contains(4)));
    // a faixa pulada duas vezes perde para a do mesmo artista (ou sai do mix)
    expect(ids.contains(5) ? ids.indexOf(5) > ids.indexOf(2) : true, isTrue);

    final radio = Recommender(tracks, plays, now: now).radio(tracks[0]);
    expect(radio.first.track.artist, 'Ghost');
  });
}
