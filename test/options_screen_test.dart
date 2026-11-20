import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player_nostalgico/crossfade.dart';
import 'package:player_nostalgico/screens/options_screen.dart';
import 'package:player_nostalgico/theme.dart';

class FakeSettings extends ChangeNotifier implements CrossfadeSettings {
  @override
  bool crossfade = true;
  @override
  Duration fadeOut = const Duration(seconds: 4);
  @override
  Duration fadeIn = const Duration(seconds: 4);
  int saves = 0;
  @override
  void setCrossfade(bool on) {
    crossfade = on;
    notifyListeners();
  }

  @override
  void setCrossfadeTimes(Duration out, Duration inn) {
    fadeOut = out;
    fadeIn = inn;
    saves++;
    notifyListeners();
  }
}

void main() {
  Future<FakeSettings> open(WidgetTester t) async {
    t.view.physicalSize = const Size(400, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = FakeSettings();
    await t.pumpWidget(
      MaterialApp(
        theme: Xp.theme(),
        home: OptionsScreen(settings: s),
      ),
    );
    return s;
  }

  testWidgets('mexer nos controles só vale depois de Aplicar; marquinhas andam de 1 em 1 s', (t) async {
    final s = await open(t);
    expect(find.textContaining(': 4 s', findRichText: true), findsNWidgets(2));
    expect(find.text('Versão 2.0.0'), findsOneWidget); // no build do GitHub: 2.0.<número do build>
    final out = find.byKey(const Key('options-out'));
    final box = t.getRect(out);
    await t.tapAt(Offset(box.right - 2, box.center.dy)); // ponta direita = 15 s
    await t.pump();
    expect(find.textContaining('sumindo): 15 s', findRichText: true), findsOneWidget);
    expect(s.fadeOut, const Duration(seconds: 4), reason: 'ainda não aplicou');
    final inn = find.byKey(const Key('options-in'));
    final b2 = t.getRect(inn);
    await t.tapAt(Offset(b2.left + 1, b2.center.dy)); // ponta esquerda = 0 s
    await t.pump();
    expect(find.textContaining('aparecendo): 0 s', findRichText: true), findsOneWidget);
    await t.tap(find.byKey(const Key('options-apply')));
    await t.pump();
    expect(s.fadeOut, const Duration(seconds: 15));
    expect(s.fadeIn, Duration.zero);
  });

  testWidgets('desmarcar e dar OK desliga a transição', (t) async {
    final s = await open(t);
    await t.tap(find.byKey(const Key('options-crossfade')));
    await t.pump();
    expect(s.crossfade, isTrue);
    await t.tap(find.byKey(const Key('options-ok')));
    await t.pump();
    expect(s.crossfade, isFalse);
  });

  testWidgets('arrastar o pegador ajusta o tempo', (t) async {
    await open(t);
    final out = find.byKey(const Key('options-out'));
    final r = t.getRect(out);
    final g = await t.startGesture(Offset(r.left + 10, r.center.dy));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(Offset(r.width * .05, 0));
      await t.pump();
    }
    await g.up();
    await t.pump();
    expect(find.textContaining(RegExp(r'sumindo\): (7|8|9) s$'), findRichText: true), findsOneWidget);
  });
}
