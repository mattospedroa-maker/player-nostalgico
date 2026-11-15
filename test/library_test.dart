import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/library_scanner.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/player_service.dart';
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

  test('releitura não desfaz edição nem apaga gênero automático; pastas vazias somem', () async {
    final f = touch('Artista/Album/musica.mp3');
    final scanner = LibraryScanner(db, FakeMeta());
    await scanner.scan(root.path);
    var t = (await db.allTracks()).single;
    await db.fillGenre(t.id!, 'Industrial Metal');
    await scanner.scan(root.path, force: true);
    expect((await db.allTracks()).single.genre, 'Industrial Metal');
    await db.editTrack(t.id!, title: 'Novo', artist: 'Eu', album: 'Meu', genre: 'Rock', year: 2001);
    await scanner.scan(root.path, force: true);
    t = (await db.allTracks()).single;
    expect([t.title, t.artist, t.genre], ['Novo', 'Eu', 'Rock']);
    f.deleteSync();
    await scanner.scan(root.path);
    expect(await db.allTracks(), isEmpty);
    expect(Directory(p.join(root.path, 'Artista')).existsSync(), isFalse);
    expect(root.existsSync(), isTrue);
  });

  test('parecença para a fila adaptativa', () {
    Track tr(String a, String g) => Track(path: '/$a$g', title: 't', artist: a, album: '$a$g', genre: g, addedAt: 0, modifiedAt: 0);
    expect(PlayerService.similarity(tr('A', 'Rock'), tr('A', 'Pop')), greaterThan(PlayerService.similarity(tr('B', 'Rock'), tr('C', 'Rock'))));
    expect(PlayerService.similarity(tr('B', 'Pop'), tr('C', 'Rock')), 0);
  });

  test('mix automático: mesmo artista ou mesma vibe, sem repetir a atual', () {
    var id = 0;
    Track tr(String a, String g) => Track(id: ++id, path: '/$id', title: 't$id', artist: a, album: 'x$id', genre: g, addedAt: 0, modifiedAt: 0);
    final seed = tr('Rammstein', 'Industrial Metal');
    final lib = [
      seed,
      tr('Rammstein', 'Industrial Metal'),
      tr('Rammstein', 'Industrial Metal'),
      tr('Linkin Park', 'Nu Metal'),
      tr('System of a Down', 'Metal'),
      tr('Miku', 'Vocaloid'),
      tr('Miku', 'J-Pop'),
      tr('Chopin', 'Classical'),
    ];
    final byArtist = PlayerService.pickMix(seed, lib, mode: MixMode.artist, count: 2);
    expect(byArtist.every((t) => t.artist == 'Rammstein'), isTrue);
    expect(byArtist.contains(seed), isFalse);
    final vibe = PlayerService.pickMix(seed, lib, mode: MixMode.vibe, count: 4);
    // os metais vêm antes dos calmos/fofos
    expect(vibe.take(4).where((t) => t.genre.contains('Metal')).length, 4);
    // artista acabou: completa com a vibe
    expect(PlayerService.pickMix(seed, lib, mode: MixMode.artist, count: 5).length, 5);
  });

  test('clima: fica salvo no banco e a releitura não apaga', () async {
    final id = await db.upsertTrack(const Track(path: '/x/zeit.mp3', title: 'Zeit', artist: 'Rammstein', album: 'Zeit', genre: 'Industrial Metal', addedAt: 0, modifiedAt: 0));
    expect((await db.allTracks()).single.effectiveMood, Mood.acao);
    await db.setMood(id, Mood.triste.name);
    await db.upsertTrack(const Track(path: '/x/zeit.mp3', title: 'Zeit', artist: 'Rammstein', album: 'Zeit', genre: 'Industrial Metal', addedAt: 0, modifiedAt: 1));
    final t = (await db.allTracks()).single;
    expect(t.chosenMood, Mood.triste);
    expect(GifFetcher.planFor(t).moods, Mood.triste.categories);
  });

  test('mix da mesma vibe segue o clima escolhido na primeira música', () {
    var id = 0;
    Track tr(String a, String g, [Mood? m]) =>
        Track(id: ++id, path: '/$id', title: 't$id', artist: a, album: 'x$id', genre: g, mood: m?.name ?? '', addedAt: 0, modifiedAt: 0);
    final seed = tr('Rammstein', 'Industrial Metal', Mood.triste);
    final lib = [
      seed,
      tr('A', 'Industrial Metal'),
      tr('B', 'Industrial Metal', Mood.acao),
      tr('C', 'Pop', Mood.triste),
      tr('D', 'Rock', Mood.triste),
      tr('E', 'Sad Ballad'),
    ];
    final picks = PlayerService.pickMix(seed, lib, mode: MixMode.vibe, count: 3, rnd: Random(1));
    expect(picks.map((t) => t.artist).toSet(), {'C', 'D', 'E'});
  });
}
