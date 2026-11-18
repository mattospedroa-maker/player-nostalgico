import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/gif_providers.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final gifBytes = [...ascii.encode('GIF89a'), ...List.filled(20, 0)];

void main() {
  sqfliteFfiInit();

  test('Openverse e Wikimedia: lê resultados e créditos', () {
    final ov = OpenverseProvider.parse({
      'results': [
        {'url': 'https://x.org/a.gif', 'title': 'Sol', 'creator': 'Ana', 'license': 'by', 'license_version': '4.0', 'foreign_landing_url': 'https://x.org/a'},
        {'url': 'https://x.org/b.jpg'},
      ]
    });
    expect(ov.map((c) => c.url), ['https://x.org/a.gif']);
    expect(ov.first.credit, contains('CC BY 4.0'));

    final wm = WikimediaProvider.parse({
      'query': {
        'pages': {
          '2': {'index': 2, 'title': 'File:B.gif', 'imageinfo': [{'url': 'https://u/B.gif', 'mime': 'image/gif', 'size': 100}]},
          '1': {'index': 1, 'title': 'File:A.gif', 'imageinfo': [{'url': 'https://u/A.gif', 'mime': 'image/gif', 'size': 100}]},
          '3': {'index': 3, 'title': 'File:C.png', 'imageinfo': [{'url': 'https://u/C.png', 'mime': 'image/png', 'size': 100}]},
        }
      }
    });
    expect(wm.map((c) => c.url), ['https://u/A.gif', 'https://u/B.gif']);
  });

  test('nekos.best: lê GIFs de anime e fica fora do download em massa', () {
    final r = NekosBestProvider.parse({
      'results': [
        {'anime_name': 'Naruto', 'url': 'https://nekos.best/api/v2/hug/abc.gif', 'dimensions': {'width': 498, 'height': 280}}
      ]
    });
    expect(r.single.url, 'https://nekos.best/api/v2/hug/abc.gif');
    expect(r.single.credit, contains('Naruto'));
    expect(NekosBestProvider(MockClient((_) async => http.Response('{}', 200))).allowBulk, isFalse);
  });

  test('plano: cenas (palavras do usuário na frente), anime no clima, título+artista; artista e gênero de reserva', () {
    final t = Track(path: '/m/x.mp3', title: '01 - Numb', artist: 'Linkin Park', album: 'Meteora', genre: 'Nu Metal', addedAt: 0, modifiedAt: 0);
    final plan = GifFetcher.planFor(t, extras: ['naruto']);
    expect(plan.scenes, ['naruto']);
    expect(plan.title, ['Numb Linkin Park', 'Numb']);
    expect(plan.artist.first, 'Linkin Park');
    expect(plan.genre, ['Nu Metal', 'Metal concert', 'Metal music']);
    expect(plan.moods, contains('punch'));
    expect(GifFetcher.slotOrder.length, 9);
    expect(GifFetcher.slotOrder.where((s) => s == GifFetcher.slotScene).length, 5);
    expect(GifFetcher.slotOrder.where((s) => s == GifFetcher.slotAnime).length, GifFetcher.animeSlots);
    expect(GifFetcher.slotOrder.where((s) => s == GifFetcher.slotTitle).length, 2);
    // com cena, não busca "artista live" nem "gênero concert"
    final withScene = GifFetcher.planFor(t, scenes: ['rain window night']);
    expect(withScene.scenes, ['rain window night']);
    expect(withScene.artist, isNot(contains('Linkin Park live')));
    expect(withScene.genre, isNot(contains('Metal concert')));
    expect(GifFetcher.moodCategories('Sertanejo'), contains('dance'));
    expect(GifFetcher.moodCategories('Lo-Fi'), contains('sleep'));
    expect(GifFetcher.moodCategories('Alternative Rock'), contains('run'));
    expect(GifFetcher.moodCategories('Polka'), isNotEmpty);
    expect(GifFetcher.moodCategories(''), isEmpty);
    final noGenre = Track(path: '/m/y.mp3', title: 'X', artist: 'Y', album: 'Z', addedAt: 0, modifiedAt: 0);
    expect(GifFetcher.planFor(noGenre).moods, GifFetcher.neutralMoods);
    expect(isTinyImage([...ascii.encode('GIF89a'), 1, 0, 1, 0, ...List.filled(3000, 0)]), isTrue);
    expect(isTinyImage([...ascii.encode('GIF89a'), 200, 0, 150, 0, ...List.filled(3000, 0)]), isFalse);
  });

  group('GifFetcher', () {
    late Directory root;
    late AppDb db;
    late GifService gifs;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('gif_test');
      db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
      gifs = GifService(db)..sourceRoot = root.path;
    });
    tearDown(() async {
      await db.db.close();
      root.deleteSync(recursive: true);
    });

    Future<Track> addTrack() async {
      await db.upsertTrack(Track(path: p.join(root.path, 'Sonne.mp3'), title: 'Sonne', artist: 'Rammstein', album: 'Mutter', addedAt: 0, modifiedAt: 0));
      return (await db.allTracks()).single;
    }

    test('baixa no máximo 9, salva em GIFs/Artista/Título e fixa na música', () async {
      final t = await addTrack();
      final queries = <String>[];
      final client = MockClient((req) async {
        if (req.url.host == 'api.openverse.org') {
          queries.add(req.url.queryParameters['q']!);
          return http.Response(jsonEncode({
            'results': [
              for (var i = 0; i < 4; i++) {'url': 'https://img.test/dup$i.gif'},
              for (var i = 0; i < 15; i++) {'url': 'https://img.test/${req.url.queryParameters['q']}$i.gif'},
            ]
          }), 200);
        }
        if (req.url.host == 'img.test') {
          // um deles não é GIF de verdade
          if (req.url.path.contains('3')) return http.Response('<html>', 200);
          // "...dup..." = mesmo GIF em outro endereço
          final id = req.url.path.replaceAll(RegExp(r'dup\d+'), 'dup');
          return http.Response.bytes([...gifBytes, ...utf8.encode(id)], 200);
        }
        return http.Response('{}', 200);
      });
      final f = GifFetcher(gifs, client: client, providers: [OpenverseProvider(client), WikimediaProvider(client)]);
      final n = await f.fetchFor(t);
      expect(n, maxGifsPerTrack);
      expect(queries.first, 'Sonne Rammstein');
      final pinned = await db.pinnedGifs(t.id!);
      expect(pinned.length, 9);
      expect(pinned.every((g) => p.isWithin(p.join(root.path, 'GIFs', 'Rammstein', 'Sonne'), g)), isTrue);
      expect(File(p.join(root.path, 'GIFs', 'Rammstein', 'Sonne', 'creditos.txt')).existsSync(), isTrue);
      expect((await gifs.gifsFor(t)).length, 9);
      // o GIF repetido em 4 endereços entra uma vez só
      final names = pinned.map(p.basename).toSet();
      expect(names.length, 9);
      // já tem 9: não baixa mais
      expect(await f.fetchFor(t, force: true), 0);
    });

    test('duas músicas com o mesmo GIF usam o mesmo arquivo, baixado uma vez', () async {
      await db.upsertTrack(Track(path: p.join(root.path, 'A.mp3'), title: 'Sonne', artist: 'Rammstein', album: 'Mutter', addedAt: 0, modifiedAt: 0));
      await db.upsertTrack(Track(path: p.join(root.path, 'B.mp3'), title: 'Sonne Live', artist: 'Rammstein', album: 'Live', addedAt: 0, modifiedAt: 0));
      final all = await db.allTracks();
      var downloads = 0;
      final client = MockClient((req) async {
        if (req.url.host == 'api.openverse.org') {
          return http.Response(jsonEncode({'results': [for (var i = 0; i < 9; i++) {'url': 'https://img.test/g$i.gif'}]}), 200);
        }
        if (req.url.host == 'img.test') {
          downloads++;
          return http.Response.bytes([...gifBytes, ...utf8.encode(req.url.path)], 200);
        }
        return http.Response('{}', 200);
      });
      final f = GifFetcher(gifs, client: client, providers: [OpenverseProvider(client), WikimediaProvider(client)]);
      expect(await f.fetchFor(all[0]), 9);
      expect(downloads, 9);
      expect(await f.fetchFor(all[1]), 9);
      expect(downloads, 9); // nada baixado de novo
      expect((await db.pinnedGifs(all[1].id!)).toSet(), (await db.pinnedGifs(all[0].id!)).toSet());
      final files = Directory(p.join(root.path, 'GIFs')).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.gif'));
      expect(files.length, 9);
      // tirar de uma música não apaga o arquivo da outra
      final g = (await db.pinnedGifs(all[1].id!)).first;
      await gifs.deleteGif(g, trackId: all[1].id);
      expect(File(g).existsSync(), isTrue);
    });

    test('sem internet não quebra e não repete a busca logo em seguida', () async {
      final t = await addTrack();
      var calls = 0;
      final offline = MockClient((_) async {
        calls++;
        throw const SocketException('offline');
      });
      final f = GifFetcher(gifs, client: offline, providers: [OpenverseProvider(offline)]);
      expect(await f.fetchFor(t), 0);
      final before = calls;
      expect(await f.fetchFor(t), 0);
      expect(calls, before);
    });

    test('palavras extras ficam salvas e entram na busca', () async {
      await gifs.setSongExtras('Eminem', 'Till I Collapse', 'gigante de aço');
      expect(gifs.extrasFor('Eminem', 'Till I Collapse'), ['gigante de aço']);
      expect(gifs.extrasFor('Linkin Park', 'Numb'), ['rock lee vs gaara']);
    });
  });
}
