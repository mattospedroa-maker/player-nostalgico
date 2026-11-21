import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/widgets.dart';

void main() {
  testWidgets('botões Tocar a seguir / À fila cabem ao lado da capa num celular estreito', (tester) async {
    for (final w in [220.0, 240.0, 300.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Center(child: SizedBox(width: w, child: const QueueButtons(<Track>[])))),
      ));
      expect(tester.takeException(), isNull, reason: 'largura $w');
      expect(find.text(w < 280 ? 'A seguir' : 'Tocar a seguir'), findsOneWidget);
      expect(find.text('À fila'), findsOneWidget);
    }
  });
}
