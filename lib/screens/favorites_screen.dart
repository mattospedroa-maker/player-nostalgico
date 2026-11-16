import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart';
import '../models.dart';
import '../player_service.dart';
import '../recommender.dart';
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';

/// Favoritas + Para você, no jeito do MSN Messenger 6: o "Mix do momento" é o cartão de perfil
/// e as listas são grupos de contatos que abrem e fecham.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

enum _Sort { recent, plays, az, artist }

class _FavoritesScreenState extends State<FavoritesScreen> {
  _Sort _sort = _Sort.recent;
  Map<int, int> _playCounts = const {};
  List<Recommendation> _mix = const [], _radio = const [], _rediscover = const [];
  Track? _seed;
  int _lastTrackCount = -1;
  final _open = <String>{'fav', 'rediscover'};

  Future<void> _refresh() async {
    final app = context.read<AppState>();
    final current = context.read<PlayerService>().current;
    final plays = await app.db.plays();
    final m = <int, int>{};
    for (final p in plays) {
      if (!p.skipped) m[p.trackId] = (m[p.trackId] ?? 0) + 1;
    }
    final r = await app.recommender();
    final seed = current ?? (app.tracks.where((t) => t.favorite).firstOrNull);
    var mix = r.mix();
    if (mix.isEmpty) {
      // sem histórico ainda: sugere uma seleção aleatória
      mix = (app.tracks.toList()..shuffle()).take(25).map((t) => Recommendation(t, 0, 'para começar')).toList();
    }
    if (!mounted) return;
    setState(() {
      _playCounts = m;
      _mix = mix;
      _seed = seed;
      _radio = seed == null ? const [] : r.radio(seed);
      _rediscover = r.rediscover();
    });
  }

  void _play(List<Track> list, int i, {bool mix = false}) {
    context.read<PlayerService>().playQueue(list, start: i, mix: mix);
    HomeShell.goTo(context, 0);
  }

  void _playRecs(List<Recommendation> recs, [int i = 0]) {
    if (recs.isEmpty) return;
    _play([for (final r in recs) r.track], i, mix: true);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final playing = context.select<PlayerService, bool>((p) => p.playing);
    if (_lastTrackCount != app.tracks.length) {
      _lastTrackCount = app.tracks.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
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
    final top = [...app.tracks.where((t) => (_playCounts[t.id] ?? 0) > 0)]..sort((a, b) => (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0));
    const sorts = [(_Sort.recent, 'Recentes'), (_Sort.plays, 'Mais tocadas'), (_Sort.az, 'A–Z'), (_Sort.artist, 'Artista')];

    return Column(
      children: [
        XpTitleBar(
          title: 'Favoritas e Para você',
          icon: XpIcons.heart,
          actions: [XpTitleButton(icon: Icons.refresh, tooltip: 'Atualizar', onTap: _refresh)],
        ),
        XpMenuBar([
          ('Exibir', [for (final (s, label) in sorts) XpMenuItem('Favoritas: $label', () => setState(() => _sort = s), checked: _sort == s)]),
          (
            'Ações',
            [
              XpMenuItem('Tocar o Mix do momento', _mix.isEmpty ? null : () => _playRecs(_mix)),
              XpMenuItem('Tocar todas as favoritas', favs.isEmpty ? null : () => _play(favs, 0)),
              XpMenuItem('Atualizar sugestões', _refresh),
            ],
          ),
        ]),
        Expanded(
          child: ColoredBox(
            color: Colors.white,
            child: app.tracks.isEmpty
                ? const EmptyHint(Icons.auto_awesome, 'Escolha sua pasta de músicas na Biblioteca primeiro.')
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _profile(playing),
                        _group('fav', 'Favoritas', favs.length, [
                          if (favs.isEmpty) _hint('Toque no ♥ de qualquer música para ela aparecer aqui.'),
                          for (var i = 0; i < favs.length; i++)
                            _buddy(favs[i], XpIcons.heart, '${favs[i].artist} · ${_playCounts[favs[i].id] ?? 0} plays', () => _play(favs, i)),
                        ]),
                        if (_rediscover.isNotEmpty)
                          _group('rediscover', 'Redescobrir · não toca há meses', _rediscover.length, [
                            for (var i = 0; i < _rediscover.length; i++)
                              _buddy(_rediscover[i].track, XpIcons.person, _rediscover[i].reason, () => _playRecs(_rediscover, i)),
                          ]),
                        if (_seed != null && _radio.isNotEmpty)
                          _group('radio', 'Rádio: ${_seed!.title}', _radio.length, [
                            for (var i = 0; i < _radio.length; i++) _buddy(_radio[i].track, XpIcons.note, _radio[i].reason, () => _playRecs(_radio, i)),
                          ]),
                        _group('mix', 'No Mix do momento', _mix.length, [
                          for (var i = 0; i < _mix.length; i++) _buddy(_mix[i].track, XpIcons.note, _mix[i].reason, () => _playRecs(_mix, i)),
                        ]),
                        if (top.isNotEmpty)
                          _group('top', 'Mais tocadas', top.length.clamp(0, 50), [
                            for (var i = 0; i < top.length && i < 50; i++)
                              _buddy(top[i], XpIcons.star, '${top[i].artist} · ${_playCounts[top[i].id]} plays', () => _play(top.take(50).toList(), i)),
                          ]),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
          ),
        ),
        XpStatusBar(['Pronto', '${favs.length} favoritas']),
      ],
    );
  }

  Widget _profile(bool playing) {
    final first = _mix.firstOrNull?.track;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white, Color(0xFFDCE7FB)]),
        border: Border(bottom: BorderSide(color: Color(0xFF9DB3E0))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFF7F9DB9)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: first == null
                  ? const SizedBox(width: 58, height: 58, child: Center(child: XpIcon(XpIcons.cassette, size: 40)))
                  : CoverSquare(first, size: 58),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Mix do momento', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Status: '),
                      TextSpan(
                        text: playing ? 'Tocando ♫' : 'Pronto',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1C56D0)),
                      ),
                      TextSpan(text: ' · ${_mix.length} faixas'),
                    ],
                  ),
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555)),
                ),
                const Text(
                  '“baseado no que você ouviu nos últimos 30 dias”',
                  style: TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic, color: Color(0xFF333333)),
                ),
              ],
            ),
          ),
          GlossyButton(icon: Icons.play_arrow, size: 46, onTap: _mix.isEmpty ? null : () => _playRecs(_mix), tooltip: 'Tocar o mix'),
        ],
      ),
    );
  }

  Widget _group(String id, String title, int count, List<Widget> children) {
    final open = _open.contains(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => open ? _open.remove(id) : _open.add(id)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 9, 8, 5),
            child: Row(
              children: [
                Container(
                  width: 13,
                  height: 13,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFF7F9DB9)),
                  ),
                  child: Text(
                    open ? '−' : '+',
                    style: const TextStyle(fontSize: 11, height: 1, color: Color(0xFF1C3F94), fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '$title ($count)',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF1C3F94)),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open) ...children,
      ],
    );
  }

  Widget _buddy(Track t, XpIcons icon, String detail, VoidCallback onTap) {
    final playing = context.select<PlayerService, int?>((p) => p.current?.id) == t.id;
    return GestureDetector(
      onLongPressStart: (d) => showTrackMenu(context, t, at: d.globalPosition),
      child: InkWell(
      onTap: onTap,
      child: Container(
        color: playing ? const Color(0xFFDCE7FB) : null,
        padding: const EdgeInsets.fromLTRB(28, 6, 10, 6),
        child: Row(
          children: [
            XpIcon(icon, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: t.title,
                      style: TextStyle(fontWeight: playing ? FontWeight.bold : FontWeight.normal),
                    ),
                    TextSpan(
                      text: '  — $detail',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF777777)),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5, color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    ));
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 4, 10, 8),
    child: Text(text, style: const TextStyle(fontSize: 12.5, color: Color(0xFF777777))),
  );
}
