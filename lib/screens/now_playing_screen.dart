import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../artist_photos.dart';
import '../audio_handler.dart';
import '../filename_parser.dart';
import '../gif_fetcher.dart';
import '../gif_service.dart';
import '../models.dart';
import '../mood.dart';
import '../player_service.dart';
import '../podcast_info.dart';
import '../podcasts.dart';
import '../main.dart' show HomeShell;
import '../skip_guard.dart';
import '../theme.dart';
import '../visual_search.dart';
import '../widgets.dart';
import '../xp_icons.dart';
import 'audiobooks_screen.dart' show BookScreen;
import 'book_reader.dart';
import 'edit_track_screen.dart';
import 'episode_summary.dart';
import 'gif_vibe_screen.dart';
import 'gif_web_screen.dart';
import 'why_screen.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ps = context.watch<PlayerService>();
    final app = context.watch<AppState>();
    final t = ps.current == null ? null : (app.byId(ps.current!.id) ?? ps.current);
    final book = t != null && app.isAudiobook(t);
    final pod = t != null && app.isSpoken(t);
    // livro com o celular deitado: o leitor ocupa a tela toda
    if (book && MediaQuery.orientationOf(context) == Orientation.landscape) {
      return Column(children: [
        XpTitleBar(title: app.bookInfoOf(t).title.isEmpty ? t.title : app.bookInfoOf(t).title, icon: XpIcons.book),
        Expanded(child: BookReader(key: ValueKey('livro-deitado-${t.id}'), track: t)),
        XpStatusBar(['${ps.playing ? 'Tocando' : 'Pausado'} · ${t.title}', 'Audiolivro · ${_speed(ps.podcastSpeed)}']),
      ]);
    }
    return Column(
      children: [
        const XpTitleBar(title: 'Tocando agora'),
        XpMenuBar([
          (
            'Arquivo',
            [
              XpMenuItem(
                'Editar informações…',
                t == null ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditTrackScreen(track: t))),
              ),
              XpMenuItem('Adicionar a uma playlist…', t == null || pod ? null : () => pickPlaylistAndAdd(context, t)),
              XpMenuItem(t?.favorite ?? false ? 'Tirar das favoritas' : 'Adicionar às favoritas', t == null || pod ? null : () => app.toggleFavorite(t)),
            ],
          ),
          (
            'Exibir',
            [
              XpMenuItem('Fila de reprodução', t == null ? null : () => _Toolbar.showQueue(context)),
              XpMenuItem('GIFs desta música…', t == null || pod ? null : () => showGifManager(context, t)),
            ],
          ),
          (
            'Tocar',
            [
              XpMenuItem(ps.playing ? 'Pausar' : 'Tocar', t == null ? null : ps.togglePlay),
              XpMenuItem('Anterior', t == null ? null : ps.previous),
              XpMenuItem('Próxima', t == null ? null : ps.next),
              XpMenuItem('Aleatório', ps.toggleShuffle, checked: ps.shuffle),
              XpMenuItem('Repetir', ps.cycleLoop, checked: ps.loop != LoopMode.off),
              XpMenuItem('Transição suave (sai ${ps.fadeOut.inSeconds}s, entra ${ps.fadeIn.inSeconds}s)', () => ps.setCrossfade(!ps.crossfade), checked: ps.crossfade),
            ],
          ),
          (
            'Mix',
            [
              XpMenuItem('Da mesma vibe', () => ps.setMixMode(MixMode.vibe), checked: ps.mixMode == MixMode.vibe),
              XpMenuItem('Do mesmo artista', () => ps.setMixMode(MixMode.artist), checked: ps.mixMode == MixMode.artist),
            ],
          ),
        ]),
        Expanded(
          child: t == null
              ? const EmptyHint(Icons.music_off, 'Nada tocando.\nEscolha uma música na Biblioteca.')
              : ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (book) _BookPanel(key: ValueKey('livro-${t.id}'), track: t) else GifCarousel(key: ValueKey(t.id), track: t),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: StreamBuilder<Duration>(
                        stream: ps.player.positionStream,
                        builder: (context, snap) => LcdPanel(
                          lines: book
                              ? [
                                  ('Livro', app.bookInfoOf(t).title.isEmpty ? t.title : app.bookInfoOf(t).title),
                                  ('Capítulo', _chapterLabel(app, t, snap.data ?? Duration.zero)),
                                  ('Autor', '${t.artist} · ${_speed(ps.podcastSpeed)}'),
                                ]
                              : pod
                              ? [
                                  ('Programa', t.artist),
                                  ('Episódio', t.title),
                                  ('Podcast', 'velocidade ${_speed(ps.podcastSpeed)}${ps.podcastMode ? '' : ' · depois voltam as músicas'}'),
                                ]
                              : [
                                  ('Artista', t.artist),
                                  ('Faixa', t.title),
                                  ('Álbum', [t.album, if ((t.year ?? 0) > 0) '${t.year}'].join(' · ')),
                                ],
                          time: _clock(snap.data ?? Duration.zero),
                          total: _clock(ps.player.duration ?? Duration(milliseconds: t.durationMs)),
                          playing: ps.playing,
                          note: audioInitError == null ? null : 'Notificação desligada: $audioInitError',
                        ),
                      ),
                    ),
                    if (book)
                      ListenableBuilder(
                        listenable: app.bookService,
                        builder: (_, _) => SeekBar(
                          player: ps.player,
                          onSeek: ps.seek,
                          marks: [for (final c in app.bookInfoOf(t).chapters) Duration(milliseconds: c.startMs)],
                        ),
                      )
                    else if (pod)
                      ListenableBuilder(
                        listenable: app.podcastInfo,
                        builder: (_, _) => SeekBar(
                          player: ps.player,
                          onSeek: ps.seek,
                          marks: [for (final c in app.podcastInfo.infoFor(t.path)?.chapters ?? const <Chapter>[]) Duration(milliseconds: c.startMs)],
                        ),
                      )
                    else
                      SeekBar(player: ps.player, onSeek: ps.seek),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: GlossyBar(
                        children: pod
                            ? [
                                GlossyButton(icon: Icons.replay_10, size: 40, onTap: () => ps.seekBy(const Duration(seconds: -10)), tooltip: 'Voltar 10 s'),
                                GlossyButton(icon: Icons.skip_previous, size: 46, onTap: ps.previous, tooltip: 'Anterior'),
                                GlossyButton(icon: ps.playing ? Icons.pause : Icons.play_arrow, size: 66, onTap: ps.togglePlay),
                                GlossyButton(icon: Icons.skip_next, size: 46, onTap: ps.next, tooltip: 'Próximo'),
                                GlossyButton(icon: Icons.forward_30, size: 40, onTap: () => ps.seekBy(const Duration(seconds: 30)), tooltip: 'Avançar 30 s'),
                                GlossyButton(icon: Icons.speed, size: 36, active: ps.podcastSpeed != 1.0, onTap: ps.cyclePodcastSpeed, tooltip: 'Velocidade: ${_speed(ps.podcastSpeed)}'),
                              ]
                            : [
                          GlossyButton(icon: Icons.shuffle, size: 40, active: ps.shuffle, onTap: ps.toggleShuffle, tooltip: 'Aleatório'),
                          GlossyButton(icon: Icons.skip_previous, size: 46, onTap: ps.previous, tooltip: 'Anterior'),
                          GlossyButton(icon: ps.playing ? Icons.pause : Icons.play_arrow, size: 66, onTap: ps.togglePlay),
                          GlossyButton(icon: Icons.skip_next, size: 46, onTap: ps.next, tooltip: 'Próxima'),
                          GlossyButton(
                            icon: ps.loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                            size: 40,
                            active: ps.loop != LoopMode.off,
                            onTap: ps.cycleLoop,
                            tooltip: 'Repetir',
                          ),
                          GlossyButton(
                            icon: Icons.swap_horiz,
                            size: 36,
                            active: ps.crossfade,
                            glyph: CrossfadeGlyph.new,
                            onTap: () => ps.setCrossfade(!ps.crossfade),
                            tooltip: ps.crossfade ? 'Transição suave: ligada' : 'Transição suave: desligada',
                          ),
                        ],
                      ),
                    ),
                    if (book) _BookBox(track: t) else if (pod) _PodcastBox(track: t) else ...[_Toolbar(track: t), const _MixBox()],
                    const SizedBox(height: 12),
                  ],
                ),
        ),
        // plano B dos GIFs: a barra diz qual serviço caiu e o que entrou no lugar
        ListenableBuilder(
          listenable: Listenable.merge([app.gifs, app.gifFetcher.health]),
          builder: (_, _) {
            final outage = t == null ? null : app.gifFetcher.statusFor(t);
            return XpStatusBar([
              outage != null ? '🌐 $outage' : (t == null ? 'Pronto' : '${ps.playing ? 'Tocando' : 'Pausado'} · ${t.title}'),
              if (t != null) p.extension(t.path).replaceFirst('.', '').toUpperCase(),
              if (book) 'Audiolivro · ${_speed(ps.podcastSpeed)}' else if (pod) 'Podcast · ${_speed(ps.podcastSpeed)}' else ...[
                'Mix: ${ps.mixMode == MixMode.artist ? 'artista' : 'vibe'}',
                ps.crossfade ? 'Transição: ligada' : 'Transição: desligada',
              ],
            ]);
          },
        ),
      ],
    );
  }

  /// "7 · O delírio" (capítulo tocando agora).
  static String _chapterLabel(AppState app, Track t, Duration pos) {
    final info = app.bookInfoOf(t);
    final i = info.chapterIndexAt(pos);
    if (i < 0) return 'sem capítulos';
    final title = info.chapters[i].title;
    return title.isEmpty ? '${i + 1} de ${info.chapters.length}' : '${i + 1} · $title';
  }

  static String _speed(double v) => '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString().replaceAll('.', ',')}x';

  static String _clock(Duration d) => '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// Livro no lugar dos GIFs (opção C): a folha do livro, com ⤢ para a tela cheia.
class _BookPanel extends StatelessWidget {
  final Track track;
  const _BookPanel({super.key, required this.track});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        height: 300,
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Color(0xFF808080), width: 2),
            left: BorderSide(color: Color(0xFF808080), width: 2),
            right: BorderSide(color: Colors.white, width: 2),
            bottom: BorderSide(color: Colors.white, width: 2),
          ),
        ),
        child: BookReader(track: track, compact: true),
      );
}

/// Livro tocando: Livro (tela cheia), Capítulos, Aa e Marcar lido.
class _BookBox extends StatelessWidget {
  final Track track;
  const _BookBox({required this.track});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final done = app.podcastProgress.listened(track.path);
    Widget item(XpIcons i, String label, VoidCallback onTap, {bool on = false}) => Expanded(
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: BevelButton(icon: i, label: label, onTap: onTap, on: on)),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
      child: Row(children: [
        item(XpIcons.book, 'Livro', () => openFullReader(context, track), on: true),
        item(XpIcons.list, 'Capítulos', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BookScreen(trackId: track.id!)))),
        item(XpIcons.edit, 'Aa', () => showReaderLook(context)),
        item(XpIcons.check, done ? 'Lido' : 'Marcar lido', () {
          app.podcastProgress.setListened(track.path, !done);
          app.touch();
        }, on: done),
      ]),
    );
  }
}

/// Podcast tocando: botões próprios (fila, ouvido) e o que vem depois (próximo episódio ou a volta das músicas).
class _PodcastBox extends StatelessWidget {
  final Track track;
  const _PodcastBox({required this.track});

  @override
  Widget build(BuildContext context) {
    final ps = context.watch<PlayerService>();
    final app = context.read<AppState>();
    final next = ps.upcoming.take(3).toList();
    final listened = app.podcastProgress.listened(track.path);
    Widget item(XpIcons i, String label, VoidCallback onTap, {bool on = false}) => Expanded(
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: BevelButton(icon: i, label: label, onTap: onTap, on: on)),
        );
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
        child: Row(children: [
          item(XpIcons.list, 'Fila', () => _Toolbar.showQueue(context)),
          item(XpIcons.doc, 'Resumo', () => showEpisodeSummary(context, track)),
          item(XpIcons.check, listened ? 'Ouvido' : 'Marcar ouvido', () {
            app.podcastProgress.setListened(track.path, !listened);
            app.touch();
          }, on: listened),
          item(XpIcons.mic, 'Podcasts', () {
            app.setLibraryMedia(MediaKind.podcasts);
            HomeShell.goTo(context, 1);
          }),
        ]),
      ),
      Container(
        margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
        child: Bevel(
          sunken: true,
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ps.podcastMode ? 'Depois deste episódio:' : 'Depois deste episódio, as músicas voltam:',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1C3F94))),
            if (next.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Nada. O player para quando o episódio acabar.', style: TextStyle(fontSize: 12, color: Xp.blueMuted)),
              ),
            for (final t in next)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(children: [
                  XpIcon(app.isPodcast(t) ? XpIcons.mic : XpIcons.note, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Xp.navy))),
                ]),
              ),
          ]),
        ),
      ),
    ]);
  }
}

/// "Depois desta, tocar:" Da mesma vibe / Do mesmo artista, e as 3 próximas.
class _MixBox extends StatelessWidget {
  const _MixBox();

  @override
  Widget build(BuildContext context) {
    final ps = context.watch<PlayerService>();
    final next = ps.upcoming.take(3).toList();
    Widget seg(String label, MixMode m) {
      final on = ps.mixMode == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => ps.setMixMode(m),
          child: Bevel(
            sunken: on,
            color: on ? const Color(0xFFE3E1D4) : Xp.beige,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: const Color(0xFF1C5180))),
                alignment: Alignment.center,
                child: on ? Container(width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF21A121))) : null,
              ),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontWeight: on ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
            ]),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      child: Bevel(
        sunken: true,
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Depois desta, tocar:', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1C3F94))),
          const SizedBox(height: 7),
          Row(children: [seg('Da mesma vibe', MixMode.vibe), const SizedBox(width: 4), seg('Do mesmo artista', MixMode.artist)]),
        if (ps.loop != LoopMode.off)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Repetir está ligado: o mix volta quando você desligar.', style: TextStyle(fontSize: 11, color: Xp.blueMuted)),
          ),
        if (next.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('A seguir:', style: TextStyle(fontSize: 12, color: Xp.blueMuted)),
          for (final t in next)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (d) => showXpContextMenu(context, header: '${t.title} — ${t.artist}', at: d.globalPosition, items: [
                XpMenuEntry('Por que está aqui?', () => showWhyWindow(context, t), icon: XpIcons.info),
              ]),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE3EAF6)))),
                child: Row(children: [
                  CoverSquare(t, size: 28),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Xp.navy)),
                      Text([t.artist, if (t.genre.isNotEmpty) t.genre].join(' · '),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Xp.blueMuted)),
                      if (ps.mixReason(t) case final why?) WhyLine(why, onTap: () => showWhyWindow(context, t)),
                    ]),
                  ),
                ]),
              ),
            ),
        ],
        ]),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final Track track;
  const _Toolbar({required this.track});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    Widget item(XpIcons i, String label, VoidCallback onTap, {bool on = false}) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: BevelButton(icon: i, label: label, onTap: onTap, on: on),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
      child: Row(
        children: [
          item(XpIcons.heart, 'Favorita', () => app.toggleFavorite(track), on: track.favorite),
          item(XpIcons.film, 'GIFs', () => showGifManager(context, track)),
          item(XpIcons.plus, 'Playlist', () => pickPlaylistAndAdd(context, track)),
          item(XpIcons.list, 'Fila', () => showQueue(context)),
          item(XpIcons.edit, 'Editar', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditTrackScreen(track: track)))),
        ],
      ),
    );
  }

  static void showQueue(BuildContext context) => showQueueWindow(context);
}

/// Abre a Lista de reprodução (a fila) por baixo da tela.
void showQueueWindow(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Xp.beige,
    builder: (ctx) => DraggableScrollableSheet(expand: false, initialChildSize: .75, maxChildSize: .95, builder: (ctx, sc) => _QueueWindow(scroll: sc)),
  );
}

/// A fila como a "Lista de reprodução" do WMP 9: visor, lista numerada e botões em relevo.
class _QueueWindow extends StatefulWidget {
  final ScrollController scroll;
  const _QueueWindow({required this.scroll});

  @override
  State<_QueueWindow> createState() => _QueueWindowState();
}

class _QueueWindowState extends State<_QueueWindow> {
  int? _sel;

  Future<void> _save(List<Track> q) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final name = await askText(context, 'Salvar como playlist', 'Nome da playlist');
    if (name == null || name.isEmpty) return;
    final id = await app.db.createPlaylist(name);
    await app.db.setPlaylistOrder(id, [for (final t in q) if (t.id != null) t.id!]);
    await app.reload();
    messenger.showSnackBar(SnackBar(content: Text('Playlist "$name" criada com ${q.length} músicas.')));
  }

  /// Segurar uma música que não abriu: tentar de novo, tirar da fila ou apagar do celular.
  void _failedMenu(PlayerService ps, Track t, int i, Offset at) {
    showXpContextMenu(context, header: '${t.title} — ${t.artist}', at: at, items: [
      XpMenuEntry('Tentar de novo', () {
        ps.retry(t);
        Navigator.pop(context);
      }, icon: XpIcons.play),
      XpMenuEntry('Tirar da fila', i == ps.player.currentIndex ? null : () => ps.removeAt(i), icon: XpIcons.bin),
      null,
      XpMenuEntry('Apagar do celular…', () => _confirmDelete(ps, t), icon: XpIcons.warning),
    ]);
  }

  /// Segurar uma música da fila: por que ela está aqui, tirar ou ver as propriedades.
  void _rowMenu(PlayerService ps, Track t, int i, Offset at) {
    showXpContextMenu(context, header: '${t.title} — ${t.artist}', at: at, items: [
      XpMenuEntry('Por que está aqui?', () => showWhyWindow(context, t), icon: XpIcons.info),
      XpMenuEntry('Tirar da fila', i == ps.player.currentIndex ? null : () => ps.removeAt(i), icon: XpIcons.bin),
      null,
      XpMenuEntry('Propriedades…', () {
        final known = context.read<AppState>().byId(t.id) ?? t;
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditTrackScreen(track: known)));
      }, icon: XpIcons.edit),
    ]);
  }

  Future<void> _confirmDelete(PlayerService ps, Track t) async {
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => XpAlertDialog(
        icon: XpIcons.warning,
        title: const Text('Apagar música?'),
        content: Text('"${t.title}" será apagada do celular e sai da biblioteca. Não dá para desfazer.'),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        ],
      ),
    );
    if (ok != true) return;
    final i = ps.queue.indexWhere((q) => q.path == t.path);
    if (i >= 0) await ps.removeAt(i);
    final known = app.byId(t.id);
    if (known != null) await app.deleteTrack(known);
  }

  @override
  Widget build(BuildContext context) {
    final ps = context.watch<PlayerService>();
    final q = ps.queue;
    final cur = ps.player.currentIndex;
    final sel = (_sel != null && _sel! < q.length) ? _sel : null;
    Widget lcd(String k, String v) => Row(children: [
          SizedBox(width: 70, child: Text(k, style: Xp.lcdStyle.copyWith(color: Xp.lcdDim, shadows: const []))),
          Expanded(child: Text(v.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: Xp.lcdStyle)),
        ]);
    Widget act(XpIcons i, String label, VoidCallback? onTap) => Expanded(
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Opacity(opacity: onTap == null ? .45 : 1, child: BevelButton(icon: i, label: label, onTap: onTap))),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      XpTitleBar(title: 'Lista de reprodução', icon: XpIcons.list, actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))]),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Bevel(
          sunken: true,
          color: const Color(0xFF020A1C),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(children: [
            lcd('FILA', ps.shuffle ? 'Aleatória' : (ps.mixMode == MixMode.artist ? 'Mix do mesmo artista' : 'Mix da mesma vibe')),
            const SizedBox(height: 2),
            lcd('TOTAL', '${q.length} faixas · ${fmtTotal(q)}'),
          ]),
        ),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Bevel(
            sunken: true,
            child: Column(children: [
              Row(children: const [
                SizedBox(width: 40, child: XpColumnHeader('#')),
                Expanded(child: XpColumnHeader('Título', right: 'Tempo')),
              ]),
              Expanded(
                child: ListView.builder(
                  controller: widget.scroll,
                  itemCount: q.length,
                  itemExtent: 40,
                  itemBuilder: (ctx, i) {
                    final t = q[i];
                    final on = i == cur;
                    final picked = i == sel;
                    final bad = ps.failureOf(t);
                    if (bad != null && !on) return _failedRow(ps, t, i, bad, picked);
                    final why = ps.mixReason(t);
                    return GestureDetector(
                      onLongPressStart: (d) => _rowMenu(ps, t, i, d.globalPosition),
                      child: InkWell(
                      onTap: () => setState(() => _sel = i),
                      onDoubleTap: () {
                        ps.jumpTo(i);
                        Navigator.pop(context);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          // amarelo: você pôs com "Tocar a seguir" / "Adicionar à fila"
                          color: on ? Xp.select : (picked ? const Color(0xFFDCE7FB) : (ps.isUserQueued(t) ? const Color(0xFFFFF6CC) : Colors.white)),
                          border: Border(bottom: const BorderSide(color: Color(0xFFF0F0F0)), left: BorderSide(color: picked ? Xp.select : Colors.transparent, width: 3)),
                        ),
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(children: [
                          SizedBox(width: 34, child: Text('${i + 1}', textAlign: TextAlign.right, style: TextStyle(fontSize: 13, color: on ? const Color(0xFFCCEEFF) : const Color(0xFF888888)))),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text.rich(
                                TextSpan(children: [
                                  TextSpan(text: t.title, style: TextStyle(fontWeight: on ? FontWeight.bold : FontWeight.normal)),
                                  TextSpan(text: '  ${t.artist}', style: TextStyle(fontSize: 12, color: on ? const Color(0xFFDFE8FF) : const Color(0xFF888888))),
                                ]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: why == null ? 14 : 13.5, color: on ? Colors.white : Colors.black),
                              ),
                              if (why != null) WhyLine(why, light: on, onTap: () => showWhyWindow(context, t)),
                            ]),
                          ),
                          Text(fmtDuration(Duration(milliseconds: t.durationMs)), style: TextStyle(fontSize: 12.5, color: on ? const Color(0xFFDFE8FF) : const Color(0xFF888888))),
                        ]),
                      ),
                      ),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          act(XpIcons.play, sel != null && ps.failureOf(q[sel]) != null ? 'De novo' : 'Tocar', sel == null
              ? null
              : () {
                  if (ps.failureOf(q[sel]) != null) {
                    ps.retry(q[sel]);
                  } else {
                    ps.jumpTo(sel);
                  }
                  Navigator.pop(context);
                }),
          act(XpIcons.bin, 'Tirar', sel == null || sel == cur ? null : () => ps.removeAt(sel).then((_) => mounted ? setState(() => _sel = null) : null)),
          act(XpIcons.shuffle, 'Embaralhar', ps.upcoming.length < 2 ? null : ps.shuffleUpcoming),
          act(XpIcons.plus, 'Salvar', q.isEmpty ? null : () => _save(q)),
        ]),
      ),
      Builder(builder: (_) {
        final failed = q.where((t) => ps.failureOf(t) != null).length;
        return XpStatusBar(warn: failed > 0, [
          if (failed > 0)
            failed == 1 ? '1 música não abriu · segure para ver opções' : '$failed músicas não abriram · segure para ver opções'
          else
            sel == null ? 'Toque numa música para escolher; dois toques para tocar' : 'Escolhida: ${q[sel].title}',
          cur == null ? '' : 'Tocando ${cur + 1} de ${q.length}',
        ]);
      }),
    ]);
  }

  /// Música que não abriu: cinza, riscada, com ⚠ e o motivo embaixo. Segurar abre as opções.
  Widget _failedRow(PlayerService ps, Track t, int i, PlaybackFailure bad, bool picked) => GestureDetector(
        onLongPressStart: (d) => _failedMenu(ps, t, i, d.globalPosition),
        child: InkWell(
          onTap: () => setState(() => _sel = i),
          child: Container(
            decoration: BoxDecoration(
              color: picked ? const Color(0xFFDCE7FB) : const Color(0xFFFAFAFA),
              border: Border(bottom: const BorderSide(color: Color(0xFFF0F0F0)), left: BorderSide(color: picked ? Xp.select : Colors.transparent, width: 3)),
            ),
            padding: const EdgeInsets.only(right: 8),
            child: Row(children: [
              SizedBox(width: 34, child: Text('${i + 1}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: Color(0xFFAAAAAA)))),
              const SizedBox(width: 6),
              const XpIcon(XpIcons.warning, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${t.title}  ${t.artist}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, color: Color(0xFF9A9A9A), decoration: TextDecoration.lineThrough, decorationColor: Color(0xFF9A9A9A))),
                  Text('Não abre · ${bad.reasonText}', style: const TextStyle(fontSize: 11, color: Xp.red)),
                ]),
              ),
              const Text('--:--', style: TextStyle(fontSize: 12.5, color: Color(0xFFAAAAAA))),
            ]),
          ),
        ),
      );
}

/// A "capa" do Tocando agora: vários GIFs que se alternam a cada 8 s.
class GifCarousel extends StatefulWidget {
  final Track track;
  const GifCarousel({super.key, required this.track});

  @override
  State<GifCarousel> createState() => _GifCarouselState();
}

class _GifCarouselState extends State<GifCarousel> with WidgetsBindingObserver {
  static const interval = Duration(seconds: 8);
  /// O que passa na roda: GIFs com a capa e as fotos do artista no meio.
  List<String> _gifs = const [];

  /// Só os GIFs (salvos, emprestados do mesmo clima e do GIPHY), sem as fotos.
  List<String> _base = const [];
  List<String> _extras = const [];
  Uint8List? _cover;
  int _i = 0;
  Timer? _timer;
  DateTime _shownAt = DateTime.now();
  late final GifService _gifService;

  /// Miniatura leve de cada GIF do GIPHY (endereço do GIF -> endereço da miniatura).
  final Map<String, String> _thumbOf = {};
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _gifService = app.gifs;
    _epoch = app.visualsEpoch;
    _gifService.addListener(_onGifsChanged);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// App visível na tela (ou só com a cortina de notificações por cima).
  static bool _onScreen(AppLifecycleState? s) => s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  /// Tela desligada ou app minimizado: a roda para (sem trocar GIF nem a imagem da notificação a cada 8 s,
  /// o que gastava bateria à toa). Ao voltar, continua do GIF em que estava, com os 8 s contando do zero.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_onScreen(state)) {
      if (_timer == null) {
        _shownAt = DateTime.now();
        _restartTimer();
      }
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void didUpdateWidget(GifCarousel old) {
    super.didUpdateWidget(old);
    // clima mudou: os GIFs do GIPHY mudam junto
    if (old.track.mood != widget.track.mood) _load();
  }

  static bool _isWeb(String s) => s.startsWith('http');

  /// Mostra um GIF salvo (arquivo) ou do GIPHY (internet).
  Widget _image(String src, {Key? key, int? cacheWidth, bool thumb = false}) {
    Widget err(BuildContext _, Object _, StackTrace? _) => const ColoredBox(color: Colors.black26);
    if (_isWeb(src)) {
      return Image.network(thumb ? (_thumbOf[src] ?? src) : src,
          key: key, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: cacheWidth, errorBuilder: err);
    }
    return Image.file(File(src), key: key, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: cacheWidth, errorBuilder: err);
  }

  int _lastCount = -1;
  int _lastBorrowed = -1;
  void _onGifsChanged() {
    // recarrega quando chegam GIFs novos (download em segundo plano) ou GIFs emprestados (plano B)
    final borrowed = context.read<AppState>().gifFetcher.borrowed[widget.track.id]?.length ?? 0;
    if (_gifService.count != _lastCount || borrowed != _lastBorrowed) {
      _load();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    _lastCount = app.gifs.count;
    // podcast: por enquanto só a capa do episódio (os GIFs de "estúdio de rádio" vêm numa fase própria)
    final pod = app.isSpoken(widget.track);
    final own = pod ? const <String>[] : await app.gifs.gifsFor(widget.track);
    // plano B: serviço de GIFs fora do ar -> completa com GIFs guardados do mesmo clima
    final lend = pod ? const <String>[] : app.gifFetcher.borrowed[widget.track.id] ?? const <String>[];
    _lastBorrowed = lend.length;
    final gifs = [...own, ...lend.where((g) => !own.contains(g))].take(maxGifsPerTrack).toList();
    final extras = pod ? const <String>[] : app.gifExtrasFor(widget.track);
    Uint8List? cover;
    if (pod) {
      // podcast: a miniatura do vídeo do episódio; enquanto não tem, o ícone do programa
      final thumb = app.programArt.episodeThumb(widget.track.path);
      cover = await thumb?.readAsBytes() ?? await app.programArt.fileFor(AppState.programDirOf(widget.track))?.readAsBytes();
      if (thumb == null) {
        final track = widget.track;
        app.programArt.ensureEpisodeThumb(track.path, app.youtubeIdOf(track)).then((ok) {
          if (ok && mounted && widget.track.id == track.id) _load();
        });
      }
      cover ??= await app.metadata.cover(widget.track.path);
    } else if (gifs.isEmpty && extras.isEmpty) {
      cover = await app.covers.fileFor(widget.track)?.readAsBytes() ?? await app.metadata.cover(widget.track.path);
    }
    if (!mounted) return;
    final showing = _gifs.isEmpty ? null : _gifs[_i.clamp(0, _gifs.length - 1)];
    setState(() {
      _base = gifs;
      _extras = extras;
      _gifs = mixExtras(gifs, extras);
      _cover = cover;
      // continua no mesmo GIF quando a roda só ganhou itens novos
      final k = showing == null ? -1 : _gifs.indexOf(showing);
      _i = k < 0 ? 0 : k;
      if (k < 0) _shownAt = DateTime.now();
    });
    app.nowShowingGif(widget.track, _gifs.isEmpty ? null : _gifs[_i]);
    _restartTimer();
    _addWeb(gifs);
  }

  /// Junta os GIFs do GIPHY (em segundo plano) aos salvos, conforme a fonte escolhida.
  Future<void> _addWeb(List<String> local) async {
    final app = context.read<AppState>();
    final track = widget.track;
    final web = await app.playerVisualsFor(track);
    if (!mounted || web.isEmpty || track.id != widget.track.id) return;
    for (final r in web) {
      _thumbOf[r.gif.url] = r.gif.previewUrl;
    }
    final urls = [for (final r in web) r.gif.url];
    // usa os salvos que estão na roda agora (podem ter chegado GIFs novos enquanto o GIPHY respondia)
    local = [for (final g in _base) if (!_isWeb(g)) g];
    final merged = switch (app.gifSource) {
      GifSource.anime => local,
      GifSource.giphy => interleave([urls, local]),
      GifSource.auto => interleave([local, urls]), // anime primeiro, depois alterna
    };
    final showing = _gifs.isEmpty ? null : _gifs[_i];
    setState(() {
      _base = merged;
      _gifs = mixExtras(merged, _extras);
      final k = showing == null ? -1 : _gifs.indexOf(showing);
      _i = k < 0 ? 0 : k;
    });
    _restartTimer();
  }

  /// Anda a cada 250 ms: só a barrinha de tempo e o "troca em X s" se redesenham com ela
  /// (antes a roda inteira, com o GIF grande e as miniaturas, era refeita 4 vezes por segundo).
  final ValueNotifier<int> _tick = ValueNotifier(0);

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    if (_gifs.length > 1 && _onScreen(WidgetsBinding.instance.lifecycleState)) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        if (DateTime.now().difference(_shownAt) >= interval) {
          _go(_i + 1);
        } else {
          _tick.value++;
        }
      });
    }
  }

  void _go(int i) {
    setState(() {
      _i = i % _gifs.length;
      _shownAt = DateTime.now();
    });
    context.read<AppState>().nowShowingGif(widget.track, _gifs[_i]);
  }

  @override
  void dispose() {
    _gifService.removeListener(_onGifsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double elapsed() => DateTime.now().difference(_shownAt).inMilliseconds / interval.inMilliseconds;
    int remaining() => (interval.inSeconds - DateTime.now().difference(_shownAt).inSeconds).clamp(0, interval.inSeconds);
    // limite de decodificação do GIF grande: 2x a largura da tela em pixels. Fotos enormes escolhidas do
    // celular (4000 px) deixam de ocupar dezenas de MB; GIFs normais, e até os bem largos que a moldura
    // corta dos lados, ficam do tamanho original (sem perder nitidez)
    final fullWidth = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context) * 2).round();
    final app = context.read<AppState>();
    final epoch = context.select<AppState, int>((a) => a.visualsEpoch);
    if (epoch != _epoch) {
      // chave ou fonte do GIPHY mudou
      _epoch = epoch;
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _load() : null);
    }
    final fetching = app.gifFetcher.isFetching(widget.track);
    final pod = app.isSpoken(widget.track);
    return Column(children: [
      GestureDetector(
        onTap: _gifs.length > 1
            ? () => _go(_i + 1)
            : (_gifs.isEmpty && !fetching && !pod ? () => app.gifFetcher.fetchFor(widget.track, force: true) : null),
        onLongPress: pod ? null : () => showGifManager(context, widget.track).then((_) => _load()),
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          height: 270,
          decoration: const BoxDecoration(
            color: Colors.black,
            border: Border(
              top: BorderSide(color: Color(0xFF808080), width: 2),
              left: BorderSide(color: Color(0xFF808080), width: 2),
              right: BorderSide(color: Colors.white, width: 2),
              bottom: BorderSide(color: Colors.white, width: 2),
            ),
          ),
          child: Stack(fit: StackFit.expand, children: [
            if (_gifs.isNotEmpty)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: _image(_gifs[_i], key: ValueKey(_gifs[_i]), cacheWidth: fullWidth),
              )
            else if (_cover != null)
              Image.memory(_cover!, fit: BoxFit.cover, cacheWidth: fullWidth)
            else
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                      pod
                          ? '🎙 Podcast\n${widget.track.artist}'
                          : fetching
                              ? 'Procurando GIFs de "${widget.track.title}"...'
                              : 'Sem GIFs para esta música.\nToque para buscar na internet, ou segure para escolher do celular.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF99FFFF), fontSize: 13)),
                ),
              ),
            if (!pod) Positioned(left: 6, top: 6, child: MoodBadge(track: widget.track)),
            if (pod) EpisodeBalloon(track: widget.track),
            if (fetching && _gifs.isNotEmpty)
              Positioned(
                left: 6,
                top: 40,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: const Text('Baixando GIFs...', style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            if (_gifs.isNotEmpty && app.extraLabel(widget.track, _gifs[_i]) != null)
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(app.extraLabel(widget.track, _gifs[_i])!, style: const TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ),
            if (_gifs.isNotEmpty && _isWeb(_gifs[_i]))
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: const Text('via GIPHY', style: TextStyle(color: Colors.white, fontSize: 10)),
                ),
              ),
            if (_gifs.length > 1)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: ValueListenableBuilder<int>(
                    valueListenable: _tick,
                    builder: (_, _, _) => Text('${_i + 1} de ${_gifs.length} · troca em ${remaining()} s',
                        style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ),
              ),
          ]),
        ),
      ),
      if (_gifs.length > 1) ...[
        SizedBox(
          height: 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: _gifs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 5),
            itemBuilder: (_, k) {
              final on = k == _i;
              return GestureDetector(
                onTap: () => _go(k),
                child: Opacity(
                  opacity: on ? 1 : .55,
                  child: Container(
                    width: on ? 62 : 54,
                    decoration: BoxDecoration(border: Border.all(color: on ? Xp.navy : const Color(0xFF7A96C9), width: on ? 2 : 1)),
                    child: _image(_gifs[k], cacheWidth: 120, thumb: true),
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          height: 3,
          color: const Color(0xFFB9C9E6),
          alignment: Alignment.centerLeft,
          child: ValueListenableBuilder<int>(
            valueListenable: _tick,
            builder: (_, _, _) => FractionallySizedBox(widthFactor: elapsed().clamp(0.0, 1.0), child: Container(color: Xp.navy)),
          ),
        ),
      ],
    ]);
  }
}

Future<void> showGifManager(BuildContext context, Track t) async {
  final app = context.read<AppState>();
  if (app.sourceRoot == null || t.id == null) return;
  final parsedTitle = parseFileName(t.title).title;
  final extras = TextEditingController(text: app.gifs.songExtras(t.artist, parsedTitle));
  final artistExtras = TextEditingController(text: app.gifs.artistExtras(t.artist));
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Xp.bgTop,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
      Future<void> saveExtras() async {
        await app.gifs.setSongExtras(t.artist, parsedTitle, extras.text);
        await app.gifs.setArtistExtras(t.artist, artistExtras.text);
      }

      // palavras novas: já baixa uns GIFs para elas (pedido do usuário)
      Future<void> saveKeywords() async {
        messenger.showSnackBar(const SnackBar(content: Text('Palavras salvas. Baixando GIFs para elas...')));
        final n = await app.saveKeywords(t, song: extras.text, artist: artistExtras.text);
        messenger.showSnackBar(SnackBar(content: Text(n > 0 ? '$n GIFs novos pelas suas palavras.' : 'Palavras salvas. Não achei GIF novo agora.')));
        setSt(() {});
      }

      return FutureBuilder<(List<String>, List<String>)>(
        future: () async {
          final pinned = (await app.db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
          final all = await app.gifs.gifsFor(t, max: 60);
          return (pinned, [...pinned, ...all.where((g) => !pinned.contains(g))]);
        }(),
        builder: (ctx, snap) {
          final pinned = snap.data?.$1 ?? const <String>[];
          final gifs = snap.data?.$2 ?? const <String>[];
          final fetching = app.gifFetcher.isFetching(t);
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * .8,
              child: Column(children: [
                XpTitleBar(title: 'GIFs de "$parsedTitle"'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                  child: Row(children: [
                    Expanded(
                      child: XpButton(
                        label: fetching ? 'Baixando...' : 'Baixar sozinho',
                        icon: Icons.cloud_download_outlined,
                        primary: true,
                        onTap: fetching
                            ? null
                            : () async {
                                await saveExtras();
                                setSt(() {});
                                final n = await app.gifFetcher.fetchFor(t, force: true);
                                messenger.showSnackBar(SnackBar(
                                    content: Text(n == 0
                                        ? (pinned.length >= maxGifsPerTrack
                                            ? 'Esta música já tem $maxGifsPerTrack GIFs. Solte algum para baixar outros.'
                                            : 'Nada novo nas fontes livres. Tente "Buscar na web".')
                                        : '$n GIFs baixados.')));
                                setSt(() {});
                              },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: XpButton(
                        label: 'Buscar na web',
                        icon: Icons.travel_explore,
                        onTap: () async {
                          await saveExtras();
                          await nav.push(MaterialPageRoute<void>(builder: (_) => GifWebScreen(track: t)));
                          setSt(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    XpButton(
                      label: '',
                      icon: Icons.add_photo_alternate_outlined,
                      onTap: () async {
                        final res = await FilePicker.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: const ['gif', 'webp', 'png', 'jpg', 'jpeg'],
                        );
                        final paths = res.map((f) => f.path).whereType<String>().toList();
                        if (paths.isEmpty) return;
                        await app.gifs.importForTrack(t, paths);
                        setSt(() {});
                      },
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
                  child: SizedBox(
                    width: double.infinity,
                    child: XpButton(
                      label: 'GIFs pela vibe da música',
                      icon: Icons.music_note,
                      onTap: () async {
                        await saveExtras();
                        await nav.push(MaterialPageRoute<void>(builder: (_) => GifVibeScreen(track: t)));
                        setSt(() {});
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: TextField(
                    controller: extras,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => saveKeywords(),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      labelText: 'Palavras desta música (ex.: rock lee vs gaara)',
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: artistExtras,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => saveKeywords(),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white,
                          border: const OutlineInputBorder(),
                          labelText: 'Palavras do artista (todas as músicas de ${t.artist})',
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    XpButton(label: 'Salvar', icon: Icons.check, onTap: saveKeywords),
                  ]),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 2, 12, 2),
                  child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 2, children: [
                    _SourceTag(manual: true),
                    Text(' escolhido por você   ', style: TextStyle(fontSize: 11, color: Xp.blueText)),
                    _SourceTag(manual: false),
                    Text(' baixado sozinho   👎 não combina', style: TextStyle(fontSize: 11, color: Xp.blueText)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                      'Fixados: ${pinned.length} de $maxGifsPerTrack. Os GIFs ficam na pasta GIFs e funcionam sem internet. '
                      '📌 fixa ou solta; 👎 tira e o GIF nunca mais volta sozinho; 🗑 só tira desta música.',
                      style: const TextStyle(fontSize: 12, color: Xp.blueText)),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(10),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: gifs.length,
                    itemBuilder: (ctx, i) {
                      final g = gifs[i];
                      final isPinned = pinned.contains(g);
                      Widget act(IconData icon, String tip, VoidCallback onTap, {bool on = false}) => Expanded(
                            child: Tooltip(
                              message: tip,
                              child: InkWell(
                                onTap: onTap,
                                child: Container(
                                  color: on ? const Color(0xFFFFD400) : Colors.transparent,
                                  padding: const EdgeInsets.symmetric(vertical: 3),
                                  child: Icon(icon, size: 16, color: on ? Colors.black : Colors.white),
                                ),
                              ),
                            ),
                          );
                      return Stack(fit: StackFit.expand, children: [
                        Image.file(File(g), fit: BoxFit.cover, cacheWidth: 240, errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26)),
                        Positioned(left: 3, top: 3, child: _SourceTag(manual: !GifService.isAuto(g))),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            color: Colors.black54,
                            child: Row(children: [
                              act(Icons.push_pin, isPinned ? 'Soltar da música' : 'Fixar na música', () async {
                                if (isPinned) {
                                  await app.db.unpinGif(t.id!, g);
                                } else if (pinned.length < maxGifsPerTrack) {
                                  await app.db.pinGif(t.id!, g);
                                } else {
                                  messenger.showSnackBar(const SnackBar(content: Text('Máximo de $maxGifsPerTrack GIFs por música.')));
                                }
                                app.gifs.changed();
                                setSt(() {});
                              }, on: isPinned),
                              act(Icons.thumb_down_alt_outlined, 'Não combina (nunca mais volta sozinho)', () async {
                                await app.rejectGif(t, g);
                                messenger.showSnackBar(const SnackBar(content: Text('Não combina: tirei e ele não volta mais sozinho.')));
                                setSt(() {});
                              }),
                              act(Icons.delete_outline, 'Tirar desta música', () async {
                                await app.gifs.deleteGif(g, trackId: t.id);
                                setSt(() {});
                              }),
                            ]),
                          ),
                        ),
                      ]);
                    },
                  ),
                ),
              ]),
            ),
          );
        },
      );
    }),
  );
  await app.gifs.setSongExtras(t.artist, parsedTitle, extras.text);
  await app.gifs.setArtistExtras(t.artist, artistExtras.text);
}

/// Etiqueta de origem do GIF: "VOCÊ" (escolhido pelo usuário) ou "AUTO" (baixado sozinho).
class _SourceTag extends StatelessWidget {
  final bool manual;
  const _SourceTag({required this.manual});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(color: manual ? const Color(0xFF1D7A2A) : const Color(0xFF55688F), borderRadius: BorderRadius.circular(3)),
        child: Text(manual ? 'VOCÊ' : 'AUTO', style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold)),
      );
}

class SeekBar extends StatelessWidget {
  final AudioPlayer player;

  /// Seek do usuário (passa pelo PlayerService para interromper uma transição em andamento).
  final Future<void> Function(Duration)? onSeek;

  /// Riscos amarelos (início de cada capítulo do podcast).
  final List<Duration> marks;
  const SeekBar({super.key, required this.player, this.onSeek, this.marks = const []});

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
    stream: player.positionStream,
    builder: (context, snap) {
      final pos = snap.data ?? Duration.zero;
      final dur = player.duration ?? Duration.zero;
      final max = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFF1C56D0),
            inactiveTrackColor: const Color(0xFFD4D0C8),
            thumbColor: const Color(0xFFF4F6FB),
            overlayColor: const Color(0x221C56D0),
            trackHeight: 5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 2),
            trackShape: const RectangularSliderTrackShape(),
          ),
          child: Stack(alignment: Alignment.center, children: [
            Slider(
              value: pos.inMilliseconds.toDouble().clamp(0, max),
              max: max,
              onChanged: (v) => (onSeek ?? player.seek)(Duration(milliseconds: v.round())),
            ),
            if (marks.isNotEmpty) Positioned.fill(child: ChapterMarks(marks: marks, total: dur)),
          ]),
        ),
      );
    },
  );
}

/// Selo no canto do GIF: mostra o clima da música e abre a lista para trocar.
/// Escolher um clima troca os GIFs de anime, põe a música na playlist do clima e guia o mix "da mesma vibe".
class MoodBadge extends StatelessWidget {
  final Track track;
  const MoodBadge({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final chosen = track.chosenMood;
    final auto = track.autoMood;
    final label = chosen == null ? '✨ Auto' : '${chosen.emoji} ${chosen.label}';
    return PopupMenuButton<String>(
      tooltip: 'Clima dos GIFs',
      position: PopupMenuPosition.under,
      onSelected: (v) async {
        final app = context.read<AppState>();
        final messenger = ScaffoldMessenger.of(context);
        final mood = Mood.byName(v);
        await app.setMood(track, mood);
        messenger.showSnackBar(SnackBar(
          content: Text(mood == null
              ? 'Clima automático. Buscando GIFs novos...'
              : 'Clima: ${mood.label}. A música foi para a playlist "${mood.label}". Buscando GIFs novos...'),
        ));
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'auto',
          checked: chosen == null,
          child: Text(auto == null ? '✨ Auto (neutro)' : '✨ Auto (${auto.label})'),
        ),
        for (final m in Mood.values)
          CheckedPopupMenuItem(value: m.name, checked: chosen == m, child: Text('${m.emoji} ${m.label}')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .62),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white38),
        ),
        child: Text('$label ▾', style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
