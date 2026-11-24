import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/podcast_info.dart';
import 'package:player_nostalgico/podcasts.dart';

Map<String, dynamic> _yt({bool captions = true}) => {
      'id': 'abc123',
      'language': 'en',
      'description': 'Joe conversa com uma convidada sobre ciência, espaço e a vida em Marte. ' * 2,
      'chapters': [
        {'start_time': 0, 'title': 'Abertura'},
        {'start_time': 600, 'title': 'Marte'},
      ],
      if (captions)
        'automatic_captions': {
          'de': [
            {'ext': 'json3', 'url': 'https://cap/de'},
          ],
          'en-orig': [
            {'ext': 'vtt', 'url': 'https://cap/vtt'},
            {'ext': 'json3', 'url': 'https://cap/en'},
          ],
        },
    };

const _json3 = '{"events":[{"tStartMs":0,"segs":[{"utf8":"olá"},{"utf8":" pessoal"}]},{"tStartMs":1000},'
    '{"tStartMs":61000,"segs":[{"utf8":"\\n"}]},{"tStartMs":62000,"segs":[{"utf8":"Marte é"},{"utf8":" vermelho"}]}]}';

const _ai = {
  'resumo': 'Uma conversa sobre Marte.',
  'participantes': [
    {'nome': 'Joe', 'papel': 'apresentador'},
    {'nome': 'Fulana de Tal', 'papel': 'astrônoma'},
    {'nome': ' ', 'papel': 'x'},
  ],
  'temas': ['Marte', 'foguetes', ''],
  'assunto': 'Ciência',
  'etiquetas': ['espaço'],
  'capitulos': [
    {'inicio_s': 590, 'titulo': 'Planeta vermelho', 'resumo': 'Por que Marte.', 'palavras_visuais': ['mars', 'rocket']},
    {'inicio_s': 5, 'titulo': 'Oi', 'resumo': 'Apresentações.', 'palavras_visuais': ['microphone']},
  ],
};

void main() {
  test('legenda: prefere a original do vídeo em json3 e lê os trechos com marcas a cada minuto', () {
    expect(captionUrl(_yt()).toString(), 'https://cap/en');
    expect(captionUrl(_yt(captions: false)), isNull);
    final segs = parseJson3(_json3);
    expect(segs, [(0, 'olá pessoal'), (62000, 'Marte é vermelho')]);
    expect(transcriptText(segs), '[0:00:00] olá pessoal \n[0:01:02] Marte é vermelho');
  });

  test('IA: capítulos do canal mantêm horário e título, resumo vem do capítulo da IA mais perto', () {
    final info = EpisodeInfo.fromYoutube(_yt()).withAi(_ai);
    expect(info.videoId, 'abc123');
    expect(info.status, SummaryStatus.ok);
    expect(info.subject, 'ciência');
    expect(info.people.map((x) => x.name), ['Joe', 'Fulana de Tal']);
    expect(info.topics, ['Marte', 'foguetes']);
    expect(info.chapters.map((c) => (c.startMs, c.title, c.summary)), [(0, 'Abertura', 'Apresentações.'), (600000, 'Marte', 'Por que Marte.')]);
    expect(info.chapterAt(const Duration(minutes: 11))?.title, 'Marte');

    // sem capítulos do canal: usa os da IA, em ordem
    final noCh = const EpisodeInfo().withAi(_ai);
    expect(noCh.chapters.map((c) => c.title), ['Oi', 'Planeta vermelho']);
    expect(noCh.chapterAt(Duration.zero), isNull);
    // assunto fora da lista vira "outro"
    expect(const EpisodeInfo().withAi({'assunto': 'culinária'}).subject, 'outro');

    // ida e volta pelo arquivo .json
    final back = EpisodeInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), info.toJson());
  });

  test('busca acha o episódio pelo participante ou tema do resumo', () {
    final info = const EpisodeInfo().withAi(_ai);
    final eps = [
      Track(id: 1, path: '/p/a.mp3', title: 'Episódio 400', artist: 'JRE', album: 'JRE', durationMs: 1, addedAt: 1, modifiedAt: 0),
      Track(id: 2, path: '/p/b.mp3', title: 'Outro', artist: 'JRE', album: 'JRE', durationMs: 1, addedAt: 2, modifiedAt: 0),
    ];
    String extra(Track t) => t.id == 1 ? info.searchText : '';
    expect(searchEpisodes(eps, 'fulana', extra: extra).map((t) => t.id), [1]);
    expect(searchEpisodes(eps, 'foguetes', extra: extra).map((t) => t.id), [1]);
    expect(searchEpisodes(eps, 'fulana').map((t) => t.id), isEmpty);
  });

  test('resposta da IA dentro de ```json``` e erros do Gemini', () async {
    expect(parseAiJson('```json\n{"resumo":"x"}\n```')['resumo'], 'x');
    expect(() => parseAiJson('nada'), throwsA(isA<GeminiException>()));

    final asked = <String>[];
    final ok = MockClient((r) async {
      asked.add(r.url.path);
      expect(r.headers['x-goog-api-key'], 'k', reason: 'chave vai no cabeçalho');
      expect(r.url.query, isNot(contains('key')), reason: 'chave nunca no link');
      if (r.url.path.contains('flash-lite')) return http.Response('não existe', 404);
      return http.Response(jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': '{"resumo":"oi"}'},
              ],
            },
          },
        ],
      }), 200);
    });
    expect((await GeminiClient(ok, 'k').generateJson('p'))['resumo'], 'oi');
    expect(asked.length, 2); // 404 no primeiro modelo -> tentou o segundo

    final bad = MockClient((r) async => http.Response('{"error":"API_KEY_INVALID"}', 400));
    await expectLater(GeminiClient(bad, 'k').generateJson('p'), throwsA(isA<GeminiException>().having((e) => e.toString(), 'msg', contains('inválida'))));
    final limit = MockClient((r) async => http.Response('', 429));
    await expectLater(GeminiClient(limit, 'k').generateJson('p'), throwsA(isA<GeminiException>()));
  });

  test('serviço: sem chave guarda só descrição e capítulos; com chave faz o resumo e salva o .json ao lado', () async {
    final dir = Directory.systemTemp.createTempSync('pinfo');
    addTearDown(() => dir.deleteSync(recursive: true));
    final client = MockClient((r) async {
      if (r.url.host == 'cap') return http.Response.bytes(utf8.encode(_json3), 200);
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': jsonEncode(_ai)},
                  ],
                },
              },
            ],
          })),
          200);
    });
    var key = '';
    final s = PodcastInfoService(client: client, apiKey: () => key, fetchInfo: (_) async => _yt());

    final noKey = await s.build(_yt(), title: 't', program: 'p');
    expect(noKey.status, SummaryStatus.noKey);
    expect(noKey.chapters.length, 2);

    key = 'k';
    final audio = p.join(dir.path, 'ep.mp3');
    final steps = <SummaryStatus>[];
    final info = await s.build(_yt(), title: 't', program: 'p', onStatus: steps.add);
    expect(steps, [SummaryStatus.working]);
    expect(info.status, SummaryStatus.ok);
    await s.save(audio, info);
    expect(File(p.join(dir.path, 'ep.json')).existsSync(), isTrue);

    // relido do disco por outro serviço (app reaberto) e levado junto quando o arquivo muda de lugar
    final again = PodcastInfoService(client: client, apiKey: () => key);
    expect(again.infoFor(audio)?.summary, 'Uma conversa sobre Marte.');
    final moved = p.join(dir.path, 'novo.mp3');
    again.moved(audio, moved);
    expect(again.infoFor(moved)?.people.length, 2);
    expect(again.infoFor(audio), isNull);

    // refazer pelo link
    final redo = await s.summarize(p.join(dir.path, 'x.mp3'), 'https://www.youtube.com/watch?v=abc123', title: 't', program: 'p');
    expect(redo?.hasSummary, isTrue);
    expect(s.isWorking(p.join(dir.path, 'x.mp3')), isFalse);
  });

  test('legenda bloqueada (200 vazio): Gemini ouve o vídeo; se isso falhar, usa a descrição e diz o motivo', () async {
    expect(parseJson3(''), isEmpty);
    final bodies = <Map<String, dynamic>>[];
    var videoOk = true;
    final client = MockClient((r) async {
      if (r.url.host == 'cap') return http.Response('', 200);
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      bodies.add(b);
      final parts = (b['contents'] as List).first['parts'] as List;
      final hasVideo = parts.any((x) => (x as Map).containsKey('fileData'));
      if (hasVideo && !videoOk) return http.Response('{"error":{"message":"Video too long for free tier"}}', 400);
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': jsonEncode(_ai)},
                  ],
                },
              },
            ],
          })),
          200);
    });
    final s = PodcastInfoService(client: client, apiKey: () => 'k');
    final yt = {..._yt(), 'duration': 5220};

    // sozinho (sem você pedir) não gasta a cota ouvindo o vídeo: resume pela descrição e diz como pedir
    final auto = await s.build(yt, title: 't', program: 'p');
    expect(auto.status, SummaryStatus.noCaptions);
    expect(auto.error, contains('Fazer resumo'));
    expect(bodies.any((b) => ((b['contents'] as List).first['parts'] as List).any((x) => (x as Map).containsKey('fileData'))), isFalse);

    final viaVideo = await s.build(yt, title: 't', program: 'p', allowVideo: true);
    expect(viaVideo.status, SummaryStatus.ok);
    expect(viaVideo.hasSummary, isTrue);
    final part = ((bodies.last['contents'] as List).first['parts'] as List).first as Map;
    expect(part['fileData'], {'fileUri': 'https://www.youtube.com/watch?v=abc123'});

    videoOk = false;
    final viaDescription = await s.build(yt, title: 't', program: 'p', allowVideo: true);
    expect(viaDescription.status, SummaryStatus.noCaptions);
    expect(viaDescription.hasSummary, isTrue);
    expect(viaDescription.error, allOf(contains('legenda veio vazia'), contains('Video too long')));
  });

  test('Gemini falhando com legenda boa: o motivo aparece', () async {
    final client = MockClient((r) async {
      if (r.url.host == 'cap') return http.Response.bytes(utf8.encode(_json3), 200);
      return http.Response('', 429);
    });
    final s = PodcastInfoService(client: client, apiKey: () => 'k');
    expect(s.quotaHit, isFalse);
    final info = await s.build(_yt(), title: 't', program: 'p');
    expect(info.status, SummaryStatus.failed);
    expect(info.error, contains('Limite do plano grátis'));
    expect(s.quotaHit, isTrue); // não tenta mais sozinho até a cota voltar
    expect(info.chapters.length, 2); // capítulos do canal continuam
  });

  test('Gemini no limite: a Mistral faz o resumo, e depois vai direto nela até a cota voltar', () async {
    final hosts = <String>[];
    final client = MockClient((r) async {
      if (r.url.host == 'cap') return http.Response.bytes(utf8.encode(_json3), 200);
      hosts.add(r.url.host);
      if (r.url.host.contains('googleapis')) return http.Response('', 429);
      expect(r.headers['Authorization'], 'Bearer m');
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {'content': jsonEncode(_ai)},
              },
            ],
          })),
          200);
    });
    final s = PodcastInfoService(client: client, apiKey: () => 'k', mistralKey: () => 'm');
    final info = await s.build(_yt(), title: 't', program: 'p');
    expect(info.status, SummaryStatus.ok);
    expect(info.ai, 'mistral');
    expect(info.aiName, 'Mistral');
    expect(s.quotaHit, isTrue);
    expect(s.canSummarizeNow, isTrue); // a Mistral segura enquanto o Gemini descansa
    expect(EpisodeInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>).ai, 'mistral');

    hosts.clear();
    await s.build(_yt(), title: 't', program: 'p');
    expect(hosts.every((h) => h == 'api.mistral.ai'), isTrue);

    // sem Mistral, o limite do Gemini trava as tentativas automáticas
    final only = PodcastInfoService(client: client, apiKey: () => 'k');
    await only.build(_yt(), title: 't', program: 'p');
    expect(only.canSummarizeNow, isFalse);
  });
}
