import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/visual_tags.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Respostas no formato do `track.getTopTags` (exemplos; daqui não dá para acessar o Last.fm).
String topTags(List<(String, int)> tags) => jsonEncode({
      'toptags': {
        'tag': [for (final (n, c) in tags) {'name': n, 'count': c, 'url': 'https://www.last.fm/tag/$n'}],
        '@attr': {'artist': 'x', 'track': 'y'},
      }
    });

final zeitJson = topTags([
  ('Neue Deutsche Härte', 100),
  ('industrial metal', 80),
  ('german', 55),
  ('Rammstein', 40),
  ('melancholic', 30),
  ('ballad', 22),
  ('industrial', 20),
  ('dark', 12),
]);

final amourJson = topTags([
  ('dance', 100),
  ('italo dance', 72),
  ('electronic', 60),
  ('90s', 48),
  ('eurodance', 45),
  ('italian', 30),
  ('trance', 22),
  ('party', 14),
  ('euphoric', 8),
]);

void main() {
  sqfliteFfiInit();
  final mapper = VisualTagMapper();

  group('Last.fm: leitura da resposta', () {
    test('tags em ordem de relevância', () {
      final r = LastFmClient.parse(200, zeitJson);
      expect(r.status, TagStatus.ok);
      expect(r.tags.first.name, 'Neue Deutsche Härte');
      expect(r.tags.map((t) => t.count), [100, 80, 55, 40, 30, 22, 20, 12]);
    });

    test('chave inválida, música não encontrada, sem tags, resposta quebrada', () {
      expect(LastFmClient.parse(403, '{"error":10,"message":"Invalid API key"}').status, TagStatus.invalidKey);
      expect(LastFmClient.parse(200, '{"error":6,"message":"Track not found"}').status, TagStatus.notFound);
      expect(LastFmClient.parse(200, '{"toptags":{"tag":[],"@attr":{}}}').status, TagStatus.noTags);
      expect(LastFmClient.parse(200, '<html>erro</html>').status, TagStatus.badResponse);
      expect(LastFmClient.parse(502, 'Bad gateway').status, TagStatus.network);
      expect(LastFmClient.parse(200, '{"toptags":"???"}').status, TagStatus.badResponse);
      expect(LastFmClient.parse(200, '{"error":29,"message":"Rate limit"}').status, TagStatus.network);
      // uma tag só vem como objeto, não lista
      final one = LastFmClient.parse(200, '{"toptags":{"tag":{"name":"sad","count":"100"}}}');
      expect(one.tags.single.name, 'sad');
    });

    test('sem chave: nem tenta a internet', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      expect((await LastFmClient(client, null).topTags('Rammstein', 'Zeit')).status, TagStatus.noKey);
      expect((await LastFmClient(client, '  ').topTags('Rammstein', 'Zeit')).status, TagStatus.noKey);
      expect(calls, 0);
    });

    test('sem internet: avisa e não quebra', () async {
      final client = MockClient((_) async => throw const SocketException('sem rede'));
      expect((await LastFmClient(client, 'k').topTags('Rammstein', 'Zeit')).status, TagStatus.network);
    });

    test('manda método, artista, música e chave', () async {
      Uri? got;
      final client = MockClient((req) async {
        got = req.url;
        return http.Response(zeitJson, 200);
      });
      await LastFmClient(client, 'abc').topTags('Rammstein', 'Zeit');
      expect(got!.queryParameters, containsPair('method', 'track.gettoptags'));
      expect(got!.queryParameters, containsPair('artist', 'Rammstein'));
      expect(got!.queryParameters, containsPair('track', 'Zeit'));
      expect(got!.queryParameters, containsPair('api_key', 'abc'));
    });
  });

  group('tags -> pesquisas visuais', () {
    test('Zeit (Rammstein): sombrio, melancólico, industrial', () {
      final plan = mapper.convert(LastFmClient.parse(200, zeitJson).tags);
      final groups = plan.top().map((q) => q.group).toSet();
      expect(groups, containsAll(['Industrial', 'Melancólico']));
      expect(plan.all.map((q) => q.group), contains('Sombrio'));
      expect(plan.top().map((q) => q.text), contains('industrial aesthetic'));
      expect(plan.anime, contains('stare'));
      expect(plan.anime, contains('cry'));
      expect(plan.anime, isNot(contains('dance')));
      // nenhuma pesquisa repetida
      expect(plan.all.map((q) => q.text).toSet().length, plan.all.length);
      expect(plan.top().length, VisualTagMapper.maxQueries);
      expect(plan.matchedTags, isNot(contains('Rammstein')));
    });

    test("L'Amour Toujours (Gigi D'Agostino): dança, festa, eufórico, nostálgico", () {
      final plan = mapper.convert(LastFmClient.parse(200, amourJson).tags);
      final groups = plan.all.map((q) => q.group).toSet();
      expect(groups, containsAll(['Dança', 'Eletrônica', 'Anos 90', 'Festa', 'Eufórico']));
      expect(plan.top().first.group, 'Dança');
      expect(plan.anime.first, 'dance');
      expect(plan.anime, isNot(contains('cry')));
    });

    test('as pesquisas mudam com as tags (nada fixo para todas)', () {
      final a = mapper.convert(LastFmClient.parse(200, zeitJson).tags).top().map((q) => q.text).toSet();
      final b = mapper.convert(LastFmClient.parse(200, amourJson).tags).top().map((q) => q.text).toSet();
      expect(a.intersection(b), isEmpty);
    });

    test('normaliza maiúsculas, espaços, hífens e acentos', () {
      expect(VisualTagMapper.normalize('  Neue   Deutsche HÄRTE '), 'neue deutsche harte');
      expect(VisualTagMapper.normalize('Hip-Hop'), 'hip hop');
      final plan = mapper.convert(const [MusicTag('  MELANCHOLIC ', 100)]);
      expect(plan.top().first.group, 'Melancólico');
    });

    test('várias tags somam na mesma pesquisa', () {
      final one = mapper.convert(const [MusicTag('dance', 100)]);
      final two = mapper.convert(const [MusicTag('dance', 100), MusicTag('party', 100)]);
      double score(VisualPlan p) => p.all.firstWhere((q) => q.text == 'party aesthetic').score;
      expect(score(two), greaterThan(score(one)));
    });

    test('clima escolhido no selo fica à frente das tags', () {
      final plan = mapper.convert(LastFmClient.parse(200, amourJson).tags, mood: Mood.triste);
      expect(plan.top().first.group, 'Triste');
      expect(plan.anime.first, 'cry');
    });

    test('sem tags: alternativa com nome, artista e gênero', () {
      final plan = mapper.convert(const [], title: 'Zeit', artist: 'Rammstein', genre: 'Industrial Metal');
      expect(plan.fromTags, isFalse);
      expect(plan.all.map((q) => q.text), contains('Zeit Rammstein'));
      expect(plan.all.map((q) => q.group), contains('Industrial'));
      final bare = mapper.convert(const [MusicTag('xyzzy', 100)], title: 'Música', artist: 'Alguém');
      expect(bare.all.map((q) => q.text), ['Música Alguém', 'Música anime', 'Alguém aesthetic']);
      expect(bare.anime, isEmpty);
    });
  });

  group('GIFs automáticos com as tags', () {
    late Directory root;
    late AppDb db;
    late GifService gifs;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('lfm_test');
      db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
      gifs = GifService(db)..sourceRoot = root.path;
    });
    tearDown(() async {
      await db.db.close();
      root.deleteSync(recursive: true);
    });

    Future<(GifFetcher, List<String>, List<String>)> fetcher(String lastFmBody, {String? key = 'k'}) async {
      final cats = <String>[];
      final lfm = <String>[];
      final client = MockClient((req) async {
        if (req.url.host == 'ws.audioscrobbler.com') {
          if (req.url.queryParameters['method'] == 'track.gettoptags') lfm.add(req.url.queryParameters['track']!);
          return http.Response(lastFmBody, 200);
        }
        if (req.url.host == 'nekos.best' && req.url.path != '/api/v2/search') {
          final cat = req.url.pathSegments.last;
          cats.add(cat);
          return http.Response(jsonEncode({
            'results': [for (var i = 0; i < 3; i++) {'url': 'https://img.test/$cat$i.gif', 'anime_name': 'x'}]
          }), 200);
        }
        if (req.url.host == 'img.test') return http.Response.bytes([...ascii.encode('GIF89a'), ...utf8.encode(req.url.path)], 200);
        return http.Response('{"results":[]}', 200);
      });
      final f = GifFetcher(gifs, client: client)..lastFmKey = (() => key);
      return (f, cats, lfm);
    }

    Future<Track> add(String title, String artist, String genre) async {
      await db.upsertTrack(Track(path: p.join(root.path, '$title.mp3'), title: title, artist: artist, album: 'a', genre: genre, addedAt: 0, modifiedAt: 0));
      return (await db.allTracks()).firstWhere((t) => t.title == title);
    }

    test('Zeit: categorias de anime vêm das tags, não do gênero', () async {
      final t = await add('Zeit', 'Rammstein', 'Industrial Metal');
      final (f, cats, lfm) = await fetcher(zeitJson);
      await f.fetchFor(t);
      expect(f.tagStatus[t.id], TagStatus.ok);
      expect(cats, isNot(contains('kick'))); // o gênero "metal" daria luta
      expect(cats.first, 'cry'); // tags tristes: o clima triste vem primeiro
      // segunda vez: usa o cache, não consulta de novo
      await f.fetchFor(t, force: true);
      expect(lfm, ['Zeit']);
      expect(File(p.join(root.path, 'GIFs', '.lastfm.json')).existsSync(), isTrue);
    });

    test('sem chave / chave inválida / sem tags: continua pelo gênero', () async {
      for (final (body, key, status) in [
        (zeitJson, null, TagStatus.noKey),
        ('{"error":10,"message":"Invalid API key"}', 'ruim', TagStatus.invalidKey),
        ('{"toptags":{"tag":[]}}', 'k', TagStatus.noTags),
      ]) {
        final t = await add('Zeit $status', 'Rammstein', 'Industrial Metal');
        final (f, cats, _) = await fetcher(body, key: key);
        final n = await f.fetchFor(t);
        expect(f.tagStatus[t.id], status);
        expect(n, greaterThan(0));
        expect(cats.every(GifFetcher.moodCategories('Industrial Metal').contains), isTrue);
      }
    });

    test('música buscada antes de ter a chave: refaz os automáticos quando as tags chegam', () async {
      final t = await add('Zeit', 'Rammstein', 'Industrial Metal');
      final (f1, _, _) = await fetcher(zeitJson, key: null);
      await f1.fetchFor(t);
      final before = (await db.pinnedGifs(t.id!)).toSet();
      final (f2, cats, _) = await fetcher(zeitJson);
      await f2.fetchFor(t);
      final after = (await db.pinnedGifs(t.id!)).toSet();
      expect(cats, contains('cry'));
      expect(after, isNot(before));
    });
  });
}
