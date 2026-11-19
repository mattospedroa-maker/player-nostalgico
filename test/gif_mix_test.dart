import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/gif_mix.dart';
import 'package:player_nostalgico/gif_providers.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

GifCandidate cand(String id, GifKind kind, double score) =>
    GifCandidate(url: 'https://x/$id.gif', source: kind.name).ranked(query: id, score: score, kind: kind);

/// Roda a mistura como o fetchFor (todo candidato é salvo) e devolve os tipos na ordem.
List<GifKind> run(GifMix mix) {
  while (mix.taken.length < mix.total) {
    final c = mix.next();
    if (c == null) break;
    mix.accept(c);
  }
  return mix.taken;
}

bool hasRunOf3(List<GifKind> ks) {
  for (var i = 2; i < ks.length; i++) {
    if (ks[i] == ks[i - 1] && ks[i] == ks[i - 2]) return true;
  }
  return false;
}

const A = GifKind.anime, G = GifKind.general;

void main() {
  sqfliteFfiInit();

  group('roteamento', () {
    test('cena, clima, título, artista, gênero e palavra do usuário vão ao geral; anime só pelo nome', () {
      final r = routeQueries(
        userWords: ['rock lee vs gaara'],
        scenes: ['sad anime', 'rain window night'],
        ost: 'Naruto',
        mood: 'rain window',
        title: ['Numb Linkin Park', 'Numb'],
        artist: ['Linkin Park'],
        genre: ['Nu Metal'],
      );
      final general = r.general.map((q) => q.text).toList();
      expect(general, containsAll(['rock lee vs gaara', 'Naruto', 'sad', 'rain window night', 'rain window', 'Numb Linkin Park', 'Linkin Park', 'Nu Metal']));
      // palavras do usuário na frente; título e clima entre as primeiras cenas; gênero por último
      expect(general.first, 'rock lee vs gaara');
      expect(general.last, 'Nu Metal');
      expect(general.take(6), ['rock lee vs gaara', 'Naruto', 'sad', 'Numb Linkin Park', 'rain window night', 'rain window']);
      expect(r.anime.map((q) => q.text), ['rock lee vs gaara', 'Naruto']);
    });

    test('tipo pelo metadado, não só pela fonte', () {
      expect(kindOf(const GifCandidate(url: 'u', source: 'openverse', meta: 'Anime girl in the rain')), A);
      expect(kindOf(const GifCandidate(url: 'u', source: 'openverse', meta: 'Rain on a window')), G);
      expect(kindOf(const GifCandidate(url: 'u', source: 'nekos.best'), animeOnlySource: true), A);
    });

    test('relevância: metadado sem nada da pesquisa é fraco', () {
      const q = RoutedQuery('metal concert', 0.45, 'gênero');
      expect(queryMatch(q.text, 'Concert crowd'), 0.5);
      expect(relevance(q, 'Concert crowd', 0), lessThan(minGoodScore));
      expect(queryMatch('rain window', 'cat sleeping'), 0);
      expect(queryMatch('rain window', ''), 0.6); // fonte sem metadado: confia em parte na busca dela
    });
  });

  group('mistura 70/30', () {
    test('relevância parecida escolhe anime', () {
      final mix = GifMix(anime: [cand('a', A, 0.80)], general: [cand('g', G, 0.86)], total: 1);
      expect(mix.next()!.kind, A);
    });

    test('geral bem mais relevante passa na frente', () {
      final mix = GifMix(anime: [cand('a', A, 0.4), cand('a2', A, 0.4)], general: [cand('g', G, 0.9)], total: 3);
      expect(mix.next()!.kind, G);
    });

    test('8 vagas com bons dos dois lados: intercalado, não 100% anime, sem blocos', () {
      final mix = GifMix(
        anime: [for (var i = 0; i < 10; i++) cand('a$i', A, 0.85 - i * 0.01)],
        general: [for (var i = 0; i < 10; i++) cand('g$i', G, 0.8 - i * 0.01)],
        total: 8,
      );
      final ks = run(mix);
      expect(ks, [A, A, G, A, A, G, A, A]);
      expect(ks.where((k) => k == G), isNotEmpty);
      expect(hasRunOf3(ks), isFalse);
    });

    test('9 vagas: 6 anime e 3 gerais intercalados', () {
      final ks = run(GifMix(
        anime: [for (var i = 0; i < 9; i++) cand('a$i', A, 0.85)],
        general: [for (var i = 0; i < 9; i++) cand('g$i', G, 0.85)],
        total: 9,
      ));
      expect(ks, [A, A, G, A, A, G, A, A, G]);
    });

    test('geral muito relevante não vira bloco de geral', () {
      final ks = run(GifMix(
        anime: [for (var i = 0; i < 9; i++) cand('a$i', A, 0.35)],
        general: [for (var i = 0; i < 9; i++) cand('g$i', G, 0.95)],
        total: 9,
      ));
      expect(hasRunOf3(ks), isFalse);
      expect(ks.where((k) => k == A), isNotEmpty);
    });

    test('seleção curta: pelo menos um geral bom', () {
      expect(run(GifMix(anime: [cand('a', A, 0.9), cand('b', A, 0.9)], general: [cand('g', G, 0.5)], total: 2)), [A, G]);
    });

    test('sem geral bom fica só anime (nada entra para completar)', () {
      final ks = run(GifMix(anime: [for (var i = 0; i < 9; i++) cand('a$i', A, 0.8)], general: const [], total: 9));
      expect(ks, List.filled(9, A));
    });

    test('anime acabando: o geral completa', () {
      final ks = run(GifMix(anime: [cand('a', A, 0.8)], general: [for (var i = 0; i < 5; i++) cand('g$i', G, 0.6)], total: 4));
      expect(ks.length, 4);
      expect(ks.where((k) => k == A).length, 1);
    });
  });

  group('GifFetcher com HTTP mockado', () {
    late Directory root;
    late AppDb db;
    late GifService gifs;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('gif_mix_test');
      db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
      gifs = GifService(db)..sourceRoot = root.path;
    });
    tearDown(() async {
      await db.db.close();
      root.deleteSync(recursive: true);
    });

    Future<Track> addTrack({String title = 'Ohne dich', String mood = 'triste'}) async {
      final path = p.join(root.path, '$title.mp3');
      await db.upsertTrack(Track(path: path, title: title, artist: 'Rammstein', album: 'Reise', addedAt: 0, modifiedAt: 0));
      var t = (await db.allTracks()).firstWhere((t) => t.path == path);
      await db.setMood(t.id!, mood);
      return (await db.allTracks()).firstWhere((t) => t.path == path);
    }

    /// Servidor falso: nekos.best (categorias e busca), Openverse, Wikimedia e os GIFs em img.test.
    /// [openverseTitle]: título que o Openverse dá a cada resultado (por padrão, a própria pesquisa = relevante).
    MockClient server({
      List<String>? nekosSearch,
      List<String>? ovQueries,
      bool nekosDown = false,
      bool openverseDown = false,
      String Function(String q)? openverseTitle,
      int ovCount = 6,
      List<String>? wikimediaUrls,
      void Function(Uri)? onDownload,
    }) =>
        MockClient((req) async {
          final u = req.url;
          if (u.path.endsWith('.gif')) {
            onDownload?.call(u);
            return http.Response.bytes([...ascii.encode('GIF89a'), ...utf8.encode(u.toString())], 200);
          }
          if (u.host == 'nekos.best') {
            if (nekosDown) return http.Response('fora', 503);
            if (u.path == '/api/v2/search') {
              nekosSearch?.add(u.queryParameters['query']!);
              return http.Response('{"results":[]}', 200);
            }
            final cat = u.pathSegments.last;
            return http.Response(jsonEncode({'results': [for (var i = 0; i < 5; i++) {'url': 'https://nekos.best/api/v2/$cat/$i.gif', 'anime_name': 'X'}]}), 200);
          }
          if (u.host == 'api.waifu.pics') return http.Response('fora', 503);
          if (u.host == 'api.openverse.org') {
            if (openverseDown) throw const SocketException('caiu');
            final q = u.queryParameters['q']!;
            ovQueries?.add(q);
            return http.Response(jsonEncode({
              'results': [
                for (var i = 0; i < ovCount; i++)
                  {'url': 'https://img.test/ov/${Uri.encodeComponent(q)}/$i.gif', 'title': openverseTitle?.call(q) ?? q, 'license': 'by', 'creator': 'Ana'}
              ]
            }), 200);
          }
          if (u.host == 'commons.wikimedia.org' && wikimediaUrls != null) {
            return http.Response(jsonEncode({
              'query': {
                'pages': {
                  for (final (i, url) in wikimediaUrls.indexed)
                    '$i': {'index': i, 'title': 'File:Rain window $i.gif', 'imageinfo': [{'url': url, 'mime': 'image/gif', 'size': 100}]}
                }
              }
            }), 200);
          }
          return http.Response('{}', 404);
        });

    GifFetcher fetcher(http.Client c, {List<GifProvider>? providers}) => GifFetcher(gifs, client: c, providers: providers)
      ..useClipInfo = false
      ..useLyrics = false;

    /// Tipos dos GIFs fixados, na ordem em que entraram.
    Future<List<GifKind>> pinnedKinds(Track t) async {
      final idx = jsonDecode(File(p.join(root.path, 'GIFs', '.indice.json')).readAsStringSync()) as Map;
      final rows = await db.db.query('track_gifs', where: 'track_id = ?', whereArgs: [t.id], orderBy: 'rowid');
      return [
        for (final r in rows)
          (idx.entries.firstWhere((e) => e.value == r['gif_path']).key as String).contains('nekos.best') ? A : G,
      ];
    }

    test('config padrão consulta fonte anime e fonte geral', () async {
      final c = MockClient((_) async => http.Response('{}', 404));
      final names = GifFetcher(gifs, client: c).providers.map((p) => p.name).toList();
      expect(names, contains('nekos.best'));
      expect(names, containsAll(['Openverse', 'Wikimedia']));
      expect(GifFetcher(gifs, client: c).providers.where((p) => p.animeOnly), isNotEmpty);
      expect(GifFetcher(gifs, client: c).providers.where((p) => !p.animeOnly), isNotEmpty);
    });

    test('query de clima/título/palavra vai ao geral; palavra do usuário vai também ao anime', () async {
      await gifs.setSongExtras('Rammstein', 'Ohne dich', 'naruto');
      final t = await addTrack();
      final search = <String>[], ov = <String>[];
      // só Openverse como geral, sem espera entre pedidos (o padrão espera 1 s)
      // poucos resultados por pesquisa: o Openverse segue para as próximas pesquisas
      final c = server(nekosSearch: search, ovQueries: ov, ovCount: 1);
      await fetcher(c, providers: [NekosBestProvider(c, minInterval: Duration.zero), OpenverseProvider(c)]).fetchFor(t);
      expect(search, ['naruto']);
      expect(ov, contains('naruto'));
      expect(ov, contains(GifFetcher.moodQueries[Mood.triste]));
    });

    test('resultado final mistura anime e geral, intercalado, sem 3 iguais seguidos', () async {
      final t = await addTrack();
      final c = server();
      final n = await fetcher(c, providers: [NekosBestProvider(c, minInterval: Duration.zero), OpenverseProvider(c)]).fetchFor(t);
      expect(n, maxGifsPerTrack);
      final ks = await pinnedKinds(t);
      expect(ks.where((k) => k == G), isNotEmpty);
      expect(ks.where((k) => k == A).length, greaterThan(ks.where((k) => k == G).length));
      expect(hasRunOf3(ks), isFalse);
      expect(ks.take(3), [A, A, G]);
    });

    test('geral ruim (nada a ver com a pesquisa) não entra para fechar 30%', () async {
      final t = await addTrack();
      final c = server(openverseTitle: (_) => 'Office stock photo');
      await fetcher(c, providers: [NekosBestProvider(c, minInterval: Duration.zero), OpenverseProvider(c)]).fetchFor(t);
      final ks = await pinnedKinds(t);
      expect(ks, isNotEmpty);
      expect(ks.every((k) => k == A), isTrue);
    });

    test('mesmo GIF em dois provedores: baixado e fixado uma vez', () async {
      final t = await addTrack(mood: 'calmo');
      final downloads = <String>[];
      const shared = 'https://img.test/shared/rain.gif';
      final c = server(
        wikimediaUrls: [shared, 'https://img.test/wm/1.gif'],
        openverseTitle: (q) => q,
        onDownload: (u) => downloads.add(u.toString()),
      );
      // Openverse devolve o mesmo endereço também
      final both = MockClient((req) async {
        if (req.url.host == 'api.openverse.org') {
          return http.Response(jsonEncode({'results': [{'url': shared, 'title': req.url.queryParameters['q']}]}), 200);
        }
        return c.get(req.url);
      });
      await fetcher(both, providers: [OpenverseProvider(both), WikimediaProvider(both)]).fetchFor(t);
      expect(downloads.where((d) => d == shared).length, 1);
      final pinned = await db.pinnedGifs(t.id!);
      expect(pinned.toSet().length, pinned.length);
    });

    test('um provedor fora não zera o outro', () async {
      // geral caiu: anime continua
      final t1 = await addTrack(title: 'A');
      final c1 = server(openverseDown: true);
      expect(await fetcher(c1, providers: [NekosBestProvider(c1, minInterval: Duration.zero), OpenverseProvider(c1)]).fetchFor(t1), greaterThan(0));
      expect((await pinnedKinds(t1)).every((k) => k == A), isTrue);
      // anime caiu (nekos.best e waifu.pics): geral continua
      final t2 = await addTrack(title: 'B');
      final c2 = server(nekosDown: true);
      final f2 = GifFetcher(gifs, client: c2,
          providers: [NekosBestProvider(c2, minInterval: Duration.zero), OpenverseProvider(c2)],
          moodSources: [NekosBestProvider(c2, minInterval: Duration.zero), WaifuPicsProvider(c2)])
        ..useClipInfo = false
        ..useLyrics = false;
      expect(await f2.fetchFor(t2), greaterThan(0));
      expect((await db.pinnedGifs(t2.id!)), isNotEmpty);
    });

    test('GIF manual continua e vale offline', () async {
      final t = await addTrack();
      final dir = Directory(p.join(root.path, 'GIFs', 'Rammstein', 'Ohne dich'))..createSync(recursive: true);
      final manual = File(p.join(dir.path, 'meu favorito.gif'))..writeAsBytesSync([...ascii.encode('GIF89a'), 1, 2, 3]);
      await db.pinGif(t.id!, manual.path);
      await gifs.refresh();
      // online: completa as vagas sem tirar o manual
      final c = server();
      await fetcher(c, providers: [NekosBestProvider(c, minInterval: Duration.zero), OpenverseProvider(c)]).fetchFor(t);
      final pinned = await db.pinnedGifs(t.id!);
      expect(pinned, contains(manual.path));
      expect(pinned.length, maxGifsPerTrack);
      // offline: nada some, o manual segue na roda
      final off = MockClient((_) async => throw const SocketException('offline'));
      await fetcher(off, providers: [NekosBestProvider(off, minInterval: Duration.zero), OpenverseProvider(off)]).fetchFor(t, force: true);
      expect(await db.pinnedGifs(t.id!), containsAll(pinned));
      expect(await gifs.gifsFor(t), contains(manual.path));
    });
  });
}
