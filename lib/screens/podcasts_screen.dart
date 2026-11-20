import 'dart:io';
import 'dart:isolate';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart' show HomeShell;
import '../models.dart';
import '../organizer.dart' show MoveRecord;
import '../player_service.dart';
import '../podcasts.dart';
import '../skip_notice.dart' show appMessengerKey, appNavigatorKey;
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';
import 'youtube_screen.dart';

// ---------------------------------------------------------------------------
// Seletor de mídia (opção C): lista grande com ícone, contagem e espaço ocupado.

/// Abre a lista de tipos de mídia logo abaixo do campo Endereço ([anchor] = contexto do campo).
Future<void> showMediaPicker(BuildContext anchor) {
  final app = anchor.read<AppState>();
  final box = anchor.findRenderObject() as RenderBox?;
  final top = box == null ? 120.0 : box.localToGlobal(Offset(0, box.size.height)).dy;
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Fechar lista',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 90),
    pageBuilder: (ctx, _, _) => Stack(children: [
      Positioned(
        left: 8,
        right: 8,
        top: top,
        child: Material(
          color: Colors.white,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border.fromBorderSide(BorderSide(color: Colors.black)),
              boxShadow: [BoxShadow(color: Color(0x59000000), offset: Offset(3, 3), blurRadius: 4)],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.white, Color(0xFFC6D3F7)])),
                child: const Text('Tipos de mídia', style: TextStyle(color: Xp.linkBlue, fontWeight: FontWeight.bold, fontSize: 13.5)),
              ),
              for (final kind in MediaKind.values) _MediaRow(kind: kind, app: app, onPick: () {
                Navigator.pop(ctx);
                app.setLibraryMedia(kind);
              }),
            ]),
          ),
        ),
      ),
    ]),
  );
}

class _MediaRow extends StatelessWidget {
  final MediaKind kind;
  final AppState app;
  final VoidCallback onPick;
  const _MediaRow({required this.kind, required this.app, required this.onPick});

  static XpIcons iconOf(MediaKind k) => switch (k) { MediaKind.music => XpIcons.note, MediaKind.podcasts => XpIcons.mic, MediaKind.audiobooks => XpIcons.book };

  @override
  Widget build(BuildContext context) {
    final selected = app.libraryMedia == kind;
    final enabled = kind.available;
    final items = switch (kind) { MediaKind.music => app.tracks, MediaKind.podcasts => app.podcasts, MediaKind.audiobooks => const <Track>[] };
    final fg = selected ? Colors.white : (enabled ? Colors.black : const Color(0xFF999999));
    final sub = selected ? const Color(0xFFDFE8FF) : (enabled ? const Color(0xFF555555) : const Color(0xFFAAAAAA));
    String count() => switch (kind) {
          MediaKind.music => '${items.length} ${items.length == 1 ? 'música' : 'músicas'}',
          MediaKind.podcasts => [
              '${items.length} ${items.length == 1 ? 'episódio' : 'episódios'}',
              if (items.isNotEmpty) '${items.where((t) => !app.podcastProgress.listened(t.path)).length} não ouvidos',
            ].join(' · '),
          MediaKind.audiobooks => 'em espera (ainda não existe)',
        };
    return InkWell(
      onTap: enabled ? onPick : null,
      child: Container(
        color: selected ? Xp.select : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(children: [
          Opacity(opacity: enabled ? 1 : .45, child: XpIcon(iconOf(kind), size: 34)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(kind.label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, color: fg)),
              if (!enabled)
                Text(count(), style: TextStyle(fontSize: 12, color: sub))
              else
                FutureBuilder<int>(
                  future: _sizeOf(items),
                  builder: (_, snap) => Text(
                    [count(), if (snap.hasData && items.isNotEmpty) formatBytes(snap.data!)].join(' · '),
                    style: TextStyle(fontSize: 12, color: sub),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Espaço ocupado (lido fora da linha da tela: bibliotecas grandes têm milhares de arquivos).
  static Future<int> _sizeOf(List<Track> items) {
    final paths = [for (final t in items) t.path];
    return Isolate.run(() {
      var total = 0;
      for (final path in paths) {
        try {
          total += File(path).lengthSync();
        } catch (_) {
          // arquivo sumiu: não conta
        }
      }
      return total;
    });
  }
}

/// "6,1 GB", "830 MB".
String formatBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1).replaceAll('.', ',')} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).round()} MB';
  return '${(b / 1024).round()} KB';
}

// ---------------------------------------------------------------------------
// Início dos podcasts (dentro da Biblioteca, quando o Endereço está em "Podcasts")

class PodcastsHome extends StatelessWidget {
  final String query;
  const PodcastsHome({super.key, this.query = ''});

  void _push(BuildContext context, Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    context.select<PlayerService, int?>((p) => p.current?.id); // "onde parou" muda quando o episódio troca
    final eps = app.podcasts;
    final resume = app.podcastProgress.lastInProgress(eps);
    if (query.isNotEmpty) {
      final found = searchEpisodes(eps, query, extra: (e) => app.podcastInfo.infoFor(e.path)?.searchText ?? '');
      return ListView(padding: EdgeInsets.zero, children: [
        if (found.isEmpty) const EmptyHint(Icons.search_off, 'Nenhum episódio com esse nome, participante ou tema.'),
        for (final e in found) EpisodeTile(episode: e, following: const []),
      ]);
    }
    final programs = groupPrograms(eps);
    return ListView(padding: EdgeInsets.zero, children: [
      XpTaskPane(title: 'Tarefas de podcast', tasks: [
        if (resume != null) (XpIcons.play, 'Continuar de onde parei', () => playEpisode(context, resume)),
        (XpIcons.youtube, 'Baixar podcast do YouTube', () => _push(context, const YoutubeScreen())),
        (XpIcons.find, 'Procurar podcasts no meio das músicas', () => _push(context, const PodcastReviewScreen())),
      ]),
      if (resume != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Text('Parou em ${formatClock(app.podcastProgress.resumeAt(resume.path)!)} de "${resume.title}"',
              maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Xp.blueText)),
        ),
      if (programs.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Nenhum podcast ainda.\n\nBaixe pelo "Baixar do YouTube" marcando "Podcast", ou coloque os arquivos na pasta Podcasts/Nome do programa/ dentro da sua pasta de músicas.',
            style: TextStyle(color: Xp.blueText, fontSize: 13.5),
          ),
        )
      else
        IpodBox(title: 'Programas', trailing: 'Episódios', children: [
          for (final pr in programs)
            IpodRow(
              icon: XpIcons.radio,
              label: pr.name,
              detail: '${pr.episodes.length}',
              onTap: () => _push(context, PodcastProgramScreen(program: pr.name)),
            ),
        ]),
      const SizedBox(height: 12),
    ]);
  }
}

/// Toca um episódio escolhido na área de Podcasts: depois dele vêm os próximos não ouvidos da lista.
Future<void> playEpisode(BuildContext context, Track ep, {List<Track> following = const []}) async {
  final app = context.read<AppState>();
  final next = [for (final t in following) if (t.id != ep.id && !app.podcastProgress.listened(t.path)) t];
  await context.read<PlayerService>().playPodcast(ep, following: next);
  if (context.mounted) HomeShell.goTo(context, 0);
}

/// Episódios de um programa.
class PodcastProgramScreen extends StatelessWidget {
  final String program;
  const PodcastProgramScreen({super.key, required this.program});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final eps = [for (final t in app.podcasts) if (t.artist == program) t]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return Scaffold(
      backgroundColor: Xp.beige,
      body: SafeArea(
        child: Column(children: [
          XpTitleBar(title: program, icon: XpIcons.radio, actions: [
            XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
          ]),
          XpAddressBar('Podcasts\\$program', icon: XpIcons.mic),
          Expanded(
            child: ColoredBox(
              color: Colors.white,
              child: eps.isEmpty
                  ? const EmptyHint(Icons.mic_off, 'Nenhum episódio neste programa.')
                  : ListView(padding: EdgeInsets.zero, children: [
                      for (var i = 0; i < eps.length; i++) EpisodeTile(episode: eps[i], following: eps.sublist(i + 1)),
                    ]),
            ),
          ),
          XpStatusBar(['${eps.length} ${eps.length == 1 ? 'episódio' : 'episódios'}', 'Podcasts']),
        ]),
      ),
    );
  }
}

/// Linha de episódio: título, duração e onde parou ("novo", "parou em 1:02:10", "ouvido ✓").
class EpisodeTile extends StatelessWidget {
  final Track episode;

  /// Episódios que tocam depois dele quando tocado daqui.
  final List<Track> following;
  const EpisodeTile({super.key, required this.episode, required this.following});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final ps = context.read<PlayerService>();
    final playing = context.select<PlayerService, int?>((p) => p.current?.id) == episode.id;
    final prog = app.podcastProgress;
    final at = prog.resumeAt(episode.path);
    final status = prog.listened(episode.path) ? 'ouvido ✓' : (at != null ? 'parou em ${formatClock(at)}' : 'novo');
    final dur = episode.durationMs > 0 ? formatDuration(Duration(milliseconds: episode.durationMs)) : '';
    final fg = playing ? Colors.white : Colors.black;
    final sub = playing ? const Color(0xFFDFE8FF) : const Color(0xFF666666);
    return Material(
      color: playing ? Xp.select : Colors.white,
      child: GestureDetector(
        onLongPressStart: (d) => showXpContextMenu(context, header: episode.title, at: d.globalPosition, items: [
          XpMenuEntry('Tocar (depois vem o próximo episódio)', () => playEpisode(context, episode, following: following), icon: XpIcons.play),
          if (ps.current != null && !ps.podcastMode && !ps.currentIsPodcast)
            XpMenuEntry('Ouvir no meio das músicas', () async {
              await ps.playPodcastBetweenSongs(episode);
              if (context.mounted) HomeShell.goTo(context, 0);
            }, icon: XpIcons.note),
          null,
          prog.listened(episode.path)
              ? XpMenuEntry('Marcar como não ouvido', () {
                  prog.setListened(episode.path, false);
                  app.touch();
                }, icon: XpIcons.refresh)
              : XpMenuEntry('Marcar como ouvido', () {
                  prog.setListened(episode.path, true);
                  app.touch();
                }, icon: XpIcons.check),
        ]),
        child: InkWell(
          onTap: () => playEpisode(context, episode, following: following),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
            child: Row(children: [
              const XpIcon(XpIcons.mic, size: 30),
              const SizedBox(width: 9),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(episode.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontSize: 14.5)),
                  Text([episode.artist, if (dur.isNotEmpty) dur, status].join(' · '),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: sub, fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sugestão de mover arquivos antigos (opção 1: balão perto do relógio → tela de revisão)

/// Balão amarelo perto do relógio: "Encontrei N possíveis podcasts". Nunca move nada sozinho.
void showPodcastSuggestionBalloon(List<PodcastCandidate> fresh) {
  final m = appMessengerKey.currentState;
  if (m == null || fresh.isEmpty) return;
  final n = fresh.length;
  m.showSnackBar(SnackBar(
    duration: const Duration(seconds: 10),
    action: SnackBarAction(
      label: 'Revisar',
      onPressed: () => appNavigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => const PodcastReviewScreen())),
    ),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const XpIcon(XpIcons.mic, size: 18),
        const SizedBox(width: 6),
        Expanded(child: Text('Encontrei $n ${n == 1 ? 'possível podcast' : 'possíveis podcasts'}', style: const TextStyle(fontWeight: FontWeight.bold))),
      ]),
      const SizedBox(height: 4),
      Text('${n == 1 ? 'Está' : 'Estão'} no meio das músicas. Toque em "Revisar" para escolher o que vai para a pasta Podcasts.',
          style: const TextStyle(fontSize: 13.5)),
    ]),
  ));
}

/// "Possíveis podcasts": caixinhas com o motivo de cada suspeita. Desmarcado + Mover = "não é podcast" (não pergunta de novo).
class PodcastReviewScreen extends StatefulWidget {
  const PodcastReviewScreen({super.key});

  @override
  State<PodcastReviewScreen> createState() => _PodcastReviewScreenState();
}

class _PodcastReviewScreenState extends State<PodcastReviewScreen> {
  late final List<PodcastCandidate> _items = context.read<AppState>().podcastCandidates();
  late final Map<String, bool> _checked = {for (final c in _items) c.track.path: c.strong};
  late final Map<String, String> _program = {for (final c in _items) c.track.path: c.program};
  bool _busy = false;

  int get _count => _checked.values.where((v) => v).length;

  Future<void> _move() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final chosen = {for (final c in _items) if (_checked[c.track.path]!) c.track: _program[c.track.path]!};
    final no = [for (final c in _items) if (!_checked[c.track.path]!) c.track];
    final List<MoveRecord> done = await app.moveToPodcasts(chosen, notPodcast: no);
    if (!mounted) return;
    Navigator.pop(context);
    if (done.isEmpty) return;
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('${done.length} ${done.length == 1 ? 'arquivo movido' : 'arquivos movidos'} para Podcasts.'),
      action: SnackBarAction(label: 'Desfazer', onPressed: () => app.undoMoveToPodcasts(done)),
    ));
  }

  Future<void> _editProgram(PodcastCandidate c) async {
    final ctl = TextEditingController(text: _program[c.track.path]);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => XpAlertDialog(
        icon: XpIcons.radio,
        title: const Text('Nome do programa'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'Programa (normalmente o canal)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
    ctl.dispose();
    if (v != null && v.isNotEmpty) setState(() => _program[c.track.path] = v);
  }

  @override
  Widget build(BuildContext context) {
    final root = context.read<AppState>().sourceRoot ?? '';
    return Scaffold(
      backgroundColor: Xp.beige,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          XpTitleBar(title: 'Possíveis podcasts', icon: XpIcons.mic, actions: [
            XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
          ]),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              _items.isEmpty
                  ? 'Não achei nada com cara de podcast no meio das músicas.'
                  : 'Marque os que devem ir para Podcasts\\Programa\\. Toque no nome do programa para corrigir. Os desmarcados ficam como música e não são sugeridos de novo.',
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? const SizedBox.shrink()
                : Container(
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    child: Bevel(
                      sunken: true,
                      child: ListView(padding: EdgeInsets.zero, children: [
                        for (final c in _items) _row(c, root),
                      ]),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              XpButton(label: 'Agora não', onTap: _busy ? null : () => Navigator.pop(context)),
              const SizedBox(width: 6),
              XpButton(label: _busy ? 'Movendo…' : 'Mover $_count', primary: true, onTap: _busy || _items.isEmpty ? null : _move),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _row(PodcastCandidate c, String root) {
    final on = _checked[c.track.path]!;
    final program = _program[c.track.path]!;
    final rel = root.isEmpty ? c.track.path : p.relative(c.track.path, from: root);
    return InkWell(
      onTap: () => setState(() => _checked[c.track.path] = !on),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Color(0xFFE4E8EF)))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.only(top: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFF1C5180))),
            child: on ? const Icon(Icons.check, size: 14, color: Color(0xFF21A121)) : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.track.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
              Text(c.reason, style: const TextStyle(fontSize: 11.5, color: Color(0xFF666666))),
              Text(rel.replaceAll(p.separator, '\\'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
              if (on)
                GestureDetector(
                  onTap: () => _editProgram(c),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('→ Podcasts\\$program\\', style: const TextStyle(fontSize: 12, color: Xp.linkBlue, decoration: TextDecoration.underline)),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
