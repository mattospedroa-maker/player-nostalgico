import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Column(children: [
      const XpTitleBar(title: 'Playlists'),
      Padding(
        padding: const EdgeInsets.all(12),
        child: XpButton(
          label: 'Nova playlist',
          icon: Icons.add,
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
                padding: const EdgeInsets.symmetric(horizontal: 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .95),
                itemCount: app.playlists.length,
                itemBuilder: (_, i) => _PlaylistCard(app.playlists[i]),
              ),
      ),
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
        final colors = [for (final t in ts.take(4)) colorFor('${t.artist}|${t.album}')];
        while (colors.length < 4) {
          colors.add(colorFor('${pl.name}${colors.length}'));
        }
        return InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: pl))),
          child: Container(
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFF9FB2D4)), borderRadius: BorderRadius.circular(4)),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [for (final c in colors) Container(color: c)],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                child: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy)),
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
      Navigator.popUntil(context, (r) => r.isFirst);
      HomeShell.goTo(context, 0);
    }

    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: _name, actions: [
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
                    builder: (ctx) => AlertDialog(
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
            Padding(
              padding: const EdgeInsets.all(10),
              child: XpButton(label: 'Tocar playlist', icon: Icons.play_arrow, primary: true, onTap: _tracks.isEmpty ? null : () => play(0)),
            ),
            Expanded(
              child: _tracks.isEmpty
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
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
