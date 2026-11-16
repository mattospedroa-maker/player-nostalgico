import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'main.dart';
import 'player_service.dart';
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
    final fg = playing ? Colors.white : Colors.black;
    final sub = playing ? const Color(0xFFDFE8FF) : const Color(0xFF666666);
    return Material(
      color: playing ? Xp.select : Colors.white,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showTrackMenu(context, track),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0))),
          ),
          child: Row(
            children: [
              CoverSquare(track, size: 38),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontSize: 14.5),
                    ),
                    Text(
                      subtitle ?? track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: sub, fontSize: 12),
                    ),
                    if (note != null) Text(note!, style: TextStyle(color: playing ? Colors.white : Xp.linkBlue, fontSize: 11.5)),
                  ],
                ),
              ),
              trailing ??
                  IconButton(
                    icon: Icon(
                      track.favorite ? Icons.favorite : Icons.favorite_border,
                      color: track.favorite ? const Color(0xFFE0342A) : (playing ? Colors.white70 : Colors.black26),
                    ),
                    onPressed: () => app.toggleFavorite(track),
                  ),
            ],
          ),
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

/// Escolhe a pasta das músicas (pede a permissão antes).
Future<void> chooseMusicFolder(BuildContext context) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  if (!await app.ensureStoragePermission()) {
    messenger.showSnackBar(const SnackBar(content: Text('Sem permissão de acesso aos arquivos, não consigo ler as músicas.')));
    return;
  }
  final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Escolha a pasta das suas músicas');
  if (dir == null) return;
  await app.setSourceRoot(dir);
}

void showGifLibraryInfo(BuildContext context) {
  final app = context.read<AppState>();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Acervo de GIFs'),
      content: Text(
        '${app.gifs.count} GIFs em\n${app.gifs.gifRoot}\n\n'
        'Crie subpastas com o nome do artista, álbum ou gênero (ex.: GIFs/Hatsune Miku) e os GIFs aparecem nas músicas que combinam. '
        'GIFs soltos direto na pasta GIFs aparecem em qualquer música.',
      ),
      actions: [
        TextButton(
          onPressed: () {
            app.reload();
            Navigator.pop(ctx);
          },
          child: const Text('Recarregar'),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
}

/// Toca a lista (em ordem ou aleatória) e vai para o Tocando agora, sem fechar a tela atual:
/// ao voltar para a aba, você continua de onde parou.
Future<void> playTracks(BuildContext context, List<Track> list, {int start = 0, bool? shuffle}) async {
  if (list.isEmpty) return;
  final ps = context.read<PlayerService>();
  if (shuffle != null && ps.shuffle != shuffle) await ps.toggleShuffle();
  if (shuffle == true) start = Random().nextInt(list.length);
  await ps.playQueue(list, start: start);
  if (context.mounted) HomeShell.goTo(context, 0);
}
