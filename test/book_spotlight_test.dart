import 'dart:io';

import 'package:material_ui/material_ui.dart' hide PageView;
import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/book_text.dart';
import 'package:player_nostalgico/screens/book_reader.dart';

void main() {
  testWidgets('página da pintura: pintura passeando na folha toda, título em cima e legenda no pé', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pintura');
    final art = File('${dir.path}/cap_0.jpg')..writeAsBytesSync(const [0, 1, 2]); // imagem inválida: só o layout importa
    const ch = BookChapter('Capítulo 20', ['Levantei os olhos ao céu, que começava a embruscar-se, e segui.']);
    const page = BookPage(0, 0, [PageSeg(0, 0, 54)], 0, spotlight: true);
    const spec = PageSpec(size: Size(360, 330), body: TextStyle(fontSize: 14, height: 1.4), title: TextStyle(fontSize: 12), padding: EdgeInsets.all(10));
    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 360,
        height: 330,
        child: PageView(chapter: ch, page: page, spec: spec, look: const ReaderLook(), art: art, footer: 'pág. 1 de 9'),
      ),
    ));
    expect(find.byType(KenBurns), findsOneWidget);
    expect(find.text('Capítulo 20'), findsOneWidget);
    expect(find.text('pág. 1 de 9'), findsOneWidget);
    final img = tester.widget<Image>(find.byType(Image));
    expect(img.fit, BoxFit.cover);
    final before = img.alignment;
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<Image>(find.byType(Image)).alignment, isNot(before)); // passeia
    expect(tester.takeException(), isNull); // nada estoura a página
    await tester.pumpWidget(const SizedBox()); // sai da tela: a animação para junto
    dir.deleteSync(recursive: true);
  });
}
