import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/download_service.dart';
import 'package:player_nostalgico/experience_ai.dart';
import 'package:player_nostalgico/experiences.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/styles.dart';
import 'package:player_nostalgico/track_sheet.dart';

Track _t(int id, String artist, String title) =>
    Track(id: id, path: '/m/$id.mp3', title: title, artist: artist, album: 'A', addedAt: 0, modifiedAt: 0);

Sheet _empty(Track _) => const Sheet([], [], [], [], [], []);

void main() {
  setUp(Styles.invalidate);

  test('inventar sem internet: "cavalgada no deserto ao pôr do sol" puxa faroeste', () {
    final th = ExperienceAi.offlineTheme('cavalgada no deserto ao pôr do sol');
    expect(th.scenes.keys.first, 'faroeste');
    expect(th.title, 'Cavalgada no deserto ao pôr do sol');
    expect(th.emoji, '🤠');
    expect(th.words, containsAll(['cavalgada', 'deserto']));
  });

  test('tema da IA: cenas fora da lista saem, lista vira pesos, sem pista nenhuma é recusado', () {
    final a = AiTheme.fromJson({'title': 'O Bom, o Mau e o Feio', 'emoji': '🌵', 'scenes': ['faroeste', 'inventada', 'cinema'], 'missing': ['Ennio Morricone — The Ecstasy of Gold']})!;
    expect(a.scenes, {'faroeste': 1.0, 'cinema': .75});
    expect(a.id, 'ia:o-bom-o-mau-e-o-feio');
    expect(AiTheme.fromJson({'title': 'Nada', 'scenes': ['xyz']}), isNull);
    expect(AiTheme.fromJson({'title': '', 'words': ['a']}), isNull);
    final list = ExperienceAi.parseThemes({'themes': [{'title': 'A', 'words': ['western']}, 'lixo', {'title': 'B'}]});
    expect(list.map((t) => t.title), ['A']);
  });

  test('palavras e artistas do tema acham as músicas mesmo sem cena', () {
    final lib = [
      for (var i = 1; i <= 6; i++) _t(i, 'Ennio Morricone', 'Western Theme $i'),
      for (var i = 7; i <= 12; i++) _t(i, 'Banda $i', 'Whistle in the desert $i'),
      for (var i = 13; i <= 20; i++) _t(i, 'Outra', 'Nada a ver $i'),
    ];
    const r = ExperienceRecipe('ia:x', 'X', '🌵', {}, words: ['western', 'whistle', 'desert'], artists: ['Ennio Morricone']);
    final got = ExperienceEngine.pick(r, lib, rnd: Random(1), sheetOf: _empty, aiOf: (_) => null);
    final ids = got.map((x) => x.$1.id!).toSet();
    expect(ids.every((id) => id <= 12), isTrue);
    expect(ids.where((id) => id > 6).length, 6); // as de "whistle/desert"
    expect(ids.where((id) => id <= 6).length, 3); // no máximo 3 do mesmo artista
  });

  test('"Para completar" só lista o que você ainda não tem', () {
    final lib = [_t(1, 'Ennio Morricone', 'The Good, the Bad and the Ugly (Main Theme)')];
    expect(
      ExperienceEngine.missingFrom(['Ennio Morricone — The Good, the Bad and the Ugly', 'Ennio Morricone — The Ecstasy of Gold'], lib),
      ['Ennio Morricone — The Ecstasy of Gold'],
    );
  });

  test('tema da IA entra no ar com selo IA, prazo e "Para completar"', () {
    final lib = [for (var i = 1; i <= 20; i++) _t(i, 'Art ${i % 7}', 'Western $i')];
    const th = AiTheme(title: 'Duelo', emoji: '🌵', words: ['western'], missing: ['X — Y']);
    const now = 1000000000000;
    final s = ExperienceEngine.refresh(ExperienceState.empty, lib, nowMs: now, rnd: Random(1), sheetOf: _empty, aiOf: (_) => null, aiThemes: [th]);
    final e = s.active.firstWhere((e) => e.kind == 'ia');
    expect(e.title, 'Duelo');
    expect(e.missing, ['X — Y']);
    expect(s.recent, contains(th.id));
    // na próxima renovação o mesmo tema não volta
    final s2 = ExperienceEngine.refresh(ExperienceState(const [], s.recent), lib, nowMs: now, rnd: Random(1), sheetOf: _empty, aiOf: (_) => null, aiThemes: [th]);
    expect(s2.active.where((e) => e.kind == 'ia'), isEmpty);
  });

  test('busca por nome passa direto para o yt-dlp', () {
    expect(DownloadService.normalizeUrl('ytsearch1:Mr. Brightside'), 'ytsearch1:Mr. Brightside');
  });

  test('pedidos à IA trazem o resumo e a lista de cenas', () {
    final p = ExperienceAi.weeklyPrompt('Total: 10 músicas.', avoid: ['motim no navio']);
    expect(p, contains('Total: 10 músicas.'));
    expect(p, contains('Não repita estes temas: motim no navio.'));
    expect(p, contains('faroeste (faroeste)'));
    expect(ExperienceAi.inventPrompt('chuva fina', 'R'), contains('"chuva fina"'));
    expect(TrackSheet.sceneByKey, isNotEmpty);
  });
}
