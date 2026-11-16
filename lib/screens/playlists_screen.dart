import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Column(children: [
      const XpTitleBar(title: 'Playlists', icon: XpIcons.list),
      const XpAddressBar('Playlists'),
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
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .95),
                itemCount: app.playlists.length,
                itemBuilder: (_, i) => _PlaylistCard(app.playlists[i]),
              ),
      ),
      XpStatusBar(['${app.playlists.length} playlists']),
    ]);
  }
}

class _PlaylistCard extends StatelessWidget {
  final Playlist pl;
  const _PlaylistCard(this.pl);

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
                child: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  List<Track> _tracks = const [];
  late String _name = widget.playlist.name;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ts = await context.read<AppState>().db.playlistTracks(widget.playlist.id);
    if (mounted) setState(() => _tracks = ts);
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
              XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
            ]),
            XpAddressBar('Playlists\\$_name'),
            Padding(
              padding: const EdgeInsets.all(8),
              child: XpButton(label: 'Tocar playlist', xpIcon: XpIcons.play, primary: true, onTap: _tracks.isEmpty ? null : () => play(0)),
            ),
            Expanded(
              child: ColoredBox(color: Colors.white, child: _tracks.isEmpty
                  ? const EmptyHint(Icons.playlist_add, 'Playlist vazia.\nSegure uma música em qualquer lista para adicionar.')
                  : ReorderableListView.builder(
                      itemCount: _tracks.length,
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
            XpStatusBar(['${_tracks.length} faixas', fmtTotal(_tracks)]),
          ]),
        ),
      ),
    );
  }
}
