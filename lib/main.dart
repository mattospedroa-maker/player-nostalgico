import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_state.dart';
import 'screens/for_you_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/library_screen.dart';
import 'screens/now_playing_screen.dart';
import 'screens/playlists_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await JustAudioBackground.init(
    androidNotificationChannelId: 'dev.playernostalgico.audio',
    androidNotificationChannelName: 'Reprodução',
    androidNotificationOngoing: true,
  );
  final app = await AppState.create();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider.value(value: app.player),
        ChangeNotifierProvider.value(value: app.gifs),
      ],
      child: const PlayerApp(),
    ),
  );
}

class PlayerApp extends StatelessWidget {
  const PlayerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Player Nostálgico',
        debugShowCheckedModeBanner: false,
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

  void select(int i) => setState(() => _tab = i);

  static const _tabs = [
    (Icons.play_arrow, 'Tocando'),
    (Icons.library_music, 'Biblioteca'),
    (Icons.queue_music, 'Playlists'),
    (Icons.favorite, 'Favoritas'),
    (Icons.auto_awesome, 'Para você'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          bottom: false,
          child: IndexedStack(index: _tab, children: const [
            NowPlayingScreen(),
            LibraryScreen(),
            PlaylistsScreen(),
            FavoritesScreen(),
            ForYouScreen(),
          ]),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF2A73E8), Color(0xFF0F4FC4)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
          border: Border(top: BorderSide(color: Color(0xFF8FB6FF))),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 60,
            child: Row(children: [
              for (var i = 0; i < _tabs.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => select(i),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(_tabs[i].$1, color: i == _tab ? Colors.white : const Color(0xFFCFE0FF), size: 22),
                      const SizedBox(height: 2),
                      Text(_tabs[i].$2,
                          style: TextStyle(
                            fontSize: 11,
                            color: i == _tab ? Colors.white : const Color(0xFFCFE0FF),
                            fontWeight: i == _tab ? FontWeight.bold : FontWeight.normal,
                          )),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
