import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player_nostalgico/error_log.dart';
import 'package:player_nostalgico/error_notice.dart';
import 'package:player_nostalgico/screens/event_log_screen.dart';

FileSystemException denied(String path) => FileSystemException('Cannot delete file', path, const OSError('Permission denied', 13));

void main() {
  group('ErrorLog', () {
    test('mesmo evento seguido vira "3×" em vez de três linhas', () {
      final log = ErrorLog();
      for (var i = 0; i < 3; i++) {
        log.info('GIFs', 'nekos.best não respondeu', const SocketException('offline'));
      }
      log.info('Capas', 'MusicBrainz não respondeu');
      expect(log.entries, hasLength(2));
      expect(log.entries.last.count, 3);
      expect(log.entries.first.source, 'Capas');
    });

    test('evento repetido volta para o topo da lista', () {
      final log = ErrorLog()
        ..info('GIFs', 'a')
        ..info('Capas', 'b')
        ..info('GIFs', 'a');
      expect(log.entries.map((e) => e.message), ['a', 'b']);
      expect(log.entries.first.count, 2);
    });

    test('guarda no máximo os últimos 200', () {
      final log = ErrorLog();
      for (var i = 0; i < 250; i++) {
        log.info('Teste', 'evento $i');
      }
      expect(log.entries, hasLength(ErrorLog.maxEntries));
      expect(log.entries.first.message, 'evento 249');
    });

    test('informação não acende o ⚠; aviso e erro acendem; abrir o registro apaga', () {
      final log = ErrorLog()..info('GIFs', 'sem internet');
      expect(log.unseen, 0);
      log
        ..warn('Repetidas', 'Não apagou x.mp3')
        ..fail('App', 'quebrou');
      expect(log.unseen, 2);
      log.markSeen();
      expect(log.unseen, 0);
    });

    test('balão só quando pedido; caixa vermelha só no grave', () async {
      final log = ErrorLog();
      final balloons = <LogEntry>[], severe = <LogEntry>[];
      log
        ..onBalloon = balloons.add
        ..onSevere = severe.add
        ..warn('GIFs', 'cache não salvou')
        ..warn('Repetidas', 'Não apagou x.mp3', error: denied('/m/x.mp3'), balloon: true)
        ..fail('App', 'Erro inesperado', error: StateError('x'), severe: true);
      await Future<void>.delayed(Duration.zero); // os avisos saem fora do build
      expect(balloons.map((e) => e.source), ['Repetidas']);
      expect(severe.map((e) => e.source), ['App']);
    });

    test('motivo em português para os erros comuns', () {
      expect(ErrorLog.reasonOf(denied('/x')), 'permissão negada');
      expect(ErrorLog.reasonOf(const FileSystemException('x', '/x', OSError('No space', 28))), 'sem espaço no celular');
      expect(ErrorLog.reasonOf(const SocketException('x')), 'sem internet ou serviço fora do ar');
      expect(ErrorLog.reasonOf(TimeoutException('x')), 'sem internet ou serviço fora do ar');
      expect(ErrorLog.reasonOf(StateError('x')), isNull);
      expect(ErrorLog.isNetwork(const SocketException('x')), isTrue);
      expect(ErrorLog.isNetwork(denied('/x')), isFalse);
    });

    test('detalhe guarda só o começo da pilha', () {
      final d = ErrorLog.describe(StateError('ruim'), StackTrace.fromString(List.generate(40, (i) => '#$i linha').join('\n')))!;
      expect(d, startsWith('Bad state: ruim'));
      expect('\n'.allMatches(d).length, 6);
    });

    test('salva no celular e lê de volta, mantendo o que chegou antes de abrir', () async {
      final dir = await Directory.systemTemp.createTemp('registro');
      addTearDown(() => dir.delete(recursive: true));
      final a = ErrorLog();
      await a.open(dir.path);
      a
        ..warn('Repetidas', 'Não apagou x.mp3', error: denied('/m/x.mp3'))
        ..info('GIFs', 'sem internet')
        ..info('GIFs', 'sem internet');
      await a.flush();

      final b = ErrorLog()..fail('Notificação', 'não ligou'); // erro na inicialização, antes de abrir
      await b.open(dir.path);
      expect(b.entries.map((e) => e.message), ['não ligou', 'sem internet', 'Não apagou x.mp3']);
      expect(b.entries[1].count, 2);
      expect(b.entries[2].reason, 'permissão negada');
      expect(b.unseen, 2);
    });

    test('registro corrompido recomeça sem quebrar', () async {
      final dir = await Directory.systemTemp.createTemp('registro');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/registro_de_erros.json').writeAsString('{isso não é json');
      final log = ErrorLog();
      await log.open(dir.path);
      expect(log.entries.single.source, 'Registro');
    });

    test('texto para copiar', () {
      final log = ErrorLog()..warn('Repetidas', 'Não apagou x.mp3', error: denied('/m/x.mp3'));
      final txt = ErrorLog.asText(log.entries);
      expect(txt, contains('[Aviso] Repetidas: Não apagou x.mp3'));
      expect(txt, contains('Permission denied'));
    });
  });

  group('balão', () {
    LogEntry e(String src, String msg, [String? reason]) => LogEntry(time: DateTime(2026), level: LogLevel.warning, source: src, message: msg, reason: reason);

    test('um aviso mostra o motivo', () {
      final (title, body) = ErrorNotice.balloonText([e('Repetidas', 'Não apagou x.mp3', 'permissão negada')]);
      expect(title, 'Não apagou x.mp3');
      expect(body, 'Motivo: permissão negada.');
    });

    test('vários avisos em seguida viram um balão só', () {
      final (title, body) = ErrorNotice.balloonText([e('Repetidas', 'Não apagou a.mp3', 'permissão negada'), e('Repetidas', 'Não apagou b.mp3')]);
      expect(title, '2 avisos · Repetidas');
      expect(body, 'Não apagou a.mp3 (permissão negada) e mais 1.');
    });
  });

  group('telas', () {
    testWidgets('ícone da bandeja aparece com o número e some ao abrir o registro', (tester) async {
      final log = ErrorLog();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: TrayErrorIcon(log: log)))));
      expect(find.text('1'), findsNothing);
      log
        ..info('GIFs', 'sem internet')
        ..warn('Repetidas', 'Não apagou x.mp3');
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.pumpWidget(MaterialApp(home: EventLogScreen(log: log)));
      await tester.pump();
      expect(log.unseen, 0);
      expect(find.text('Não apagou x.mp3'), findsOneWidget);
      expect(find.text('sem internet'), findsOneWidget);

      // filtro "Avisos" esconde a informação
      await tester.tap(find.text('Avisos'));
      await tester.pump();
      expect(find.text('sem internet'), findsNothing);

      // tocar na linha mostra os detalhes
      await tester.tap(find.text('Não apagou x.mp3'));
      await tester.pump();
      expect(find.textContaining('Detalhes'), findsOneWidget);
    });

    test('quando: hoje mostra a hora, ontem e antes mostram o dia', () {
      final now = DateTime(2026, 11, 17, 21, 40);
      expect(eventTime(DateTime(2026, 11, 17, 9, 5), now), '09:05');
      expect(eventTime(DateTime(2026, 11, 16, 23, 1), now), 'ontem 23:01');
      expect(eventTime(DateTime(2026, 11, 2, 8), now), '02/11');
    });
  });
}
