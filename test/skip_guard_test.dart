import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/skip_guard.dart';
import 'package:player_nostalgico/skip_notice.dart';

void main() {
  group('SkipGuard', () {
    test('pula para a próxima quando uma música não abre', () {
      final g = SkipGuard();
      expect(g.onError(2, 5, failed: (_) => false), 3);
    });

    test('pula as que já falharam antes', () {
      final g = SkipGuard();
      final bad = {3, 4};
      expect(g.onError(2, 6, failed: bad.contains), 5);
    });

    test('para no fim da fila quando não repete', () {
      final g = SkipGuard();
      expect(g.onError(4, 5, failed: (_) => false), isNull);
    });

    test('recomeça do início quando está repetindo tudo', () {
      final g = SkipGuard();
      expect(g.onError(4, 5, wrap: true, failed: (_) => false), 0);
    });

    test('fila com uma música só: para', () {
      final g = SkipGuard();
      expect(g.onError(0, 1, failed: (_) => false), isNull);
    });

    test('todas falham (repetindo tudo): para depois de uma volta, sem loop', () {
      final g = SkipGuard();
      final bad = <int>{};
      var i = 0;
      var jumps = 0;
      while (true) {
        bad.add(i);
        final to = g.onError(i, 4, wrap: true, failed: bad.contains);
        if (to == null) break;
        i = to;
        jumps++;
        expect(jumps, lessThan(10), reason: 'entrou em loop');
      }
      expect(jumps, 3);
      expect(bad, {0, 1, 2, 3});
    });

    test('desiste depois de muitas falhas seguidas, mesmo numa fila enorme', () {
      final g = SkipGuard();
      var i = 0;
      var jumps = 0;
      int? to;
      do {
        to = g.onError(i, 1000, failed: (j) => j < i);
        if (to != null) {
          i = to;
          jumps++;
        }
      } while (to != null);
      expect(jumps, SkipGuard.maxStreak - 1);
    });

    test('uma música que abre zera a contagem', () {
      final g = SkipGuard();
      for (var i = 0; i < SkipGuard.maxStreak - 1; i++) {
        g.onError(i, 1000, failed: (_) => false);
        g.onReady();
      }
      expect(g.streak, 0);
      expect(g.onError(500, 1000, failed: (_) => false), 501);
    });

    test('o mesmo erro avisado duas vezes não pula duas músicas', () {
      final g = SkipGuard();
      expect(g.onError(1, 5, failed: (_) => false), 2);
      expect(g.onError(1, 5, failed: (_) => false), -1);
      expect(g.streak, 1);
    });

    test('depois de reset, a mesma posição pode falhar de novo (tentar de novo)', () {
      final g = SkipGuard();
      g.onError(1, 5, failed: (_) => false);
      g.reset();
      expect(g.onError(1, 5, failed: (_) => false), 2);
    });
  });

  group('PlaybackFailure', () {
    test('arquivo que não existe = apagado; existe mas não abre = com defeito', () {
      final dir = Directory.systemTemp.createTempSync('falha');
      addTearDown(() => dir.deleteSync(recursive: true));
      final broken = File('${dir.path}/quebrada.mp3')..writeAsStringSync('isto não é mp3');
      expect(PlaybackFailure.reasonFor('${dir.path}/sumiu.mp3'), FailReason.missing);
      expect(PlaybackFailure.reasonFor(broken.path), FailReason.broken);
      expect(PlaybackFailure(broken.path, FailReason.broken).reasonText, 'arquivo com defeito');
    });
  });

  group('Balão de música pulada', () {
    Track t(String title) => Track(path: '/m/$title.mp3', title: title, artist: 'X', album: '', addedAt: 0, modifiedAt: 0);
    test('uma música: diz qual e o motivo', () {
      final (title, body) = SkipNotice.balloonText([(t('Ritual'), PlaybackFailure('/m/Ritual.mp3', FailReason.missing))]);
      expect(title, 'Música pulada');
      expect(body, contains('"Ritual" não abriu (arquivo apagado)'));
    });
    test('várias seguidas viram um balão só', () {
      final f = PlaybackFailure('/x', FailReason.broken);
      final (title, body) = SkipNotice.balloonText([for (final n in ['A', 'B', 'C', 'D', 'E']) (t(n), f)]);
      expect(title, '5 músicas puladas');
      expect(body, startsWith('A, B, C e mais 2 não abriram.'));
    });
  });
}
