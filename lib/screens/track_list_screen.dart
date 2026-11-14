import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets.dart';

/// Lista de músicas com "Tocar tudo" e "Aleatório".
class TrackListScreen extends StatelessWidget {
  final String title;
  final List<Track> tracks;
  const TrackListScreen({super.key, required this.title, required this.tracks});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // usa a versão mais recente (favorita, caminho) de cada faixa
    final list = [for (final t in tracks) app.byId(t.id) ?? t];
    final ps = context.read<PlayerService>();
    void play(int i, {bool shuffle = false}) async {
      await ps.player.setShuffleModeEnabled(shuffle);
      await ps.playQueue(list, start: i);
      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    }

    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: title, actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))]),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Expanded(child: XpButton(label: 'Tocar tudo', icon: Icons.play_arrow, primary: true, onTap: list.isEmpty ? null : () => play(0))),
                const SizedBox(width: 8),
                Expanded(child: XpButton(label: 'Aleatório', icon: Icons.shuffle, onTap: list.isEmpty ? null : () => play(0, shuffle: true))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${list.length} faixas · ${fmtTotal(list)}', style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
              ),
            ),
            Expanded(
              child: ListView.builder(itemCount: list.length, itemBuilder: (_, i) => TrackTile(track: list[i], onTap: () => play(i))),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Artistas / Álbuns / Gêneros / Pastas.
class GroupListScreen extends StatelessWidget {
  final String title;
  final String Function(Track) keyOf;
  final String Function(Track)? subOf;
  const GroupListScreen({super.key, required this.title, required this.keyOf, this.subOf});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final groups = <String, List<Track>>{};
    for (final t in app.tracks) {
      groups.putIfAbsent(keyOf(t), () => []).add(t);
    }
    final keys = groups.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: title, actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))]),
            Expanded(
              child: ListView(children: [
                IpodBox(title: title, trailing: '${keys.length}', children: [
                  for (final k in keys)
                    IpodRow(
                      label: k == '.' ? '(raiz)' : k,
                      detail: subOf != null ? subOf!(groups[k]!.first) : '${groups[k]!.length}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrackListScreen(title: k, tracks: groups[k]!))),
                    ),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
