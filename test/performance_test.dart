// Testes das otimizações de desempenho: garantem que o resultado continua o mesmo de antes.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/cover_service.dart';
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/library_scanner.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/player_service.dart';
import 'package:player_nostalgico/recommender.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoMeta implements MetadataReader {
  @override
  Future<TagInfo?> read(String path) async => null;
  @override
  Future<Uint8List?> cover(String path) async => null;
}

class _CoverMeta implements MetadataReader {
  @override
  Future<TagInfo?> read(String path) async => null;
  @override
  Future<Uint8List?> cover(String path) async => Uint8List.fromList(List.filled(2000, 5));
}

Track _t(int id, {String artist = 'A', String album = 'X', String genre = 'Rock', String mood = '', String path = ''}) => Track(
      id: id,
      path: path.isEmpty ? '/m/$id.mp3' : path,
      title: 'Song $id',
      artist: artist,
      album: album,
      genre: genre,
      mood: mood,
      addedAt: id,
      modifiedAt: id,
    );

void main() {
  sqfliteFfiInit();
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('perf_test'));
  tearDown(() => root.deleteSync(recursive: true));

  test('mix: mesma regra de antes (metais primeiro, até 2 por artista, sem repetir e sem a semente)', () {
    final seed = _t(1, artist: 'Rammstein', genre: 'Industrial Metal');
    final lib = [
      seed,
      for (var i = 2; i < 40; i++) _t(i, artist: 'M${i % 6}', genre: i.isEven ? 'Nu Metal' : 'Industrial Metal'),
      for (var i = 40; i < 80; i++) _t(i, artist: 'C${i % 9}', genre: 'Classical'),
    ];
    final picks = PlayerService.pickMix(seed, lib, mode: MixMode.vibe, count: 10, rnd: Random(3));
    expect(picks.length, 10);
    expect(picks.contains(seed), isFalse);
    expect(picks.map((t) => t.id).toSet().length, 10);
    expect(picks.every((t) => t.genre.contains('Metal')), isTrue);
    final perArtist = <String, int>{};
    for (final t in picks) {
      perArtist[t.artist] = (perArtist[t.artist] ?? 0) + 1;
    }
    expect(perArtist.values.every((n) => n <= 2), isTrue);
    // a mesma semente de sorte dá a mesma escolha
    expect(PlayerService.pickMix(seed, lib, mode: MixMode.vibe, count: 10, rnd: Random(3)).map((t) => t.id), picks.map((t) => t.id));
  });

  test('clima e gênero guardados na memória dão a mesma resposta de sempre', () {
    for (var k = 0; k < 3; k++) {
      expect(_t(1, genre: 'Industrial Metal').effectiveMood, Mood.acao);
      expect(_t(1, genre: 'Industrial Metal', mood: 'triste').effectiveMood, Mood.triste);
      expect(_t(1, genre: '').effectiveMood, isNull);
      expect(Mood.byName('festa'), Mood.festa);
      expect(Mood.byName('xyz'), isNull);
      expect(Recommender.affinity(_t(1, artist: 'P', genre: 'Nu Metal'), _t(2, artist: 'Q', genre: 'Industrial Metal')), greaterThan(0));
    }
  });

  test('leitura da pasta em lotes: muitas músicas, tags reais lidas fora da tela e releitura sem mudanças', () async {
    final db = await AppDb.open(p.join(root.path, 'x.db'), factory: databaseFactoryFfi);
    for (var i = 0; i < 130; i++) {
      File(p.join(root.path, 'Artista $i', 'Artista $i - Faixa $i.mp3'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    // arquivo de verdade com tags ID3: passa pelo leitor de tags real (isolate)
    File('test/fixtures/tagged.mp3').copySync(p.join(root.path, 'tagged.mp3'));
    final progress = <int>[];
    final n = await LibraryScanner(db, const FileMetadataReader()).scan(root.path, onProgress: (d, _) => progress.add(d));
    expect(n, 131);
    final all = await db.allTracks();
    expect(all.length, 131);
    final melt = all.firstWhere((t) => t.title == 'Melt');
    expect((melt.artist, melt.album, melt.genre), ('ryo', 'supercell', 'J-Pop'));
    final f7 = all.firstWhere((t) => t.title == 'Faixa 7');
    expect((f7.artist, f7.album), ('Artista 7', 'Artista 7'));
    expect(progress.last, 131); // terminou em 100%
    // nada mudou: não regrava nada
    expect(await LibraryScanner(db, const FileMetadataReader()).scan(root.path), 0);
    // uma música sumiu: sai do banco
    File(p.join(root.path, 'Artista 3', 'Artista 3 - Faixa 3.mp3')).deleteSync();
    await LibraryScanner(db, _NoMeta()).scan(root.path);
    expect((await db.allTracks()).length, 130);
    await db.db.close();
  });

  test('banco: índices novos existem e a contagem de quem usa um GIF continua certa', () async {
    final db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
    final idx = (await db.db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'")).map((r) => r['name']).toSet();
    expect(idx, containsAll(['playlist_tracks_pl', 'playlist_tracks_track', 'track_gifs_path']));
    final a = await db.upsertTrack(_t(0, path: '/a.mp3'));
    final b = await db.upsertTrack(_t(0, path: '/b.mp3'));
    expect(await db.gifUsers('/g.gif'), 0);
    await db.pinGif(a, '/g.gif');
    await db.pinGif(b, '/g.gif');
    expect(await db.gifUsers('/g.gif'), 2);
    await db.db.close();
  });

  test('capas: resposta guardada enxerga a capa nova assim que ela é gravada', () async {
    final svc = CoverService(root.path, _CoverMeta());
    final track = _t(1, artist: 'Nirvana', album: unknownAlbum);
    expect(svc.fileFor(track), isNull);
    expect(svc.fileFor(track), isNull); // segunda vez: sem ir ao disco
    final n = await svc.fetchMissing([track], <String>{});
    expect(n, 1);
    expect(svc.fileFor(track), isNotNull);
  });

  test('GIFs: escolha igual à de antes (automáticos de outras músicas não entram, os do artista sim) e leituras juntas', () async {
    final db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
    final gifRoot = p.join(root.path, 'GIFs');
    File touch(String rel) => File(p.join(gifRoot, rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(3000, 1));
    touch('Linkin Park/Numb/0123456789ab.gif'); // automático de outra música
    touch('Linkin Park/rock lee.gif'); // escolhido pelo usuário, pasta do artista
    touch('geral.gif'); // solto: vale para todas
    touch('Outro Artista/nada.gif');
    final svc = GifService(db)..sourceRoot = root.path;
    var notified = 0;
    svc.addListener(() => notified++);
    await Future.wait([svc.refresh(), svc.refresh(), svc.refresh()]);
    expect(svc.count, 4);
    expect(notified, lessThanOrEqualTo(2)); // três pedidos ao mesmo tempo: no máximo uma leitura extra
    final id = await db.upsertTrack(_t(0, artist: 'Linkin Park', album: 'Meteora', path: '/numb.mp3'));
    final track = (await db.allTracks()).firstWhere((t) => t.id == id);
    final gifs = await svc.gifsFor(track);
    expect(gifs.map(p.basename).toSet(), {'rock lee.gif', 'geral.gif'});
    // fixado pela música: vem primeiro, mesmo sendo automático
    final auto = p.join(gifRoot, 'Linkin Park/Numb/0123456789ab.gif');
    await db.pinGif(id, auto);
    expect((await svc.gifsFor(track)).first, auto);
    // arquivo apagado por fora: some da escolha
    File(p.join(gifRoot, 'geral.gif')).deleteSync();
    expect((await svc.gifsFor(track)).map(p.basename), isNot(contains('geral.gif')));
    await db.db.close();
  });
}
