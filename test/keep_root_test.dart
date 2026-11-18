import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player_nostalgico/main.dart';

void main() {
  testWidgets('aba nunca fica vazia: fechar a tela principal reabre ela', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final keep = KeepRootObserver(() => const Text('Tocando agora'));
    await tester.pumpWidget(MaterialApp(
      home: Navigator(
        key: key,
        observers: [keep],
        onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => const Text('Tocando agora')),
      ),
    ));
    expect(find.text('Tocando agora'), findsOneWidget);

    // abre "Editar música" e fecha duas vezes seguidas (o bug: dois toques em OK)
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('Propriedades')));
    await tester.pumpAndSettle();
    key.currentState!.pop();
    key.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.text('Tocando agora'), findsOneWidget);
    expect(keep.open, 1);
  });
}
