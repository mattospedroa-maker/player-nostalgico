import 'dart:async';
import 'dart:io';


import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:audio_service/audio_service.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_state.dart';
import 'audio_handler.dart';
import 'screens/duplicates_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/library_screen.dart';
import 'screens/now_playing_screen.dart';
import 'screens/organizer_screen.dart';
import 'screens/playlists_screen.dart';
import 'screens/youtube_screen.dart';
import 'skip_notice.dart';
import 'theme.dart';
import 'widgets.dart';
import 'xp_icons.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BootScreen());
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  PlayerAudioHandler? handler;
  try {
    handler = await AudioService.init(
      builder: PlayerAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.playernostalgico.audio',
        androidNotificationChannelName: 'Reprodução',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (e) {
    // desktop/testes: sem notificação. No Android, mostra o erro para dar para corrigir.
    if (Platform.isAndroid) audioInitError = '$e';
  }
  final app = await AppState.create(handler: handler);
  SkipNotice.attach(app.player);
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider.value(value: app.player),
        ChangeNotifierProvider.value(value: app.gifs),
        ChangeNotifierProvider.value(value: app.downloads),
      ],
      child: const PlayerApp(),
    ),
  );
}

/// Tela de abertura no estilo do boot do Windows XP, enquanto a biblioteca é lida.
class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: Xp.theme(),
        home: const Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                XpIcon(XpIcons.cassette, size: 96),
                SizedBox(height: 14),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: 'Nostalgic ', style: TextStyle(color: Colors.white)),
                      TextSpan(text: 'MPlayer', style: TextStyle(color: Color(0xFFF39C2B), fontStyle: FontStyle.italic)),
                    ],
                  ),
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                ),
                Text('edição anos 2000', style: TextStyle(color: Color(0xFF9DB3E0), fontSize: 13)),
                SizedBox(height: 46),
                SizedBox(width: 150, child: _BootBar()),
                SizedBox(height: 18),
                Text('Lendo a biblioteca…', style: TextStyle(color: Color(0xFF8899AA), fontSize: 13)),
              ],
            ),
          ),
        ),
      );
}

/// Barra do boot do XP: fundo preto com borda cinza arredondada e 3 bloquinhos azuis correndo.
class _BootBar extends StatefulWidget {
  const _BootBar();

  @override
  State<_BootBar> createState() => _BootBarState();
}

class _BootBarState extends State<_BootBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        height: 18,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(border: Border.all(color: const Color(0xFFB0B0B0), width: 1.5), borderRadius: BorderRadius.circular(5)),
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) => LayoutBuilder(
              builder: (_, c) {
                const w = 9.0, gap = 2.0, group = 3 * w + 2 * gap;
                final x = -group + (c.maxWidth + group) * _c.value;
                return Stack(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Positioned(
                        left: x + i * (w + gap),
                        top: 0,
                        bottom: 0,
                        width: w,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF9FC0F7), Color(0xFF2A64E0), Color(0xFF1C4FC4), Color(0xFF7FA8F0)],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      );
}

class PlayerApp extends StatelessWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Nostalgic MPlayer',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: appMessengerKey,
        navigatorKey: appNavigatorKey,
        theme: Xp.theme(),
        home: const HomeShell(),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  static void goTo(BuildContext context, int tab) => context.findAncestorStateOfType<_HomeShellState>()?.select(tab);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 1; // começa na Biblioteca (página inicial)
  bool _startOpen = false;

  /// Cada aba tem a própria pilha de telas: trocar de aba e voltar mantém onde você estava.
  final _navs = List.generate(4, (_) => GlobalKey<NavigatorState>());

  void select(int i) => setState(() {
    _startOpen = false;
    _tab = i;
  });

  void _tapTab(int i) {
    if (i == _tab) {
      // tocar de novo na aba ativa volta ao começo dela
      _navs[i].currentState?.popUntil((r) => r.isFirst);
    }
    select(i);
  }

  static const _tabs = [(XpIcons.cassette, 'Tocando'), (XpIcons.folder, 'Biblioteca'), (XpIcons.list, 'Playlists'), (XpIcons.heart, 'Favoritas')];

  static const _roots = <Widget>[NowPlayingScreen(), LibraryScreen(), PlaylistsScreen(), FavoritesScreen()];

  Widget _tabNavigator(int i) => Navigator(
    key: _navs[i],
    onGenerateRoute: (s) => MaterialPageRoute<void>(settings: s, builder: (_) => _roots[i]),
  );

  void _openTool(Widget screen) {
    setState(() => _startOpen = false);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_startOpen) return setState(() => _startOpen = false);
        final nav = _navs[_tab].currentState;
        if (nav != null && await nav.maybePop()) return;
        if (_tab != 1) return select(1);
        await SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF3A6EA5),
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  // moldura azul da janela do XP
                  decoration: const BoxDecoration(
                    color: Xp.beige,
                    border: Border(
                      left: BorderSide(color: Color(0xFF0831D9), width: 3),
                      right: BorderSide(color: Color(0xFF0831D9), width: 3),
                    ),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: IndexedStack(index: _tab, children: [for (var i = 0; i < _tabs.length; i++) _tabNavigator(i)]),
                ),
              ),
              if (_startOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _startOpen = false),
                    child: const ColoredBox(color: Color(0x22000000)),
                  ),
                ),
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: StartMenu(
                    items: [
                      StartItem(XpIcons.find, 'Buscar novas músicas', () => _openTool(const OrganizerScreen())),
                      null,
                      StartItem(XpIcons.youtube, 'Baixar do YouTube', () => _openTool(const YoutubeScreen())),
                      StartItem(XpIcons.duplicate, 'Músicas repetidas', () => _openTool(const DuplicatesScreen())),
                      StartItem(XpIcons.film, 'Acervo de GIFs', () {
                        setState(() => _startOpen = false);
                        showGifLibraryInfo(context);
                      }),
                      StartItem(
                        XpIcons.refresh,
                        'Reler pasta de músicas',
                        app.sourceRoot == null
                            ? null
                            : () {
                                setState(() => _startOpen = false);
                                app.rescan();
                              },
                      ),
                      StartItem(XpIcons.folder, 'Trocar pasta de músicas', () {
                        setState(() => _startOpen = false);
                        chooseMusicFolder(context);
                      }),
                      null,
                      StartItem(XpIcons.power, 'Sair…', () => SystemNavigator.pop()),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        bottomNavigationBar: Taskbar(
          tabs: _tabs,
          current: _tab,
          startOpen: _startOpen,
          onTab: _tapTab,
          onStart: () => setState(() => _startOpen = !_startOpen),
        ),
      ),
    );
  }
}

/// Barra de tarefas do XP: botão "iniciar", uma "janela" por aba e o relógio.
class Taskbar extends StatelessWidget {
  final List<(XpIcons, String)> tabs;
  final int current;
  final bool startOpen;
  final ValueChanged<int> onTab;
  final VoidCallback onStart;
  const Taskbar({super.key, required this.tabs, required this.current, required this.startOpen, required this.onTab, required this.onStart});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF3168D5), Color(0xFF4993E6), Color(0xFF2157D7), Color(0xFF245EDB), Color(0xFF1941A5)],
        stops: [0, .06, .12, .5, 1],
      ),
    ),
    child: SafeArea(
      top: false,
      child: SizedBox(
        height: 54,
        child: Row(
          children: [
            GestureDetector(
              onTap: onStart,
              child: Container(
                width: 92,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(16)),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: startOpen ? const [Color(0xFF1A4BB5), Color(0xFF1F5FD8)] : const [Color(0xFF5AA6FF), Color(0xFF1F5FD8), Color(0xFF1A4BB5)],
                  ),
                  boxShadow: const [BoxShadow(color: Color(0xFF0C2F86), offset: Offset(1, 0), blurRadius: 2)],
                ),
                child: const Text(
                  'iniciar',
                  style: TextStyle(
                    color: Colors.white,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.bold,
                    fontSize: 19,
                    shadows: [Shadow(color: Color(0xFF0A1D55), offset: Offset(1, 1), blurRadius: 2)],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onTab(i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: const Color(0xFF1A46B0)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: i == current ? const [Color(0xFF1E46B2), Color(0xFF1A3D9E)] : const [Color(0xFF3C81F3), Color(0xFF2A64E0)],
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        XpIcon(tabs[i].$1, size: 17),
                        const SizedBox(height: 1),
                        Text(
                          tabs[i].$2,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: i == current ? FontWeight.bold : FontWeight.normal),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const _Clock(),
          ],
        ),
      ),
    ),
  );
}

class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late final Timer _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 20), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF139EE9), Color(0xFF18B5F2), Color(0xFF1290E8), Color(0xFF0D8DEA)],
          stops: [0, .1, .5, 1],
        ),
        border: Border(left: BorderSide(color: Color(0xFF092E7A))),
      ),
      child: Text('${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: Colors.white, fontSize: 13)),
    );
  }
}

class StartItem {
  final XpIcons icon;
  final String label;
  final VoidCallback? onTap;
  const StartItem(this.icon, this.label, this.onTap);
}

/// Menu "iniciar" no estilo do Windows 98: faixa lateral com o nome do app e ícones grandes.
class StartMenu extends StatelessWidget {
  final List<StartItem?> items; // null = separador
  const StartMenu({super.key, required this.items});

  @override
  Widget build(BuildContext context) => Container(
    width: 300,
    decoration: const BoxDecoration(
      color: Color(0xFFC0C0C0),
      border: Border(
        top: BorderSide(color: Colors.white, width: 2),
        left: BorderSide(color: Colors.white, width: 2),
        right: BorderSide(color: Color(0xFF404040), width: 2),
        bottom: BorderSide(color: Color(0xFF404040), width: 2),
      ),
      boxShadow: [BoxShadow(color: Colors.black, offset: Offset(2, 2))],
    ),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 32,
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xFF0A246A), Color(0xFF3A6FF0)]),
            ),
            alignment: Alignment.bottomCenter,
            padding: const EdgeInsets.only(bottom: 10),
            child: const RotatedBox(
              quarterTurns: 3,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Nostalgic ',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    TextSpan(
                      text: 'MPlayer',
                      style: TextStyle(color: Color(0xFFBCD2FF)),
                    ),
                  ],
                ),
                style: TextStyle(fontSize: 18),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final it in items)
                    if (it == null)
                      Container(
                        height: 2,
                        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                        decoration: const BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Color(0xFF808080)),
                            bottom: BorderSide(color: Colors.white),
                          ),
                        ),
                      )
                    else
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: it.onTap,
                          hoverColor: Xp.navy,
                          splashColor: Xp.navy,
                          child: Opacity(
                            opacity: it.onTap == null ? .45 : 1,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                              child: Row(
                                children: [
                                  XpIcon(it.icon, size: 30),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(it.label, style: const TextStyle(fontSize: 15, color: Colors.black)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
