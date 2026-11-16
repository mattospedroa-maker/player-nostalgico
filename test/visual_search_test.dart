import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player_nostalgico/gif_providers.dart';
import 'package:player_nostalgico/visual_search.dart';
import 'package:player_nostalgico/visual_tags.dart';

String giphyPage(String q, int n, int offset) => jsonEncode({
      'data': [
        for (var i = 0; i < n; i++)
          {
            'id': '$q-${offset + i}',
            'title': q,
            'url': 'https://giphy.com/gifs/$i',
            'images': {
              'fixed_width_small': {'url': 'https://media.giphy.com/$q/${offset + i}/s.gif'},
              'downsized_medium': {'url': 'https://media.giphy.com/$q/${offset + i}/m.gif'},
            }
          }
      ]
    });

void main() {
  test('GIPHY: lê resultados e trata erros', () {
    final r = GiphyProvider.parse(200, giphyPage('rain', 2, 0));
    expect(r.length, 2);
    expect(r.first.previewUrl, contains('/s.gif'));
    expect(() => GiphyProvider.parse(401, '{}'), throwsA(isA<GiphyException>().having((e) => e.error, 'erro', GiphyError.invalidKey)));
    expect(() => GiphyProvider.parse(200, 'xx'), throwsA(isA<GiphyException>()));
    expect(() => GiphyProvider(MockClient((_) async => http.Response('', 200)), '').search('x'),
        throwsA(isA<GiphyException>().having((e) => e.error, 'erro', GiphyError.noKey)));
  });

  test('versões anime e geral do termo', () {
    expect(TermPager.animeVariant('apocalyptic scenery'), 'anime apocalyptic scenery');
    expect(TermPager.animeVariant('sad anime'), 'sad anime');
    expect(TermPager.generalVariant('sad anime'), 'sad');
    expect(TermPager.generalVariant('rain scenery'), 'rain scenery');
  });

  test('anime primeiro; geral só completa quando falta anime', () async {
    final asked = <String>[];
    final animeAvail = {'anime rain scenery': 3, 'anime dark cinematic': 20};
    final client = MockClient((req) async {
      final q = req.url.queryParameters['q']!;
      final off = int.parse(req.url.queryParameters['offset']!);
      final lim = int.parse(req.url.queryParameters['limit']!);
      asked.add(q);
      final total = animeAvail[q] ?? 50;
      return http.Response(giphyPage(q, (total - off).clamp(0, lim), off), 200);
    });
    final g = GiphyProvider(client, 'k');
    final rain = await TermPager(g, const VisualQuery('rain scenery', 'Melancólico', 1)).next(count: 12);
    expect(asked, ['anime rain scenery', 'rain scenery']);
    expect(rain.take(3).every((r) => r.anime), isTrue);
    expect(rain.skip(3).every((r) => !r.anime), isTrue);
    expect(rain.length, 12);

    asked.clear();
    final dark = await TermPager(g, const VisualQuery('dark cinematic', 'Sombrio', 1)).next(count: 12);
    // anime de sobra: ~70% anime e ~30% geral (preferência por anime, mas não 100%)
    expect(asked, ['anime dark cinematic', 'dark cinematic']);
    expect(dark.where((r) => r.anime).length, 8);
    expect(dark.take(8).every((r) => r.anime), isTrue);
  });

  test('roda do player: mistura os termos principais', () async {
    final client = MockClient((req) async {
      final q = req.url.queryParameters['q']!;
      return http.Response(giphyPage(q, int.parse(req.url.queryParameters['limit']!), 0), 200);
    });
    final plan = VisualTagMapper().convert(const [], title: 'Zeit', artist: 'Rammstein', genre: 'Industrial Metal');
    final picks = await PlayerVisuals(GiphyProvider(client, 'k')).pick(plan, count: 5);
    expect(picks.length, 5);
    expect(picks.map((r) => r.query).toSet().length, greaterThan(1));
    expect(interleave([[1, 3, 5], [2, 4]]), [1, 2, 3, 4, 5]);
  });
}
