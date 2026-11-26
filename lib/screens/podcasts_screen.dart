import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../main.dart' show HomeShell;
import '../models.dart';
import '../organizer.dart' show MoveRecord;
import '../player_service.dart';
import '../podcast_themes.dart' show EpisodeTheme, PodcastThemesService;
import '../podcasts.dart';
import '../skip_notice.dart' show appMessengerKey, appNavigatorKey;
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';
import 'track_list_screen.dart' show GroupThumb, ThumbFrame;
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
    final items = switch (kind) { MediaKind.music => app.tracks, MediaKind.podcasts => app.podcasts, MediaKind.audiobooks => app.audiobooks };
    final fg = selected ? Colors.white : (enabled ? Colors.black : const Color(0xFF999999));
    final sub = selected ? const Color(0xFFDFE8FF) : (enabled ? const Color(0xFF555555) : const Color(0xFFAAAAAA));
    String count() => switch (kind) {
          MediaKind.music => '${items.length} ${items.length == 1 ? 'música' : 'músicas'}',
          MediaKind.podcasts => [
              '${items.length} ${items.length == 1 ? 'episódio' : 'episódios'}',
              if (items.isNotEmpty) '${items.where((t) => !app.podcastProgress.listened(t.path)).length} não ouvidos',
            ].join(' · '),
          MediaKind.audiobooks => [
              '${items.length} ${items.length == 1 ? 'livro' : 'livros'}',
              if (items.isNotEmpty) '${items.where((t) => !app.podcastProgress.listened(t.path)).length} não terminados',
            ].join(' · '),
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

  static const _viewKey = 'groupView_podcasts';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListenableBuilder(listenable: app.programArt, builder: (context, _) => _build(context, app));
  }

  Widget _build(BuildContext context, AppState app) {
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
        ..._programs(context, app, programs),
      const SizedBox(height: 12),
    ]);
  }

  List<Widget> _programs(BuildContext context, AppState app, List<PodcastProgram> programs) {
    for (final pr in programs) {
      app.ensureProgramArt(pr.episodes);
    }
    final grid = (app.prefs.getString(_viewKey) ?? 'grid') == 'grid';
    void open(PodcastProgram pr) => _push(context, PodcastProgramScreen(program: pr.name));
    int fresh(PodcastProgram pr) => pr.episodes.where((e) => !app.podcastProgress.listened(e.path)).length;
    Widget toggle(String label, String value, bool on) => GestureDetector(
      onTap: () async {
        await app.prefs.setString(_viewKey, value);
        app.touch();
      },
      child: Bevel(
        sunken: on,
        color: on ? const Color(0xFFE3E1D4) : Xp.beige,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(label, style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.bold : FontWeight.normal)),
      ),
    );
    return [
      Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: const BoxDecoration(
          color: Xp.beige,
          border: Border.symmetric(horizontal: BorderSide(color: Color(0xFFD4D0C8))),
        ),
        child: Row(children: [
          const Text('Exibir:', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          toggle('Miniaturas', 'grid', grid),
          const SizedBox(width: 4),
          toggle('Detalhes', 'list', !grid),
          const Spacer(),
          Text('${programs.length} ${programs.length == 1 ? 'programa' : 'programas'}', style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
        ]),
      ),
      if (grid)
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisExtent: 178),
          itemCount: programs.length,
          itemBuilder: (context, i) {
            final pr = programs[i];
            final n = pr.episodes.length;
            return GestureDetector(
              onTap: () => open(pr),
              onLongPressStart: (d) => showProgramMenu(context, pr, d.globalPosition),
              child: Column(children: [
                ThumbFrame(thumb: programThumb(app, pr), size: 104, name: pr.name, badge: 'PODCAST', count: fresh(pr), placeholderIcon: XpIcons.mic),
                const SizedBox(height: 4),
                Text(pr.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, height: 1.15)),
                Text('$n ${n == 1 ? 'episódio' : 'episódios'}', maxLines: 1, style: const TextStyle(fontSize: 11, color: Color(0xFF666666))),
              ]),
            );
          },
        )
      else ...[
        const XpColumnHeader('Programa', right: 'Novos / Total'),
        for (final pr in programs)
          InkWell(
            onTap: () => open(pr),
            onLongPress: () => showProgramMenu(context, pr, null),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
              child: Row(children: [
                ThumbFrame(thumb: programThumb(app, pr), size: 44, name: pr.name, padding: 2, placeholderIcon: XpIcons.mic),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(pr.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5)),
                    Text('Último: ${pr.episodes.first.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
                  ]),
                ),
                const SizedBox(width: 6),
                Text.rich(TextSpan(children: [
                  TextSpan(text: '${fresh(pr)}', style: TextStyle(fontWeight: FontWeight.bold, color: fresh(pr) > 0 ? Xp.red : const Color(0xFF666666))),
                  TextSpan(text: ' / ${pr.episodes.length}'),
                ]), style: const TextStyle(fontSize: 12.5, color: Xp.blueText)),
              ]),
            ),
          ),
      ],
    ];
  }
}

/// Miniatura do programa: imagem escolhida/ícone do canal > capa do episódio mais recente > microfone cinza.
GroupThumb programThumb(AppState app, PodcastProgram pr) {
  final color = colorFor(pr.name);
  final f = app.programArt.fileFor(AppState.programDirOf(pr.episodes.first));
  if (f != null) return GroupThumb(file: f, color: color);
  for (final e in pr.episodes) {
    final c = app.covers.fileFor(e);
    if (c != null) return GroupThumb(file: c, color: color);
  }
  return GroupThumb(color: color);
}

void _say(String text) => appMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));

/// Segurar um programa: trocar a imagem ou voltar ao ícone do canal.
Future<void> showProgramMenu(BuildContext context, PodcastProgram pr, Offset? at) {
  final app = context.read<AppState>();
  final dir = AppState.programDirOf(pr.episodes.first);
  final custom = File(p.join(dir, 'folder.png')).existsSync();
  String? anyId() {
    for (final e in pr.episodes) {
      final id = app.youtubeIdOf(e);
      if (id != null) return id;
    }
    return null;
  }

  return showXpContextMenu(context, header: pr.name, at: at, items: [
    XpMenuEntry('Trocar imagem…', () async {
      final res = await FilePicker.pickFiles(type: FileType.image);
      final path = res.map((f) => f.path).whereType<String>().firstOrNull;
      if (path == null) return;
      try {
        await app.programArt.setCustom(dir, path);
      } catch (e) {
        _say('Não deu para usar essa imagem.');
      }
    }, icon: XpIcons.folder),
    if (custom)
      XpMenuEntry('Voltar ao ícone do canal', () => app.programArt.resetCustom(dir, videoId: anyId()), icon: XpIcons.refresh)
    else
      XpMenuEntry('Baixar ícone do canal de novo', () async {
        final id = anyId();
        final ok = id != null && await app.programArt.ensure(dir, videoId: id, force: true);
        if (!ok) _say(id == null ? 'Esse programa não veio do YouTube pelo app.' : 'Não deu para baixar o ícone agora. Tente mais tarde.');
      }, icon: XpIcons.youtube),
  ]);
}

/// Toca um episódio escolhido na área de Podcasts: depois dele vêm os próximos não ouvidos da lista.
Future<void> playEpisode(BuildContext context, Track ep, {List<Track> following = const []}) async {
  final app = context.read<AppState>();
  final next = [for (final t in following) if (t.id != ep.id && !app.podcastProgress.listened(t.path)) t];
  await context.read<PlayerService>().playPodcast(ep, following: next);
  if (context.mounted) HomeShell.goTo(context, 0);
}

/// Episódios de um programa: imagem do programa no topo e os episódios separados por tema (ou todos).
class PodcastProgramScreen extends StatelessWidget {
  final String program;
  const PodcastProgramScreen({super.key, required this.program});

  static const _viewKey = 'programView';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListenableBuilder(
      listenable: Listenable.merge([app.programArt, app.podcastThemes]),
      builder: (context, _) => _build(context, app),
    );
  }

  Widget _build(BuildContext context, AppState app) {
    final eps = [for (final t in app.podcasts) if (t.artist == program) t]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final pr = PodcastProgram(program, eps);
    final dir = eps.isEmpty ? '' : AppState.programDirOf(eps.first);
    final prog = app.podcastProgress;
    final fresh = eps.where((e) => !prog.listened(e.path)).toList();
    if (eps.isNotEmpty) {
      unawaited(app.podcastThemes.ensure(dir, program, eps, app.podcastInfo.infoFor));
    }
    final groups = eps.isEmpty ? const <_ThemeGroup>[] : _themeGroups(app, dir, eps);
    final working = dir.isNotEmpty && app.podcastThemes.isWorking(dir);
    final themeError = dir.isEmpty || eps.length < PodcastThemesService.minEpisodes ? null : app.podcastThemes.errorFor(dir);
    final canTheme = groups.isNotEmpty;
    final byTheme = canTheme && (app.prefs.getString(_viewKey) ?? 'themes') == 'themes';

    Widget toggle(String label, String value, bool on) => GestureDetector(
      onTap: () async {
        await app.prefs.setString(_viewKey, value);
        app.touch();
      },
      child: Bevel(
        sunken: on,
        color: on ? const Color(0xFFE3E1D4) : Xp.beige,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(label, style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.bold : FontWeight.normal)),
      ),
    );

    return Scaffold(
      backgroundColor: Xp.beige,
      body: SafeArea(
        child: Column(children: [
          XpTitleBar(title: program, icon: XpIcons.mic, actions: [
            XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
          ]),
          XpAddressBar('Podcasts\\$program', icon: XpIcons.mic),
          if (eps.isNotEmpty)
            _InfoHeader(
              thumb: programThumb(app, pr),
              title: program,
              lines: [
                '${eps.length} ${eps.length == 1 ? 'episódio' : 'episódios'} · ${fresh.length} ${fresh.length == 1 ? 'novo' : 'novos'}'
                    '${canTheme ? ' · ${groups.where((g) => g.theme != null).length} temas' : ''}',
              ],
              action: fresh.isEmpty ? null : ('Tocar os não ouvidos', () => playEpisode(context, fresh.last, following: fresh.reversed.toList())),
              onLongPress: (at) => showProgramMenu(context, pr, at),
            ),
          if (canTheme)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8)))),
              child: Row(children: [
                const Text('Exibir:', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 6),
                toggle('Por tema', 'themes', byTheme),
                const SizedBox(width: 4),
                toggle('Todos os episódios', 'all', !byTheme),
              ]),
            ),
          if (working)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFFFE1),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: const Text('Separando os episódios por tema…', style: TextStyle(fontSize: 12.5)),
            )
          else if (!canTheme && themeError != null)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFFFE1),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'Não deu para separar por tema: $themeError. '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: GestureDetector(
                      onTap: () => app.podcastThemes.ensure(dir, program, eps, app.podcastInfo.infoFor, force: true),
                      child: const Text('Tentar de novo', style: TextStyle(fontSize: 12.5, color: Xp.linkBlue, decoration: TextDecoration.underline)),
                    ),
                  ),
                ]),
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          Expanded(
            child: ColoredBox(
              color: Colors.white,
              child: eps.isEmpty
                  ? const EmptyHint(Icons.mic_off, 'Nenhum episódio neste programa.')
                  : byTheme
                      ? GridView.builder(
                          padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisExtent: 178),
                          itemCount: groups.length,
                          itemBuilder: (context, i) {
                            final g = groups[i];
                            final n = g.episodes.length;
                            return GestureDetector(
                              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                                builder: (_) => PodcastThemeScreen(program: program, themeName: g.theme?.name),
                              )),
                              child: Column(children: [
                                ThumbFrame(
                                  thumb: g.thumb,
                                  size: 104,
                                  name: g.name,
                                  count: g.episodes.where((e) => !prog.listened(e.path)).length,
                                  placeholderIcon: g.theme == null ? XpIcons.mic : null,
                                ),
                                const SizedBox(height: 4),
                                Text(g.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, height: 1.15)),
                                Text('$n ${n == 1 ? 'episódio' : 'episódios'}', style: const TextStyle(fontSize: 11, color: Color(0xFF666666))),
                              ]),
                            );
                          },
                        )
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

/// Um quadradinho da tela do programa: um tema (com GIF) ou "Outros" ([theme] null).
class _ThemeGroup {
  final EpisodeTheme? theme;
  final List<Track> episodes;
  final GroupThumb thumb;
  const _ThemeGroup(this.theme, this.episodes, this.thumb);
  String get name => theme?.name ?? 'Outros';
}

/// Temas guardados do programa aplicados aos episódios de agora. Vazio = programa sem temas (ainda).
List<_ThemeGroup> _themeGroups(AppState app, String dir, List<Track> eps) {
  final saved = app.podcastThemes.themesFor(dir);
  if (saved == null || saved.themes.isEmpty) return const [];
  final byFile = {for (final e in eps) p.basename(e.path): e};
  final placed = <String>{};
  final out = <_ThemeGroup>[];
  for (final t in saved.themes) {
    final list = [for (final f in t.files) if (byFile[f] != null && placed.add(f)) byFile[f]!]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (list.isEmpty) continue;
    final gif = app.podcastThemes.gifFile(dir, t);
    out.add(_ThemeGroup(t, list, GroupThumb(file: gif, isGif: gif != null, color: colorFor(t.name))));
  }
  final rest = [for (final e in eps) if (!placed.contains(p.basename(e.path))) e];
  if (rest.isNotEmpty) out.add(_ThemeGroup(null, rest, GroupThumb(color: colorFor('Outros'))));
  return out;
}

/// Episódios de um tema (ou de "Outros", [themeName] null).
class PodcastThemeScreen extends StatelessWidget {
  final String program;
  final String? themeName;
  const PodcastThemeScreen({super.key, required this.program, required this.themeName});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListenableBuilder(listenable: app.podcastThemes, builder: (context, _) => _build(context, app));
  }

  Widget _build(BuildContext context, AppState app) {
    final eps = [for (final t in app.podcasts) if (t.artist == program) t];
    final dir = eps.isEmpty ? '' : AppState.programDirOf(eps.first);
    final groups = eps.isEmpty ? const <_ThemeGroup>[] : _themeGroups(app, dir, eps);
    final g = groups.where((x) => x.theme?.name == themeName).firstOrNull;
    final list = g?.episodes ?? const <Track>[];
    final name = themeName ?? 'Outros';
    final fresh = list.where((e) => !app.podcastProgress.listened(e.path)).toList();
    final others = [for (final x in groups) if (x.theme != null && x.theme!.name != themeName) x.theme!.name];
    // ordem de ouvir: do mais antigo para o mais novo
    final inOrder = list.reversed.toList();
    return Scaffold(
      backgroundColor: Xp.beige,
      body: SafeArea(
        child: Column(children: [
          XpTitleBar(title: name, icon: XpIcons.mic, actions: [
            XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
          ]),
          XpAddressBar('Podcasts\\$program\\$name', icon: XpIcons.mic),
          if (g != null)
            _InfoHeader(
              thumb: g.thumb,
              title: name,
              placeholderIcon: g.theme == null ? XpIcons.mic : null,
              lines: ['${list.length} ${list.length == 1 ? 'episódio' : 'episódios'} · ${fresh.length} ${fresh.length == 1 ? 'novo' : 'novos'}'],
              action: list.isEmpty ? null : ('Tocar este tema', () => playEpisode(context, inOrder.first, following: inOrder)),
            ),
          Expanded(
            child: ColoredBox(
              color: Colors.white,
              child: list.isEmpty
                  ? const EmptyHint(Icons.mic_off, 'Nenhum episódio neste tema.')
                  : ListView(padding: EdgeInsets.zero, children: [
                      // tema costuma ser série: do mais antigo para o mais novo (parte 1, parte 2...)
                      for (var i = 0; i < inOrder.length; i++)
                        EpisodeTile(
                          episode: inOrder[i],
                          following: inOrder.sublist(i + 1),
                          moveTargets: [...others, if (themeName != null) null],
                          onMove: (to) => app.podcastThemes.move(dir, p.basename(inOrder[i].path), to),
                        ),
                    ]),
            ),
          ),
          XpStatusBar(['${list.length} ${list.length == 1 ? 'episódio' : 'episódios'}', program]),
        ]),
      ),
    );
  }
}

/// Topo estilo "Informações do álbum" do WMP: imagem grande, nome, contagem e um link de ação.
class _InfoHeader extends StatelessWidget {
  final GroupThumb thumb;
  final String title;
  final List<String> lines;
  final (String, VoidCallback)? action;
  final void Function(Offset at)? onLongPress;
  final XpIcons? placeholderIcon;
  const _InfoHeader({required this.thumb, required this.title, required this.lines, this.action, this.onLongPress, this.placeholderIcon = XpIcons.mic});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPressStart: onLongPress == null ? null : (d) => onLongPress!(d.globalPosition),
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Xp.bgTop, Xp.bgBottom]),
        border: Border(bottom: BorderSide(color: Color(0xFF9FB3D6))),
      ),
      child: Row(children: [
        ThumbFrame(thumb: thumb, size: 76, name: title, padding: 3, badge: '', placeholderIcon: placeholderIcon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Xp.navy)),
            for (final l in lines) Text(l, style: const TextStyle(fontSize: 12.5, color: Xp.blueText)),
            if (action != null)
              InkWell(
                onTap: action!.$2,
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const XpIcon(XpIcons.play, size: 14),
                    const SizedBox(width: 4),
                    Text(action!.$1, style: const TextStyle(fontSize: 13, color: Xp.linkBlue)),
                  ]),
                ),
              ),
          ]),
        ),
      ]),
    ),
  );
}

/// Linha de episódio: título, duração e onde parou ("novo", "parou em 1:02:10", "ouvido ✓").
class EpisodeTile extends StatelessWidget {
  final Track episode;

  /// Episódios que tocam depois dele quando tocado daqui.
  final List<Track> following;

  /// Temas para onde dá para mudar o episódio (null = "Outros"). Vazio = sem a opção no menu.
  final List<String?> moveTargets;
  final void Function(String? toTheme)? onMove;
  const EpisodeTile({super.key, required this.episode, required this.following, this.moveTargets = const [], this.onMove});

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
          if (onMove != null && moveTargets.isNotEmpty) ...[
            null,
            for (final to in moveTargets) XpMenuEntry('Mover para: ${to ?? 'Outros'}', () => onMove!(to), icon: XpIcons.folder),
          ],
        ]),
        child: InkWell(
          onTap: () => playEpisode(context, episode, following: following),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
            child: Row(children: [
              _art(app),
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

  /// Imagem do programa pequenininha no lugar do microfone (se tiver).
  Widget _art(AppState app) {
    final f = app.programArt.fileFor(AppState.programDirOf(episode));
    if (f == null) return const XpIcon(XpIcons.mic, size: 30);
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFB8C4D8))),
      child: Image.file(f, fit: BoxFit.cover, cacheWidth: 90, gaplessPlayback: true, errorBuilder: (_, _, _) => const XpIcon(XpIcons.mic, size: 26)),
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
