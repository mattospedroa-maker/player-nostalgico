import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:player_nostalgico/player_service.dart';

void main() {
  group('avanço manual (botões próxima/anterior)', () {
    test('vai para a próxima música da fila', () {
      expect(PlayerService.nextIndexFor(0, 3, LoopMode.off), 1);
      expect(PlayerService.previousIndexFor(2, 3, LoopMode.off), 1);
    });

    test('"Repetir uma" não prende o botão na mesma música', () {
      expect(PlayerService.nextIndexFor(1, 3, LoopMode.one), 2);
      expect(PlayerService.previousIndexFor(1, 3, LoopMode.one), 0);
    });

    test('na última: para sem repetir; com repetir volta ao começo', () {
      expect(PlayerService.nextIndexFor(2, 3, LoopMode.off), isNull);
      expect(PlayerService.nextIndexFor(2, 3, LoopMode.all), 0);
      expect(PlayerService.nextIndexFor(2, 3, LoopMode.one), 0);
      expect(PlayerService.previousIndexFor(0, 3, LoopMode.off), isNull);
      expect(PlayerService.previousIndexFor(0, 3, LoopMode.all), 2);
    });

    test('fila vazia ou nada tocando', () {
      expect(PlayerService.nextIndexFor(null, 3, LoopMode.off), isNull);
      expect(PlayerService.nextIndexFor(0, 0, LoopMode.all), isNull);
    });
  });
}
