import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'main.dart';
import 'player_service.dart';
import 'screens/edit_track_screen.dart';
import 'screens/now_playing_screen.dart' show showGifManager;
import 'xp_icons.dart';
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
      child: GestureDetector(
        onLongPressStart: (d) => showTrackMenu(context, track, at: d.globalPosition),
        child: InkWell(
        onTap: onTap,
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
      )),
    );
  }
}

/// Item do menu de contexto (null = separador).
class XpMenuEntry {
  final XpIcons? icon;
  final String label;
  final VoidCallback? onTap;
  final bool submenu;
  const XpMenuEntry(this.label, this.onTap, {this.icon, this.submenu = false});
}

/// Menu de contexto do XP (branco, ícones à esquerda), aberto onde o dedo segurou.
Future<void> showXpContextMenu(BuildContext context, {required String header, required List<XpMenuEntry?> items, Offset? at}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fechar menu',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 90),
    pageBuilder: (ctx, _, _) {
      final size = MediaQuery.sizeOf(ctx);
      const w = 280.0;
      final h = 46.0 + items.fold<double>(0, (a, e) => a + (e == null ? 7 : 42));
      final p = at ?? Offset(size.width / 2 - w / 2, size.height / 3);
      final left = p.dx.clamp(8.0, size.width - w - 8);
      final top = p.dy.clamp(30.0, (size.height - h - 70).clamp(30.0, double.infinity));
      return Stack(children: [
        Positioned(
          left: left,
          top: top,
          width: w,
          child: Material(
            color: Colors.white,
            elevation: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border.fromBorderSide(BorderSide(color: Color(0xFFACA899))),
                boxShadow: [BoxShadow(color: Color(0x59000000), offset: Offset(3, 3), blurRadius: 3)],
              ),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(42, 8, 10, 8),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8)))),
                  child: Text(header, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                for (final e in items)
                  if (e == null)
                    Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 2), color: const Color(0xFFD4D0C8))
                  else
                    InkWell(
                      onTap: e.onTap == null
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              e.onTap!();
                            },
                      hoverColor: Xp.select,
                      highlightColor: Xp.select,
                      child: SizedBox(
                        height: 42,
                        child: Row(children: [
                          SizedBox(width: 42, child: e.icon == null ? null : Center(child: XpIcon(e.icon!, size: 20))),
                          Expanded(child: Text(e.label, style: TextStyle(fontSize: 14.5, color: e.onTap == null ? Colors.black38 : Colors.black))),
                          if (e.submenu) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.arrow_right, size: 22, color: Colors.black)),
                        ]),
                      ),
                    ),
              ]),
            ),
          ),
        ),
      ]);
    },
  );
}

Future<void> showTrackMenu(BuildContext context, Track t, {Offset? at}) {
  final app = context.read<AppState>();
  final fav = (app.byId(t.id) ?? t).favorite;
  return showXpContextMenu(context, header: '${t.title} — ${t.artist}', at: at, items: [
    XpMenuEntry('Tocar agora', () => playTracks(context, [t]), icon: XpIcons.play),
    null,
    XpMenuEntry(fav ? 'Tirar das favoritas' : 'Adicionar às favoritas', () => app.toggleFavorite(t), icon: XpIcons.heart),
    XpMenuEntry('Adicionar a uma playlist', () => pickPlaylistAndAdd(context, t), icon: XpIcons.plus, submenu: true),
    XpMenuEntry('GIFs desta música', () => showGifManager(context, t), icon: XpIcons.film),
    null,
    XpMenuEntry('Propriedades…', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditTrackScreen(track: t))), icon: XpIcons.doc),
  ]);
}

Future<void> pickPlaylistAndAdd(BuildContext context, Track t) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  Widget row(BuildContext ctx, XpIcons icon, String label, int value, {bool bold = false}) => InkWell(
        onTap: () => Navigator.pop(ctx, value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
          child: Row(children: [
            XpIcon(icon, size: 22),
            const SizedBox(width: 9),
            Expanded(child: Text(label, style: TextStyle(fontSize: 15, fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
          ]),
        ),
      );
  final choice = await showDialog<int>(
    context: context,
    builder: (ctx) => XpAlertDialog(
      title: const Text('Adicionar a uma playlist'),
      icon: XpIcons.plus,
      content: Bevel(
        sunken: true,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final pl in app.playlists) row(ctx, XpIcons.cassette, pl.name, pl.id),
          row(ctx, XpIcons.plus, 'Nova playlist…', -1, bold: true),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar'))],
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
    builder: (ctx) => XpAlertDialog(
      icon: XpIcons.edit,
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
    builder: (ctx) => XpAlertDialog(
      icon: XpIcons.film,
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
