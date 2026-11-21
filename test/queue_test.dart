import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/player_service.dart';

void main() {
  group('Adicionar à fila', () {
    test('entra depois das que você já pôs, antes do resto', () {
      final seq = ['atual', 'q1', 'q2', 'velha1', 'velha2'];
      expect(PlayerService.queueEndPos(seq, 1, (t) => t.startsWith('q')), 3);
    });
    test('sem nada posto, entra logo depois da atual', () {
      expect(PlayerService.queueEndPos(['atual', 'velha'], 1, (_) => false), 1);
    });
    test('fila no fim: vai para o final', () {
      expect(PlayerService.queueEndPos(['atual', 'q1'], 1, (t) => t == 'q1'), 2);
    });
  });

  group('Reordenar não mexe no bloco "a seguir"', () {
    test('aleatório mantém as postas na frente, na mesma ordem', () {
      final current = ['q1', 'q2', 'a', 'b', 'c'];
      final shuffled = ['c', 'q2', 'a', 'q1', 'b'];
      expect(PlayerService.keepQueuedFirst(shuffled, current, (t) => t.startsWith('q')), ['q1', 'q2', 'c', 'a', 'b']);
    });
    test('sem bloco, fica como pedido', () {
      expect(PlayerService.keepQueuedFirst(['b', 'a'], ['a', 'b'], (_) => false), ['b', 'a']);
    });
    test('só conta o bloco do começo', () {
      // "q9" está no meio da fila velha (já tocou o bloco antes dele): pode ser reordenado
      expect(PlayerService.keepQueuedFirst(['q9', 'a'], ['a', 'q9'], (t) => t.startsWith('q')), ['q9', 'a']);
    });
  });

  group('Trocar o mix com uma lista na fila', () {
    test('sobrou música da lista: o painel troca pelo mix', () {
      expect(PlayerService.listAhead(['q1', 'album2', 'mix1'], (t) => t.startsWith('q') || t.startsWith('mix')), isTrue);
    });
    test('só mix e músicas postas por você: nada da lista', () {
      expect(PlayerService.listAhead(['q1', 'mix1', 'mix2'], (t) => t.startsWith('q') || t.startsWith('mix')), isFalse);
      expect(PlayerService.listAhead(<String>[], (_) => false), isFalse);
    });
  });
}
