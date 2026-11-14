import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

enum _Sort { recent, plays, az, artist }

class _FavoritesScreenState extends State<FavoritesScreen> {
  _Sort _sort = _Sort.recent;
  Map<int, int> _playCounts = const {};

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    final plays = await context.read<AppState>().db.plays();
    final m = <int, int>{};
    for (final p in plays) {
      if (!p.skipped) m[p.trackId] = (m[p.trackId] ?? 0) + 1;
    }
    if (mounted) setState(() => _playCounts = m);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ps = context.read<PlayerService>();
    final favs = app.tracks.where((t) => t.favorite).toList();
    switch (_sort) {
      case _Sort.recent:
        favs.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case _Sort.plays:
        favs.sort((a, b) => (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0));
      case _Sort.az:
        favs.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case _Sort.artist:
        favs.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
    }
    void play(List<Track> list, int i) {
      ps.playQueue(list, start: i);
      HomeShell.goTo(context, 0);
    }

    return Column(children: [
      const XpTitleBar(title: 'Favoritas'),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _loadCounts,
          child: ListView(padding: EdgeInsets.zero, children: [
            HeroCard(
              title: '♥ ${favs.length} favoritas',
              subtitle: '${fmtTotal(favs)} de música',
              colors: const [Xp.red, Color(0xFFFF33AA)],
              onPlay: favs.isEmpty ? null : () => play(favs, 0),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Wrap(spacing: 6, children: [
                for (final (s, label) in const [(_Sort.recent, 'Recentes'), (_Sort.plays, 'Mais tocadas'), (_Sort.az, 'A–Z'), (_Sort.artist, 'Artista')])
                  ChoiceChip(
                    label: Text(label, style: TextStyle(fontSize: 12, color: _sort == s ? Colors.white : Xp.navy)),
                    selected: _sort == s,
                    selectedColor: const Color(0xFF0F4FC4),
                    backgroundColor: Colors.white,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _sort = s),
                  ),
              ]),
            ),
            if (favs.isEmpty) const EmptyHint(Icons.favorite_border, 'Toque no ♥ de qualquer música para ela aparecer aqui.'),
            for (var i = 0; i < favs.length; i++)
              TrackTile(
                track: favs[i],
                subtitle: '${favs[i].artist} · ${_playCounts[favs[i].id] ?? 0} plays',
                onTap: () => play(favs, i),
              ),
          ]),
        ),
      ),
    ]);
  }
}
