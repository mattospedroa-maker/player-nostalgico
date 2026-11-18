import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/artist_photos.dart';
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/error_log.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/gif_providers.dart';
import 'package:player_nostalgico/gif_service.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/service_health.dart';
import 'package:player_nostalgico/ytdlp.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

List<int> gif(String id) => [...ascii.encode('GIF89a'), ...utf8.encode(id), ...List.filled(20, 0)];

/// nekos.best respondendo normal: 5 GIFs por categoria.
http.Response nekosOk(http.Request req) {
  final seg = req.url.pathSegments;
  if (seg.length == 3) {
    final cat = seg[2];
    return http.Response(jsonEncode({
      'results': [for (var i = 0; i < 5; i++) {'url': 'https://nekos.best/api/v2/$cat/$cat$i.gif', 'anime_name': 'A'}]
    }), 200);
  }
  return http.Response.bytes(gif(req.url.path), 200);
}

void main() {
  sqfliteFfiInit();

  test('ServiceHealth: serviço que caiu fica pausado 30 min e volta quando responde', () {
    var now = DateTime(2026, 11, 17, 20);
    final h = ServiceHealth(now: () => now);
    expect(h.isDown('nekos.best'), isFalse);
    h.down('nekos.best', const ServiceDown('nekos.best', 503));
    expect(h.isDown('nekos.best'), isTrue);
    now = now.add(const Duration(minutes: 31));
    expect(h.isDown('nekos.best'), isFalse); // já pode tentar de novo
    expect(h.wasDown('nekos.best'), isTrue); // mas ainda não voltou
    h.up('nekos.best');
    expect(h.wasDown('nekos.best'), isFalse);
  });

  test('ServiceHealth: balão uma vez por queda; sem internet vai só para o registro', () {
    errorLog.clear();
    final h = ServiceHealth();
    h.down('nekos.best', const ServiceDown('nekos.best', 503));
    h.announce('nekos.best', online: true, fallback: 'mostrando GIFs guardados no celular');
    h.announce('nekos.best', online: true, fallback: 'mostrando GIFs guardados no celular');
    expect(errorLog.entries.where((e) => e.level == LogLevel.warning).length, 1);
    expect(errorLog.entries.first.message, contains('nekos.best fora do ar'));

    errorLog.clear();
    final h2 = ServiceHealth();
    h2.down('nekos.best', const SocketException('offline'));
    h2.announce('nekos.best', online: false, fallback: 'mostrando GIFs guardados no celular');
    expect(errorLog.entries.single.level, LogLevel.info);
  });

  test('waifu.pics: só GIFs, com a categoria traduzida e lembrada', () {
    final r = WaifuPicsProvider.parse({
      'files': ['https://i.waifu.pics/a.gif', 'https://i.waifu.pics/b.png', 'https://i.waifu.pics/c.gif']
    }, 'punch');
    expect(r.map((c) => c.url), ['https://i.waifu.pics/a.gif', 'https://i.waifu.pics/c.gif']);
    expect(r.first.category, 'punch');
    expect(WaifuPicsProvider.categoryFor('punch'), 'bonk');
    expect(WaifuPicsProvider.categoryFor('dance'), 'dance');
  });

  group('GIFs: plano B', () {
    late Directory root;
    late AppDb db;
    late GifService gifs;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('plano_b');
      db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
      gifs = GifService(db)..sourceRoot = root.path;
      errorLog.clear();
    });
    tearDown(() async {
      await db.db.close();
      root.deleteSync(recursive: true);
    });

    Future<Track> add(String file, String title) async {
      await db.upsertTrack(Track(path: p.join(root.path, file), title: title, artist: 'Daft Punk', album: 'Discovery', genre: 'Electronic', addedAt: 0, modifiedAt: 0));
      return (await db.allTracks()).firstWhere((t) => t.title == title);
    }

    test('nekos.best fora do ar: o waifu.pics entra no lugar e a barra avisa', () async {
      final t = await add('a.mp3', 'One More Time');
      var waifuCalls = 0;
      final client = MockClient((req) async {
        if (req.url.host == 'nekos.best') return http.Response('fora', 503);
        if (req.url.host == 'api.waifu.pics') {
          waifuCalls++;
          final cat = req.url.pathSegments.last;
          return http.Response(jsonEncode({'files': [for (var i = 0; i < 6; i++) 'https://i.waifu.pics/$cat$i.gif']}), 200);
        }
        if (req.url.host == 'i.waifu.pics') return http.Response.bytes(gif(req.url.path), 200);
        return http.Response('{}', 200);
      });
      final f = GifFetcher(gifs, client: client)..useClipInfo = false;
      final n = await f.fetchFor(t);
      expect(n, greaterThan(0));
      expect(waifuCalls, greaterThan(0));
      expect(f.statusFor(t), 'nekos.best fora do ar · GIFs do waifu.pics no lugar');
      expect(f.health.isDown('nekos.best'), isTrue);
      final warn = errorLog.entries.where((e) => e.level == LogLevel.warning).toList();
      expect(warn.single.message, contains('nekos.best fora do ar'));
      // o clima dos GIFs do waifu.pics fica guardado, para emprestar depois
      expect(File(p.join(root.path, 'GIFs', '.climas.json')).existsSync(), isTrue);
    });

    test('sem internet: mostra GIFs guardados do mesmo clima e tenta de novo depois', () async {
      final a = await add('a.mp3', 'One More Time');
      final online = MockClient((req) async => req.url.host == 'nekos.best' ? nekosOk(req) : http.Response('{}', 200));
      expect(await GifFetcher(gifs, client: online).fetchFor(a), maxGifsPerTrack);

      final b = await add('b.mp3', 'Aerodynamic');
      var calls = 0;
      final offline = MockClient((_) async {
        calls++;
        throw const SocketException('offline');
      });
      final f = GifFetcher(gifs, client: offline)..useClipInfo = false;
      expect(await f.fetchFor(b), 0);
      expect(f.borrowed[b.id], isNotEmpty);
      expect(f.borrowed[b.id]!.every((g) => File(g).existsSync()), isTrue);
      expect(f.statusFor(b), 'Sem internet · usando GIFs guardados');
      // nada fixado na música: quando a internet voltar, ela ganha os GIFs dela
      expect(await db.pinnedGifs(b.id!), isEmpty);
      expect(errorLog.entries.where((e) => e.level == LogLevel.warning), isEmpty);
      // durante a pausa nem chama os serviços de novo
      final before = calls;
      await f.fetchFor(b);
      expect(calls, before);
    });
  });

  test('yt-dlp velho: reconhece os erros que pedem atualização', () {
    expect(YtDlp.looksOutdated('ERROR: [youtube] abc: Unable to extract uploader id; please report this issue ... Confirm you are on the latest version using yt-dlp -U'), isTrue);
    expect(YtDlp.looksOutdated('ERROR: unable to download video data: HTTP Error 403: Forbidden'), isTrue);
    expect(YtDlp.looksOutdated('WARNING: [youtube] nsig extraction failed: Some formats may be missing'), isTrue);
    expect(YtDlp.looksOutdated('ERROR: [youtube] abc: Private video. Sign in if you\'ve been granted access'), isFalse);
    expect(YtDlp.looksOutdated('ERROR: [youtube] abc: Video unavailable'), isFalse);
    expect(YtDlp.looksOutdated('ERROR: Unable to download webpage: <urlopen error [Errno -3] Temporary failure in name resolution> (failed to resolve)'), isFalse);
    expect(YtDlpException.from('ERROR: HTTP Error 403: Forbidden').outdated, isTrue);
  });

  test('fotos do artista: Deezer e Wikipédia só com o nome certo', () {
    expect(ArtistPhotoService.sameName('The Beatles', 'beatles'), isTrue);
    expect(ArtistPhotoService.sameName('Beyoncé', 'Beyonce'), isTrue);
    expect(ArtistPhotoService.sameName('Linkin Park', 'Linkin'), isFalse);
    final dz = ArtistPhotoService.parseDeezer({
      'data': [
        {'name': 'Linkin Park Tribute', 'picture_xl': 'https://e-cdns-images.dzcdn.net/images/artist/x/1000x1000.jpg'},
        {'name': 'Linkin Park', 'picture_xl': 'https://e-cdns-images.dzcdn.net/images/artist/abc/1000x1000.jpg'},
      ]
    }, 'linkin park');
    expect(dz, 'https://e-cdns-images.dzcdn.net/images/artist/abc/1000x1000.jpg');
    // artista sem foto no Deezer: silhueta padrão não serve
    expect(ArtistPhotoService.parseDeezer({'data': [{'name': 'MC VV', 'picture_xl': 'https://e-cdns-images.dzcdn.net/images/artist//1000x1000-000000-80-0-0.jpg'}]}, 'MC VV'), isNull);
    final wp = ArtistPhotoService.parseWikipedia({
      'query': {
        'pages': {
          '1': {'index': 1, 'title': 'Nirvana (band)', 'description': 'American rock band', 'thumbnail': {'source': 'https://upload.wikimedia.org/x/Nirvana_1992.jpg'}},
          '2': {'index': 2, 'title': 'Nirvana', 'description': 'Buddhist concept', 'thumbnail': {'source': 'https://upload.wikimedia.org/x/Buddha.jpg'}},
        }
      }
    }, 'Nirvana');
    expect(wp, 'https://upload.wikimedia.org/x/Nirvana_1992.jpg');
  });

  test('capa e fotos entram a cada 3 GIFs, sem tirar nenhum GIF', () {
    final g = [for (var i = 1; i <= 9; i++) 'g$i'];
    expect(mixExtras(g, ['capa', 'foto1', 'foto2']), ['g1', 'g2', 'g3', 'capa', 'g4', 'g5', 'g6', 'foto1', 'g7', 'g8', 'g9', 'foto2']);
    expect(mixExtras(['g1'], ['capa', 'foto1']), ['g1', 'capa', 'foto1']);
    expect(mixExtras(g, const []), g);
  });
}
