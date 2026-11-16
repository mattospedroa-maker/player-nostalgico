import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/gif_feedback.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/gif_providers.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/visual_tags.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('👎 e ⬇ mudam a força dos termos e ficam salvos', () {
    final dir = Directory.systemTemp.createTempSync('fb');
    final file = File(p.join(dir.path, '.preferencias.json'));
    final fb = GifFeedback(file);
    fb.vote('Linkin Park', 'Numb', 'dark cinematic', -1);
    fb.vote('Linkin Park', 'Numb', 'sad anime', 1);
    fb.reject('Linkin Park', 'Numb', ['giphy123']);
    final again = GifFeedback(file); // depois de reiniciar o app
    expect(again.weight('Linkin Park', 'Numb', 'dark cinematic'), lessThan(1));
    expect(again.weight('Linkin Park', 'Numb', 'sad anime'), greaterThan(1));
    expect(again.weight('Linkin Park', 'In the End', 'sad anime'), greaterThan(1)); // o artista aprende um pouco
    expect(again.weight('Linkin Park', 'In the End', 'sad anime'), lessThan(again.weight('Linkin Park', 'Numb', 'sad anime')));
    expect(again.rejected('Linkin Park', 'Numb'), contains('giphy123'));
    expect(again.rejected('Linkin Park', 'Faint'), contains('giphy123')); // vale para o artista
    expect(again.rejected('Eminem', 'Lose Yourself'), isEmpty);

    final plan = VisualPlan(
      all: const [VisualQuery('dark cinematic', 'Sombrio', 1), VisualQuery('sad anime', 'Triste', 0.9)],
      anime: const ['cry', 'stare'],
      matchedTags: const [],
      fromTags: true,
    );
    final applied = again.apply(plan, 'Linkin Park', 'Numb');
    expect(applied.all.first.text, 'sad anime');
    dir.deleteSync(recursive: true);
  });

  test('memes e GIFs com texto perdem para os da vibe; anime tem preferência', () {
    expect(looksLikeMeme('Reaction GIF lol'), isTrue);
    expect(looksLikeMeme('Rain Window GIF by Studio'), isFalse);
    final meme = resultScore(termScore: 1, anime: true, title: 'funny meme');
    final vibe = resultScore(termScore: 1, anime: false, title: 'rain city night');
    final animeVibe = resultScore(termScore: 1, anime: true, title: 'rain city night');
    expect(vibe, greaterThan(meme));
    expect(animeVibe, greaterThan(vibe));
    expect(nekosCategory('https://nekos.best/api/v2/cry/abc.gif'), 'cry');
    expect(nekosCategory('https://media.giphy.com/x.gif'), isNull);
  });

  test('álbum de trilha sonora vira busca', () {
    expect(GifFetcher.soundtrackName('Naruto Original Soundtrack'), 'Naruto');
    expect(GifFetcher.soundtrackName('Cowboy Bebop OST'), 'Cowboy Bebop');
    expect(GifFetcher.soundtrackName('Meteora'), isNull);
    expect(GifFetcher.soundtrackName(unknownAlbum), isNull);
  });

  group('com banco e pasta', () {
    late Directory root;
    late AppDb db;
    late GifService gifs;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('fb_db');
      db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
      gifs = GifService(db)..sourceRoot = root.path;
    });
    tearDown(() async {
      await db.db.close();
      root.deleteSync(recursive: true);
    });

    Future<Track> add(String title, String album) async {
      await db.upsertTrack(Track(path: p.join(root.path, '$title.mp3'), title: title, artist: 'Rammstein', album: album, addedAt: 0, modifiedAt: 0));
      return (await db.allTracks()).firstWhere((t) => t.title == title);
    }

    File gif(String rel) => File(p.join(root.path, 'GIFs', rel))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([...ascii.encode('GIF89a'), 100, 0, 100, 0, ...List.filled(3000, 1), ...utf8.encode(rel)]);

    test('roda: escolhidos por você primeiro; GIF automático de outra faixa do álbum não entra', () async {
      final zeit = await add('Zeit', 'Zeit');
      final other = await add('Armee der Tristen', 'Zeit');
      final auto1 = gif('Rammstein/Zeit/aaaaaaaaaaaa.gif');
      final mine = gif('Rammstein/Zeit/web_1.gif');
      final otherAuto = gif('Rammstein/Armee der Tristen/bbbbbbbbbbbb.gif');
      await db.pinGif(zeit.id!, auto1.path);
      await db.pinGif(zeit.id!, mine.path);
      await db.pinGif(other.id!, otherAuto.path);
      await gifs.refresh();
      final list = await gifs.gifsFor(zeit);
      expect(list.first, mine.path);
      expect(list, isNot(contains(otherAuto.path)));
      expect(GifService.isAuto(auto1.path), isTrue);
      expect(GifService.isAuto(mine.path), isFalse);
    });

    test('👎 num GIF automático: sai da música e não volta no próximo download', () async {
      final t = await add('Zeit', 'Zeit');
      final client = MockClient((req) async {
        if (req.url.path.endsWith('.gif')) return http.Response.bytes([...ascii.encode('GIF89a'), ...utf8.encode(req.url.path)], 200);
        if (req.url.host == 'nekos.best' && req.url.path != '/api/v2/search') {
          final cat = req.url.pathSegments.last;
          return http.Response(jsonEncode({'results': [for (var i = 0; i < 5; i++) {'url': 'https://nekos.best/api/v2/$cat/$i.gif'}]}), 200);
        }
        if (req.url.host == 'nekos.best') return http.Response('{"results":[]}', 200);
        if (req.url.path.endsWith('.gif')) return http.Response.bytes([...ascii.encode('GIF89a'), ...utf8.encode(req.url.path)], 200);
        return http.Response('{}', 404);
      });
      final f = GifFetcher(gifs, client: client)..useClipInfo = false;
      await f.fetchFor(t);
      final first = (await db.pinnedGifs(t.id!)).first;
      await f.rejectFile(t, first);
      expect(await db.pinnedGifs(t.id!), isNot(contains(first)));
      await f.fetchFor(t, force: true);
      expect(await db.pinnedGifs(t.id!), isNot(contains(first)));
      final (title, artist) = GifFetcher.namesFor(t);
      expect(f.feedback!.rejected(artist, title), contains(p.basenameWithoutExtension(first)));
    });

    test('palavras novas já baixam GIFs do GIPHY (anime primeiro)', () async {
      final t = await add('Numb', 'Meteora');
      final asked = <String>[];
      final client = MockClient((req) async {
        if (req.url.host == 'api.giphy.com') {
          final q = req.url.queryParameters['q']!;
          asked.add(q);
          final lim = int.parse(req.url.queryParameters['limit']!);
          return http.Response(jsonEncode({
            'data': [
              for (var i = 0; i < lim; i++)
                {
                  'id': '$q$i',
                  'title': i == 0 ? 'funny reaction' : 'fight scene',
                  'images': {
                    'fixed_width_small': {'url': 'https://media.giphy.test/$q/$i/s.gif'},
                    'downsized_medium': {'url': 'https://media.giphy.test/$q/$i/m.gif'}
                  }
                }
            ]
          }), 200);
        }
        if (req.url.host == 'media.giphy.test') return http.Response.bytes([...ascii.encode('GIF89a'), 100, 0, 100, 0, ...List.filled(3000, 1), ...utf8.encode(req.url.path)], 200);
        return http.Response('{"results":[]}', 200);
      });
      final f = GifFetcher(gifs, client: client)..useClipInfo = false;
      final n = await f.fetchForKeywords(t, ['rock lee vs gaara'], giphy: GiphyProvider(client, 'k'));
      expect(n, greaterThanOrEqualTo(3));
      expect(asked.first, 'anime rock lee vs gaara');
      final pinned = await db.pinnedGifs(t.id!);
      expect(pinned.where((g) => !GifService.isAuto(g)).length, 3);
    });
  });
}
