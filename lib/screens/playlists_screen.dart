import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../list_search.dart';
import '../main.dart';
import '../models.dart';
import '../mood.dart';
import '../recommender.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> with InListSearch {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final shown = searching ? [for (final pl in app.playlists) if (textMatches(searchQuery, [pl.name])) pl] : app.playlists;
    return Column(children: [
      XpTitleBar(title: 'Playlists', icon: XpIcons.list, actions: [searchButton()]),
      XpAddressBar(searchPath('Playlists')),
      searchBox('Pesquisar playlist pelo nome…'),
      Padding(
        padding: const EdgeInsets.all(8),
        child: XpButton(
          label: 'Nova playlist',
          xpIcon: XpIcons.plus,
          onTap: () async {
            final name = await askText(context, 'Nova playlist', 'Nome');
            if (name != null && name.isNotEmpty) await app.createPlaylist(name);
          },
        ),
      ),
      Expanded(
        child: app.playlists.isEmpty
            ? const EmptyHint(Icons.queue_music, 'Nenhuma playlist ainda.\nSegure uma música para adicionar a uma playlist.')
            : shown.isEmpty
                ? noMatches()
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .95),
                    itemCount: shown.length,
                    itemBuilder: (_, i) => _PlaylistCard(shown[i], highlight: searching ? searchQuery : null),
                  ),
      ),
      XpStatusBar([searching ? '${shown.length} de ${app.playlists.length} playlists' : '${app.playlists.length} playlists']),
    ]);
  }
}

class _PlaylistCard extends StatelessWidget {
  final Playlist pl;
  final String? highlight;
  const _PlaylistCard(this.pl, {this.highlight});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return FutureBuilder<List<Track>>(
      future: app.db.playlistTracks(pl.id),
      builder: (context, snap) {
        final ts = snap.data ?? const [];
        // capas de álbuns diferentes no mosaico (repete se a playlist tiver menos de 4)
        final seen = <String>{};
        final covers = [for (final t in ts) if (seen.add('${t.artist}|${t.album}')) t].take(4).toList();
        return InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: pl))),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFB8C4D8)), boxShadow: const [BoxShadow(color: Color(0xFFD6DBE5), offset: Offset(1, 1))]),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [
                    for (var i = 0; i < 4; i++)
                      covers.isEmpty ? Container(color: colorFor('${pl.name}$i')) : LayoutBuilder(builder: (_, c) => CoverSquare(covers[i % covers.length], size: c.maxWidth)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: Text.rich(
                  highlightSpan(pl.name, highlight, const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text('${pl.trackCount} faixas · ${fmtTotal(ts)}', style: const TextStyle(fontSize: 11, color: Xp.blueMuted)),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;
  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> with InListSearch {
  List<Track> _tracks = const [];
  late String _name = widget.playlist.name;
  InListIndex? _index;

  /// Sugestões do fim da lista (já na ordem), mostradas de 6 em 6.
  List<PlaylistSuggestion> _sugs = const [];
  int _sugPage = 0;
  List<Play>? _plays;
  static const _sugCount = 6;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final ts = await app.db.playlistTracks(widget.playlist.id);
    if (mounted) {
      setState(() {
        _tracks = ts;
        _index = null;
      });
    }
    _plays ??= await app.db.plays(); // histórico lido uma vez por tela (só para baixar as puladas)
    if (mounted) _suggest();
  }

  /// Recalcula as sugestões (conta rápida em memória, sem internet).
  void _suggest() {
    final app = context.read<AppState>();
    setState(() => _sugs = Recommender.forPlaylist(_tracks, app.tracks, playlistName: _name, plays: _plays ?? const []));
  }

  List<PlaylistSuggestion> get _sugShown {
    if (_sugs.isEmpty) return const [];
    final pages = (_sugs.length + _sugCount - 1) ~/ _sugCount;
    final start = (_sugPage % pages) * _sugCount;
    return _sugs.skip(start).take(_sugCount).toList();
  }

  Future<void> _addSuggestion(Track t) async {
    final app = context.read<AppState>();
    await app.addSuggestionToPlaylist(widget.playlist.id, t);
    await _load(); // a música entra no fim da playlist e outra sugestão ocupa o lugar dela
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    await app.db.setPlaylistOrder(widget.playlist.id, [for (final t in _tracks) t.id!]);
    await app.reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final ps = context.read<PlayerService>();
    void play(int i) {
      ps.playQueue(_tracks, start: i);
      HomeShell.goTo(context, 0);
    }

    final shown = searching ? (_index ??= InListIndex(_tracks)).filter(_tracks, searchQuery) : _tracks;
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: _name, icon: XpIcons.cassette, actions: [
              XpTitleButton(
                icon: Icons.edit,
                tooltip: 'Renomear',
                onTap: () async {
                  final n = await askText(context, 'Renomear playlist', 'Nome', initial: _name);
                  if (n == null || n.isEmpty) return;
                  await app.db.renamePlaylist(widget.playlist.id, n);
                  await app.reload();
                  setState(() => _name = n);
                  _suggest(); // nome de clima ("Triste") muda a regra
                },
              ),
              XpTitleButton(
                icon: Icons.delete_outline,
                tooltip: 'Apagar playlist',
                onTap: () async {
                  final nav = Navigator.of(context);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => XpAlertDialog(
                      icon: XpIcons.warning,
                      title: const Text('Apagar playlist?'),
                      content: const Text('As músicas continuam na biblioteca.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  await app.db.deletePlaylist(widget.playlist.id);
                  await app.reload();
                  nav.pop();
                },
              ),
              searchButton(),
              XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
            ]),
            XpAddressBar(searchPath('Playlists\\$_name')),
            searchBox('Pesquisar em "$_name"…'),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                XpButton(label: 'Tocar playlist', xpIcon: XpIcons.play, primary: true, onTap: _tracks.isEmpty ? null : () => play(0)),
                const SizedBox(height: 5),
                QueueButtons(_tracks),
              ]),
            ),
            Expanded(
              child: ColoredBox(color: Colors.white, child: _tracks.isEmpty
                  ? const EmptyHint(Icons.playlist_add, 'Playlist vazia.\nSegure uma música em qualquer lista para adicionar.')
                  : searching
                  // enquanto busca: só a lista filtrada (arrastar e apagar voltam ao fechar a busca)
                  ? (shown.isEmpty
                      ? noMatches()
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (_, i) => TrackTile(
                            track: shown[i],
                            highlight: searchQuery,
                            subtitle: '${shown[i].artist} · ${fmtDuration(Duration(milliseconds: shown[i].durationMs))}',
                            onTap: () => play(_tracks.indexOf(shown[i])),
                          ),
                        ))
                  : ReorderableListView.builder(
                      itemCount: _tracks.length,
                      footer: _sugShown.isEmpty
                          ? null
                          : _SuggestionsBlock(
                              suggestions: _sugShown,
                              hasMore: _sugs.length > _sugCount,
                              onAdd: _addSuggestion,
                              onPlay: (i) {
                                ps.playQueue([_sugShown[i].track]); // toca ela e depois o mix segue normal
                                HomeShell.goTo(context, 0);
                              },
                              onPlayAll: () {
                                ps.playQueue([for (final r in _sugShown) r.track]);
                                HomeShell.goTo(context, 0);
                              },
                              onMore: () => setState(() => _sugPage++),
                            ),
                      onReorderItem: (a, b) {
                        setState(() {
                          final list = [..._tracks];
                          list.insert(b, list.removeAt(a));
                          _tracks = list;
                        });
                        _save();
                      },
                      itemBuilder: (_, i) => Dismissible(
                        key: ValueKey('${_tracks[i].id}-$i'),
                        direction: DismissDirection.endToStart,
                        background: Container(color: Xp.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16), child: const Icon(Icons.delete, color: Colors.white)),
                        onDismissed: (_) {
                          setState(() => _tracks = [..._tracks]..removeAt(i));
                          _save();
                          _suggest(); // a que saiu pode voltar a ser sugerida
                        },
                        child: TrackTile(
                          track: _tracks[i],
                          subtitle: '${_tracks[i].artist} · ${fmtDuration(Duration(milliseconds: _tracks[i].durationMs))}',
                          onTap: () => play(i),
                          trailing: ReorderableDragStartListener(index: i, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle))),
                        ),
                      ),
                    )),
            ),
            XpStatusBar([
              searching
                  ? '${shown.length} de ${_tracks.length} faixas'
                  : '${_tracks.length} faixas${_sugShown.isEmpty ? '' : ' · ${_sugShown.length} sugestões'}',
              fmtTotal(searching ? shown : _tracks),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Fim da playlist: "Combina com esta playlist", músicas da biblioteca com o mesmo gênero e clima.
class _SuggestionsBlock extends StatelessWidget {
  final List<PlaylistSuggestion> suggestions;
  final bool hasMore;
  final void Function(Track) onAdd;
  final void Function(int) onPlay;
  final VoidCallback onPlayAll, onMore;
  const _SuggestionsBlock(
      {required this.suggestions, required this.hasMore, required this.onAdd, required this.onPlay, required this.onPlayAll, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFDBE6FB), Color(0xFFC4D5F5)]),
          border: Border(top: BorderSide(color: Color(0xFF6F95DD), width: 2)),
        ),
        child: const Row(children: [
          Text('✨ Combina com esta playlist', style: TextStyle(color: Color(0xFF0B2F80), fontWeight: FontWeight.bold, fontSize: 13)),
          Spacer(),
          Text('da sua biblioteca', style: TextStyle(color: Color(0xFF334455), fontSize: 11)),
        ]),
      ),
      for (var i = 0; i < suggestions.length; i++)
        TrackTile(
          key: ValueKey('sug-${suggestions[i].track.id}'),
          track: suggestions[i].track,
          subtitle: suggestions[i].track.artist,
          onTap: () => onPlay(i),
          below: _SuggestionChips(suggestions[i]),
          trailing: _AddButton(onTap: () => onAdd(suggestions[i].track)),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Row(children: [
          if (hasMore) ...[
            Expanded(child: XpButton(label: 'Outras sugestões', icon: Icons.refresh, onTap: onMore)),
            const SizedBox(width: 6),
          ],
          Expanded(child: XpButton(label: 'Tocar sugestões', xpIcon: XpIcons.play, onTap: onPlayAll)),
        ]),
      ),
    ]);
  }
}

/// Etiquetas do porquê: gênero (azul) e clima (verde).
class _SuggestionChips extends StatelessWidget {
  final PlaylistSuggestion s;
  const _SuggestionChips(this.s);

  Widget _chip(String text, Color bg, Color fg, Color border) => Container(
        margin: const EdgeInsets.only(right: 4, top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: border)),
        child: Text(text, style: TextStyle(color: fg, fontSize: 10.5), maxLines: 1, overflow: TextOverflow.ellipsis),
      );

  @override
  Widget build(BuildContext context) {
    final Mood? m = s.mood;
    return Wrap(children: [
      if (s.genre != null) _chip(s.genre!, const Color(0xFFE4ECFB), const Color(0xFF1C3F8A), const Color(0xFFB9CBEE)),
      if (m != null) _chip('${m.emoji} ${m.label}', const Color(0xFFEEF3E0), const Color(0xFF3D5A12), const Color(0xFFC8D9A6)),
    ]);
  }
}

/// Botão redondo prateado com "+" azul-marinho: põe a sugestão no fim da playlist.
class _AddButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Adicionar à playlist',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.all(6),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF6B7486)),
              gradient: const RadialGradient(center: Alignment(-.3, -.4), colors: [Colors.white, Color(0xFFC9CCD3), Color(0xFF9EA4AE)], stops: [0, .6, 1]),
            ),
            child: const Icon(Icons.add, color: Xp.navy, size: 20),
          ),
        ),
      );
}
