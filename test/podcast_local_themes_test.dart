import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/podcast_info.dart';
import 'package:player_nostalgico/podcast_local_themes.dart';
import 'package:player_nostalgico/podcast_themes.dart';

Track _ep(int i, String title) => Track(
  id: i,
  path: '/m/Podcasts/Inteligência Ltda/ep$i.m4a',
  title: title,
  artist: 'Inteligência Ltda',
  album: 'Inteligência Ltda',
  durationMs: 3600000,
  addedAt: i,
  modifiedAt: 0,
);

void main() {
  const program = 'Inteligência Ltda';
  final titles = [
    'DR. GUSTAVO CABRAL (IMUNOLOGISTA) - Inteligência Ltda. Podcast #108',
    'A ORIGEM E O FIM DA VIDA NA TERRA: SACANI E ALBERTO LINDNER - Inteligência Ltda. Podcast #1200',
    'A TECNOLOGIA DOS PRÓXIMOS MIL ANOS - Inteligência Ltda. Podcast #1066',
    'AGRO: ROBERTO RODRIGUES E GUSTAVO SPADOTTI - Inteligência Ltda. Podcast #686',
    'DOUGLAS GALANTE (ASTROBIÓLOGO) - Inteligência Ltda. Podcast #276',
    'SÉRGIO SACANI (ASTRONOMIA) - Inteligência Ltda. Podcast #300',
    'VIDA FORA DA TERRA - Inteligência Ltda. Podcast #900',
    'INTELIGÊNCIA ARTIFICIAL E O FUTURO DA TECNOLOGIA - Inteligência Ltda. Podcast #1100',
    'BRUNO SARTORI (DEEP FAKE) - Inteligência Ltda. Podcast #028',
    'AMOR E S3X0: CARLA CECARELLO E MARCOS LACERDA (NÓS DA QUESTÃO) - Inteligência Ltda. Podcast #500',
  ];
  final eps = [for (var i = 0; i < titles.length; i++) _ep(i, titles[i])];
  final chapters = <String, List<String>>{
    eps[0].path: ['Introdução', 'Vacinas e imunidade', 'Ciência e tecnologia'],
    eps[4].path: ['Introdução', 'Vida em Marte', 'Astronomia amadora'],
    eps[5].path: ['Abertura', 'Buracos negros', 'Telescópio James Webb'],
    eps[8].path: ['Introdução', 'Tecnologia de deep fake', 'Inteligência artificial'],
  };
  EpisodeInfo? info(String path) => chapters[path] == null
      ? null
      : EpisodeInfo(
          chapters: [for (var i = 0; i < chapters[path]!.length; i++) Chapter(startMs: i * 60000, title: chapters[path]![i])],
        );

  test('junta pelos assuntos repetidos no título e nos capítulos, sem nome de convidado nem do programa', () {
    final themes = LocalThemes.build(program, eps, info);
    final names = [for (final t in themes) t.name.toLowerCase()];
    expect(names, isNot(contains('gustavo')));
    expect(names, isNot(contains('inteligência')));
    expect(names, isNot(contains('introdução')));
    final tech = themes.firstWhere((t) => t.name.toLowerCase() == 'tecnologia');
    expect(tech.files, containsAll(['ep2.m4a', 'ep7.m4a', 'ep8.m4a']));
    expect(names.any((n) => n == 'vida' || n == 'terra'), isTrue);
    for (final t in themes) {
      expect(t.files.length, greaterThanOrEqualTo(2));
    }
    final all = [for (final t in themes) ...t.files];
    expect(all.toSet().length, all.length, reason: 'cada episódio em um tema só');
  });

  test('poucos episódios sem nada em comum: nenhum tema', () {
    expect(LocalThemes.build(program, [_ep(1, 'Abacaxi'), _ep(2, 'Bicicleta'), _ep(3, 'Computador'), _ep(4, 'Dinossauro')], (_) => null), isEmpty);
  });

  test('pedido para a IA fica curto: tira o nome do programa e limita os capítulos', () {
    final prompt = PodcastThemesService.promptFor(program, eps, info);
    expect(prompt, contains('1. DR. GUSTAVO CABRAL (IMUNOLOGISTA) | Introdução; Vacinas e imunidade; Ciência e tecnologia'));
    expect(prompt, isNot(contains('Podcast #108')));
  });

  test('temas locais guardam a fonte e voltam do arquivo', () {
    const t = ProgramThemes('s', [
      EpisodeTheme(name: 'Tecnologia', gifQuery: 'tecnologia', files: ['a']),
    ], source: 'local');
    final back = ProgramThemes.fromJson(t.toJson());
    expect(back.byAi, isFalse);
    expect(ProgramThemes.fromJson(const {'temas': []}).byAi, isTrue, reason: 'arquivo antigo = IA');
  });

  test('espera mais a cada falha da IA', () {
    expect(PodcastThemesService.retryWait(1), const Duration(minutes: 30));
    expect(PodcastThemesService.retryWait(2), const Duration(hours: 2));
    expect(PodcastThemesService.retryWait(5), const Duration(days: 1));
  });

  test('resumo: erro temporário tenta de novo, erro fixo não', () {
    expect(
      isTemporarySummaryError(
        'Sem legenda (o YouTube recusou a legenda (HTTP 429); ouvir o vídeo falhou: o vídeo é longo demais), e o Gemini falhou: Gemini respondeu 503: high demand',
      ),
      isTrue,
    );
    expect(isTemporarySummaryError('O Gemini demorou demais para responder'), isTrue);
    expect(isTemporarySummaryError('Sem legenda e sem descrição suficiente (o vídeo não tem legenda).'), isFalse);
    expect(isTemporarySummaryError('Chave do Gemini inválida'), isFalse);
    expect(isTemporarySummaryError(null), isFalse);
    expect(summaryRetryWait(0), Duration.zero);
    expect(summaryRetryWait(1), const Duration(minutes: 30));
    expect(summaryRetryWait(2), const Duration(hours: 2));
    expect(summaryRetryWait(7), const Duration(days: 1));
  });
}
