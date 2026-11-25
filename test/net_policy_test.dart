import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player_nostalgico/net_policy.dart';
import 'package:player_nostalgico/screens/options_screen.dart';
import 'package:player_nostalgico/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<NetPolicy> policy([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return NetPolicy(await SharedPreferences.getInstance());
  }

  test('padrão: internet ligada, tudo liberado', () async {
    final n = await policy();
    expect(n.mode, NetMode.online);
    expect(NetFeature.values.every(n.allows), isTrue);
  });

  test('off-line: nada passa', () async {
    final n = await policy();
    await n.set(NetMode.offline, const {});
    expect(n.online, isFalse);
    expect(NetFeature.values.any(n.allows), isFalse);
  });

  test('só no Wi-Fi: libera no Wi-Fi e segura nos dados móveis', () async {
    final n = await policy();
    await n.set(NetMode.wifiOnly, const {});
    var changes = 0;
    n.addListener(() => changes++);
    n.onWifi = false;
    expect(n.allows(NetFeature.gifs), isFalse);
    n.onWifi = true;
    expect(n.allows(NetFeature.gifs), isTrue);
    expect(changes, 2);
  });

  test('item desligado fica de fora mesmo com internet; escolhas ficam salvas', () async {
    final n = await policy();
    await n.set(NetMode.online, {NetFeature.ai, NetFeature.lyrics});
    expect(n.allows(NetFeature.ai), isFalse);
    expect(n.allows(NetFeature.lyrics), isFalse);
    expect(n.allows(NetFeature.covers), isTrue);
    final again = NetPolicy(n.prefs);
    expect(again.disabled, {NetFeature.ai, NetFeature.lyrics});
  });

  testWidgets('aba Internet: off-line desabilita o resto; desmarcar um item', (t) async {
    t.view.physicalSize = const Size(400, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final n = await policy();
    NetMode? mode;
    Set<NetFeature>? off;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, set) => InternetTab(
            policy: n,
            mode: mode,
            off: off,
            onChanged: (m, o) => set(() {
              mode = m;
              off = o;
            }),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const Key('net-ai')));
    await t.pump();
    expect(off, {NetFeature.ai});
    await t.tap(find.byKey(const Key('net-wifi')));
    await t.pump();
    expect(mode, NetMode.wifiOnly);
    await t.tap(find.byKey(const Key('net-offline')));
    await t.pump();
    expect(mode, NetMode.offline);
    expect(t.widget<CheckboxListTile>(find.byKey(const Key('net-gifs'))).onChanged, isNull);
    expect(t.widget<CheckboxListTile>(find.byKey(const Key('net-wifi'))).onChanged, isNull);
  });

  testWidgets('barra de status mostra o modo no canto e muda junto', (t) async {
    final n = await policy();
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [Spacer(), XpStatusBar(['12 músicas', 'Musica'])]))));
    expect(find.text('Internet'), findsOneWidget);
    await n.set(NetMode.wifiOnly, const {});
    n.onWifi = false;
    await t.pump();
    expect(find.text('Só Wi-Fi (esperando)'), findsOneWidget);
    await n.set(NetMode.offline, const {});
    await t.pump();
    expect(find.text('Trabalhando off-line'), findsOneWidget);
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: XpStatusBar(['Opções'], showNet: false))));
    expect(find.byKey(const Key('statusbar-net')), findsNothing);
  });
}
