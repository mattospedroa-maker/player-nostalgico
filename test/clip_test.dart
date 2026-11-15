import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player_nostalgico/clip_info.dart';
import 'package:player_nostalgico/gif_providers.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/visual_search.dart';
import 'package:player_nostalgico/visual_tags.dart';

/// Seção do clipe no formato da Wikipédia (texto de exemplo; daqui não dá para acessar a Wikipédia).
const zeitVideo = r"""
== Music video ==
The music video for "Zeit" was directed by [[Robert Gwisdek]].<ref>{{cite web|url=x}}</ref>
It shows the band members as old men on a cliff by the '''sea''', watching the waves while a clock
stops. Later they stand in the rain at a funeral, and the video ends with the members in a burning boat at sunset.
{{Clear}}
""";

void main() {
  test('acha o artigo da música (não o do álbum)', () {
    final search = {
      'query': {
        'search': [
          {'title': 'Zeit (album)', 'snippet': 'Zeit is the eighth album by Rammstein'},
          {'title': 'Zeit (Rammstein song)', 'snippet': 'single by German band <span>Rammstein</span>'},
        ]
      }
    };
    expect(ClipInfoClient.pickArticle(search, 'Rammstein', 'Zeit'), 'Zeit (Rammstein song)');
    expect(ClipInfoClient.pickArticle({'query': {'search': []}}, 'Rammstein', 'Zeit'), isNull);
    expect(ClipInfoClient.pickArticle(null, 'Rammstein', 'Zeit'), isNull);
  });

  test('acha a seção do videoclipe', () {
    final secs = {
      'parse': {
        'sections': [
          {'line': 'Background', 'index': '1'},
          {'line': 'Music video', 'index': '2'},
        ]
      }
    };
    expect(ClipInfoClient.videoSection(secs), '2');
    expect(ClipInfoClient.videoSection({'parse': {'sections': [{'line': 'Charts', 'index': '1'}]}}), isNull);
  });

  test('texto limpo e cenas do clipe', () {
    final text = ClipInfoClient.plainText(zeitVideo);
    expect(text, isNot(contains('<ref')));
    expect(text, isNot(contains('[[')));
    expect(text, contains('Robert Gwisdek'));
    final scenes = ClipInfoClient.scenesIn(text);
    expect(scenes.keys, containsAll(['ocean', 'time', 'rain', 'grave', 'fire', 'sunset', 'mountain']));
    expect(scenes.keys, isNot(contains('desert')));
  });

  test('busca completa com respostas de exemplo', () async {
    final client = MockClient((req) async {
      final q = req.url.queryParameters;
      if (q['list'] == 'search') {
        return http.Response(jsonEncode({'query': {'search': [{'title': 'Zeit (Rammstein song)', 'snippet': 'Rammstein'}]}}), 200);
      }
      if (q['prop'] == 'sections') return http.Response(jsonEncode({'parse': {'sections': [{'line': 'Music video', 'index': '3'}]}}), 200);
      if (q['prop'] == 'wikitext' && q['section'] == '3') return http.Response(jsonEncode({'parse': {'wikitext': zeitVideo}}), 200);
      return http.Response('{}', 404);
    });
    final info = await ClipInfoClient(client).lookup('Rammstein', 'Zeit');
    expect(info, isNotNull);
    expect(info!.article, 'Zeit (Rammstein song)');
    expect(info.sceneLabels, contains('Chuva'));
  });

  test('sem internet: avisa que não chegou (para não guardar "sem clipe")', () async {
    final c = ClipInfoClient(MockClient((_) async => throw Exception('offline')));
    expect(await c.lookup('Rammstein', 'Zeit'), isNull);
    expect(c.reached, isFalse);
  });

  test('cenas do clipe entram nas pesquisas junto com as tags', () {
    final scenes = ClipInfoClient.scenesIn(ClipInfoClient.plainText(zeitVideo));
    final tags = const [MusicTag('industrial metal', 100), MusicTag('melancholic', 40)];
    final plan = VisualTagMapper().convert(tags, scenes: scenes);
    expect(plan.clipScenes, contains('Chuva'));
    expect(plan.all.map((q) => q.group), containsAll(['Chuva', 'Mar', 'Industrial']));
    // sem tags, o clipe sozinho já guia
    final only = VisualTagMapper().convert(const [], title: 'Zeit', artist: 'Rammstein', scenes: scenes);
    expect(only.all.map((q) => q.group), contains('Chuva'));
  });

  test('músicas do mesmo álbum pegam GIFs diferentes do GIPHY', () async {
    final client = MockClient((req) async {
      final q = req.url.queryParameters['q']!;
      final off = int.parse(req.url.queryParameters['offset']!);
      final lim = int.parse(req.url.queryParameters['limit']!);
      return http.Response(jsonEncode({
        'data': [
          for (var i = off; i < off + lim; i++)
            {
              'id': '$q-$i',
              'images': {
                'fixed_width_small': {'url': 'https://m.test/$q/$i/s.gif'},
                'downsized_medium': {'url': 'https://m.test/$q/$i/m.gif'}
              }
            }
        ]
      }), 200);
    });
    final plan = VisualTagMapper().convert(const [MusicTag('industrial metal', 100), MusicTag('melancholic', 60), MusicTag('dark', 40)]);
    final g = GiphyProvider(client, 'k');
    final a = await PlayerVisuals(g).pick(plan, count: 5, rnd: Random(1));
    final b = await PlayerVisuals(g).pick(plan, count: 5, rnd: Random(2), avoid: a.map((r) => r.gif.id).toSet());
    expect(a.length, 5);
    expect(b.length, 5);
    expect(a.map((r) => r.gif.id).toSet().intersection(b.map((r) => r.gif.id).toSet()), isEmpty);
  });
}
