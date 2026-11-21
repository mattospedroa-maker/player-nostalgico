import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../player_service.dart';
import '../podcast_info.dart';
import '../podcasts.dart';
import '../theme.dart';
import '../xp_icons.dart';

/// Opção B (escolha de Cuseko): balão amarelo do XP sobre a imagem do episódio. Aparece no começo e a cada
/// capítulo novo, some sozinho em 8 s. Tocar abre o resumo completo.
class EpisodeBalloon extends StatefulWidget {
  final Track track;
  const EpisodeBalloon({super.key, required this.track});

  @override
  State<EpisodeBalloon> createState() => _EpisodeBalloonState();
}

class _EpisodeBalloonState extends State<EpisodeBalloon> {
  static const shownFor = Duration(seconds: 8);
  DateTime _until = DateTime.now().add(shownFor);
  int? _chapterMs = -1;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _show() {
    _until = DateTime.now().add(shownFor);
    _hide?.cancel();
    _hide = Timer(shownFor, () => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final ps = context.read<PlayerService>();
    return ListenableBuilder(
      listenable: app.podcastInfo,
      builder: (context, _) => StreamBuilder<Duration>(
        stream: ps.player.positionStream,
        builder: (context, snap) {
          final info = app.podcastInfo.infoFor(widget.track.path);
          final working = app.podcastInfo.isWorking(widget.track.path);
          final ch = info?.chapterAt(snap.data ?? Duration.zero);
          if (ch?.startMs != _chapterMs) {
            final first = _chapterMs == -1;
            _chapterMs = ch?.startMs;
            if (first) {
              _hide ??= Timer(shownFor, () => mounted ? setState(() {}) : null);
            } else {
              _show();
            }
          }
          if (DateTime.now().isAfter(_until)) return const SizedBox.shrink();
          final String title;
          final String body;
          if (info == null || (!info.hasSummary && info.chapters.isEmpty)) {
            if (!working) return const SizedBox.shrink();
            title = 'Fazendo o resumo deste episódio…';
            body = 'A IA está lendo a legenda. Leva uns segundos.';
          } else if (ch != null) {
            title = 'Agora: ${ch.title}';
            body = ch.summary.isNotEmpty ? ch.summary : _short(info.summary);
          } else {
            title = 'Sobre este episódio';
            body = _short(info.summary.isNotEmpty ? info.summary : info.description);
          }
          return Positioned(
            left: 10,
            right: 10,
            top: 10,
            child: GestureDetector(
              onTap: () => showEpisodeSummary(context, widget.track),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFFE1),
                  border: Border.all(color: Colors.black),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), offset: Offset(2, 2), blurRadius: 3)],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const XpIcon(XpIcons.info, size: 16),
                    const SizedBox(width: 6),
                    Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                  ]),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(body, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Colors.black)),
                  ],
                  if (info != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Text('Ler resumo completo', style: TextStyle(fontSize: 12, color: Xp.linkBlue, decoration: TextDecoration.underline)),
                    ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  static String _short(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 220 ? '${t.substring(0, 220)}…' : t;
  }
}

/// Resumo completo do episódio: do que se trata, quem participa, capítulos (tocar pula para ele) e temas.
Future<void> showEpisodeSummary(BuildContext context, Track t) {
  final app = context.read<AppState>();
  final ps = context.read<PlayerService>();
  return showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: app.podcastInfo,
      builder: (ctx, _) {
        final info = app.podcastInfo.infoFor(t.path);
        final working = app.podcastInfo.isWorking(t.path);
        final canRedo = app.geminiKey.isNotEmpty && ((info?.videoId.isNotEmpty ?? false) || app.downloads.youtubeIdFor(t.path) != null);
        Widget h(String s) => Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 3),
              child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Color(0xFF1C3F94))),
            );
        return XpAlertDialog(
          icon: XpIcons.mic,
          title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .6),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text([t.artist, if (t.durationMs > 0) formatDuration(Duration(milliseconds: t.durationMs)), if ((info?.subject ?? '').isNotEmpty) info!.subject].join(' · '),
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
                if (working) h('Fazendo o resumo… (pode levar até uns minutos)'),
                if (info == null && !working)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      canRedo
                          ? 'Ainda sem resumo. Toque em "Fazer resumo".'
                          : app.geminiKey.isEmpty
                              ? 'Sem resumo: falta a chave do Gemini.'
                              : 'Sem resumo: este arquivo não foi baixado pelo app, então não dá para achar a legenda do vídeo.',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                if (info != null) ...[
                  if (info.hasSummary) ...[h('Do que se trata'), Text(info.summary, style: const TextStyle(fontSize: 13.5))],
                  // o aviso da tentativa anterior some enquanto uma nova está em andamento
                  if (!working && info.status != SummaryStatus.none && info.status != SummaryStatus.ok)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        (info.error ?? '').isNotEmpty ? info.error! : 'Resumo: ${info.status.label}.',
                        style: TextStyle(fontSize: 12.5, color: info.hasSummary ? const Color(0xFF555555) : Xp.red),
                      ),
                    ),
                  if (info.people.isNotEmpty) ...[
                    h('Quem participa'),
                    for (final x in info.people)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          const XpIcon(XpIcons.person, size: 16),
                          const SizedBox(width: 6),
                          Expanded(child: Text(x.role.isEmpty ? x.name : '${x.name} (${x.role})', style: const TextStyle(fontSize: 13.5))),
                        ]),
                      ),
                  ],
                  if (info.chapters.isNotEmpty) ...[
                    h('Capítulos (toque para ir)'),
                    for (final c in info.chapters)
                      InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          if (ps.current?.id == t.id) ps.seek(Duration(milliseconds: c.startMs));
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${formatClock(Duration(milliseconds: c.startMs))}  ${c.title}', style: const TextStyle(fontSize: 13.5, color: Xp.linkBlue)),
                            if (c.summary.isNotEmpty) Text(c.summary, style: const TextStyle(fontSize: 12, color: Color(0xFF555555))),
                          ]),
                        ),
                      ),
                  ],
                  if (info.topics.isNotEmpty) ...[h('Temas'), Text(info.topics.join(' · '), style: const TextStyle(fontSize: 13))],
                  if (info.hasSummary)
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text('Resumo feito por IA (Gemini).', style: TextStyle(fontSize: 11, color: Color(0xFF777777))),
                    ),
                ],
              ]),
            ),
          ),
          actions: [
            if (canRedo && !working)
              TextButton(
                onPressed: () {
                  final id = info?.videoId.isNotEmpty == true ? info!.videoId : app.downloads.youtubeIdFor(t.path)!;
                  app.podcastInfo.summarize(t.path, 'https://www.youtube.com/watch?v=$id', title: t.title, program: t.artist);
                },
                child: Text(info?.hasSummary ?? false ? 'Refazer resumo' : 'Fazer resumo'),
              ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        );
      },
    ),
  );
}

/// Riscos amarelos na barra de tempo, um por capítulo.
class ChapterMarks extends StatelessWidget {
  final List<Duration> marks;
  final Duration total;

  /// Recuo da barra do Slider de cada lado (o espaço do botão de arrastar).
  static const inset = 24.0;
  const ChapterMarks({super.key, required this.marks, required this.total});

  @override
  Widget build(BuildContext context) {
    if (marks.isEmpty || total <= Duration.zero) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth - inset * 2;
        return Stack(children: [
          for (final m in marks)
            if (m > Duration.zero && m < total)
              Positioned(
                left: inset + w * (m.inMilliseconds / total.inMilliseconds) - 1,
                top: 0,
                bottom: 0,
                child: Center(child: Container(width: 3, height: 14, color: const Color(0xFFFFC800))),
              ),
        ]);
      }),
    );
  }
}
