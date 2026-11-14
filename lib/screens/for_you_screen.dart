import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart';
import '../models.dart';
import '../player_service.dart';
import '../recommender.dart';
import '../theme.dart';
import '../widgets.dart';

class ForYouScreen extends StatefulWidget {
  const ForYouScreen({super.key});

  @override
  State<ForYouScreen> createState() => _ForYouScreenState();
}

class _ForYouScreenState extends State<ForYouScreen> {
  List<Recommendation> _mix = const [], _radio = const [], _rediscover = const [];
  Track? _seed;
  int _lastTrackCount = -1;

  Future<void> _compute() async {
    final app = context.read<AppState>();
    final current = context.read<PlayerService>().current;
    final r = await app.recommender();
    final seed = current ?? (app.tracks.where((t) => t.favorite).firstOrNull);
    var mix = r.mix();
    if (mix.isEmpty) {
      // sem histórico ainda: sugere uma seleção aleatória
      mix = (app.tracks.toList()..shuffle()).take(25).map((t) => Recommendation(t, 0, 'para começar')).toList();
    }
    if (!mounted) return;
    setState(() {
      _mix = mix;
      _seed = seed;
      _radio = seed == null ? const [] : r.radio(seed);
      _rediscover = r.rediscover();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ps = context.read<PlayerService>();
    if (_lastTrackCount != app.tracks.length) {
      _lastTrackCount = app.tracks.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _compute());
    }
    void playRecs(List<Recommendation> recs, [int i = 0]) {
      if (recs.isEmpty) return;
      ps.playQueue([for (final r in recs) r.track], start: i);
      HomeShell.goTo(context, 0);
    }

    return Column(children: [
      XpTitleBar(title: 'Para você', actions: [XpTitleButton(icon: Icons.refresh, tooltip: 'Atualizar', onTap: _compute)]),
      Expanded(
        child: app.tracks.isEmpty
            ? const EmptyHint(Icons.auto_awesome, 'Escolha sua pasta de músicas na Biblioteca primeiro.')
            : ListView(padding: EdgeInsets.zero, children: [
                HeroCard(
                  title: 'Mix do momento',
                  subtitle: '${_mix.length} faixas · baseado no que você ouviu nos últimos 30 dias',
                  colors: const [Xp.blue, Color(0xFF7A3CD8)],
                  onPlay: () => playRecs(_mix),
                ),
                if (_seed != null)
                  HeroCard(
                    title: 'Rádio: ${_seed!.title}',
                    subtitle: 'artista, gênero e o que você costuma ouvir em seguida',
                    colors: const [Xp.navyDeep, Color(0xFF2A4FA8)],
                    onPlay: () => playRecs(_radio),
                  ),
                if (_rediscover.isNotEmpty) ...[
                  const SectionLabel('Redescobrir · não toca há meses'),
                  for (var i = 0; i < _rediscover.length; i++)
                    TrackTile(track: _rediscover[i].track, note: _rediscover[i].reason, onTap: () => playRecs(_rediscover, i)),
                ],
                const SectionLabel('No mix'),
                for (var i = 0; i < _mix.length && i < 10; i++)
                  TrackTile(track: _mix[i].track, note: _mix[i].reason, onTap: () => playRecs(_mix, i)),
                const SizedBox(height: 20),
              ]),
      ),
    ]);
  }
}
