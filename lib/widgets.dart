import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/edit_track_screen.dart';
import 'models.dart';
import 'theme.dart';

String fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String fmtTotal(Iterable<Track> ts) {
  final ms = ts.fold<int>(0, (a, t) => a + t.durationMs);
  final d = Duration(milliseconds: ms);
  return d.inHours > 0 ? '${d.inHours}h${(d.inMinutes % 60).toString().padLeft(2, '0')}' : '${d.inMinutes} min';
}

class CoverSquare extends StatelessWidget {
  final Track track;
  final double size;
  const CoverSquare(this.track, {super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final c = colorFor('${track.artist}|${track.album}');
    final cover = context.read<AppState>().covers.fileFor(track);
    if (cover != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(border: Border.all(color: const Color(0xFF888899))),
        child: Image.file(cover, fit: BoxFit.cover, cacheWidth: (size * 3).round(), errorBuilder: (_, _, _) => const SizedBox()),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF888899)),
        gradient: LinearGradient(colors: [c, Color.lerp(c, Colors.black, .45)!]),
      ),
      child: Icon(Icons.music_note, color: Colors.white54, size: size * .5),
    );
  }
}

/// Linha de música com capa, título, artista e coração.
class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  final String? subtitle;
  final String? note;
  final Widget? trailing;
  const TrackTile({super.key, required this.track, required this.onTap, this.subtitle, this.note, this.trailing});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final playing = context.select<AppState, int?>((s) => s.player.current?.id) == track.id;
    return Material(
      color: playing ? const Color(0xFFE6EEFC) : Colors.white,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showTrackMenu(context, track),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Xp.listBorder))),
          child: Row(children: [
            CoverSquare(track),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 14)),
                Text(subtitle ?? track.artist,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Xp.blueMuted, fontSize: 12)),
                if (note != null) Text(note!, style: const TextStyle(color: Xp.navy, fontSize: 11)),
              ]),
            ),
            trailing ??
                IconButton(
                  icon: Icon(track.favorite ? Icons.favorite : Icons.favorite_border, color: Xp.gold),
                  onPressed: () => app.toggleFavorite(track),
                ),
          ]),
        ),
      ),
    );
  }
}

Future<void> showTrackMenu(BuildContext context, Track t) async {
  final app = context.read<AppState>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Xp.beige,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(t.title, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('${t.artist} · ${t.album}')),
        ListTile(
          leading: Icon(t.favorite ? Icons.favorite : Icons.favorite_border, color: Xp.red),
          title: Text(t.favorite ? 'Tirar das favoritas' : 'Adicionar às favoritas'),
          onTap: () {
            Navigator.pop(ctx);
            app.toggleFavorite(t);
          },
        ),
        ListTile(
          leading: const Icon(Icons.playlist_add, color: Xp.navy),
          title: const Text('Adicionar a uma playlist'),
          onTap: () {
            Navigator.pop(ctx);
            pickPlaylistAndAdd(context, t);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined, color: Xp.navy),
          title: const Text('Editar informações'),
          onTap: () {
            Navigator.pop(ctx);
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditTrackScreen(track: t)));
          },
        ),
      ]),
    ),
  );
}

Future<void> pickPlaylistAndAdd(BuildContext context, Track t) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Adicionar a…'),
      children: [
        for (final pl in app.playlists) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, pl.id), child: Text(pl.name)),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, -1),
          child: const Text('＋ Nova playlist', style: TextStyle(color: Xp.blue, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  var id = choice;
  if (choice == -1) {
    final name = await askText(context, 'Nova playlist', 'Nome');
    if (name == null || name.isEmpty) return;
    id = await app.db.createPlaylist(name);
  }
  await app.addToPlaylist(id, t);
  messenger.showSnackBar(SnackBar(content: Text('"${t.title}" adicionada')));
}

Future<String?> askText(BuildContext context, String title, String label, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

/// Card grande com degradê e botão de play (Favoritas / Para você).
class HeroCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Color> colors;
  final VoidCallback? onPlay;
  const HeroCard({super.key, required this.title, required this.subtitle, required this.colors, this.onPlay});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors),
          border: Border.all(color: const Color(0xFF0B2F7A), width: 2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ]),
          ),
          GlossyButton(icon: Icons.play_arrow, size: 44, onTap: onPlay),
        ]),
      );
}

class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyHint(this.icon, this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(children: [
          Icon(icon, size: 48, color: Xp.blueMuted),
          const SizedBox(height: 10),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Xp.blueText)),
        ]),
      );
}
