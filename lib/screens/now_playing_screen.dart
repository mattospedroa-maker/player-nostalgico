import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../audio_handler.dart';
import '../filename_parser.dart';
import '../gif_fetcher.dart';
import '../gif_service.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets.dart';
import 'edit_track_screen.dart';
import 'gif_web_screen.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ps = context.watch<PlayerService>();
    final app = context.watch<AppState>();
    final t = ps.current == null ? null : (app.byId(ps.current!.id) ?? ps.current);
    return Column(children: [
      const XpTitleBar(title: 'Tocando agora'),
      Expanded(
        child: t == null
            ? const EmptyHint(Icons.music_off, 'Nada tocando.\nEscolha uma música na Biblioteca.')
            : ListView(padding: EdgeInsets.zero, children: [
                GifCarousel(key: ValueKey(t.id), track: t),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Xp.navy)),
                    Text(t.artist, style: const TextStyle(fontSize: 14, color: Xp.blueText)),
                    Text([t.album, if ((t.year ?? 0) > 0) '${t.year}'].join(' · '),
                        style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
                    if (audioInitError != null)
                      Text('Notificação desligada: $audioInitError', style: const TextStyle(fontSize: 11, color: Xp.red)),
                  ]),
                ),
                SeekBar(player: ps.player),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: GlossyBar(children: [
                    GlossyButton(icon: Icons.shuffle, active: ps.shuffle, onTap: ps.toggleShuffle, tooltip: 'Aleatório'),
                    GlossyButton(icon: Icons.skip_previous, onTap: ps.previous, tooltip: 'Anterior'),
                    GlossyButton(icon: ps.playing ? Icons.pause : Icons.play_arrow, size: 64, onTap: ps.togglePlay),
                    GlossyButton(icon: Icons.skip_next, onTap: ps.next, tooltip: 'Próxima'),
                    GlossyButton(
                      icon: ps.loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                      active: ps.loop != LoopMode.off,
                      onTap: ps.cycleLoop,
                      tooltip: 'Repetir',
                    ),
                  ]),
                ),
                _Toolbar(track: t),
                const SizedBox(height: 16),
              ]),
      ),
    ]);
  }
}

class _Toolbar extends StatelessWidget {
  final Track track;
  const _Toolbar({required this.track});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    Widget item(IconData i, String label, VoidCallback onTap, {bool on = false}) => Expanded(
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Icon(i, size: 20, color: on ? Xp.red : Colors.black87),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(fontSize: 11, color: on ? Xp.red : Colors.black87, fontWeight: on ? FontWeight.bold : FontWeight.normal)),
              ]),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      decoration: BoxDecoration(color: Xp.beige, border: Border.all(color: Xp.beigeBorder), borderRadius: BorderRadius.circular(4)),
      child: Row(children: [
        item(track.favorite ? Icons.favorite : Icons.favorite_border, 'Favorita', () => app.toggleFavorite(track), on: track.favorite),
        item(Icons.gif_box_outlined, 'GIFs desta', () => showGifManager(context, track)),
        item(Icons.playlist_add, 'Playlist', () => pickPlaylistAndAdd(context, track)),
        item(Icons.queue_music, 'Fila', () => _showQueue(context)),
        item(Icons.edit_outlined, 'Editar', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EditTrackScreen(track: track)))),
      ]),
    );
  }

  void _showQueue(BuildContext context) {
    final ps = context.read<PlayerService>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Xp.bgTop,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        builder: (ctx, sc) => Column(children: [
          const XpTitleBar(title: 'Fila'),
          Expanded(
            child: ListView.builder(
              controller: sc,
              itemCount: ps.queue.length,
              itemBuilder: (ctx, i) => TrackTile(
                track: ps.queue[i],
                onTap: () {
                  ps.player.seek(Duration.zero, index: i);
                  Navigator.pop(ctx);
                },
                trailing: Text('${i + 1}', style: const TextStyle(color: Xp.blueMuted)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A "capa" do Tocando agora: vários GIFs que se alternam a cada 8 s.
class GifCarousel extends StatefulWidget {
  final Track track;
  const GifCarousel({super.key, required this.track});

  @override
  State<GifCarousel> createState() => _GifCarouselState();
}

class _GifCarouselState extends State<GifCarousel> {
  static const interval = Duration(seconds: 8);
  List<String> _gifs = const [];
  Uint8List? _cover;
  int _i = 0;
  Timer? _timer;
  DateTime _shownAt = DateTime.now();
  late final GifService _gifService;

  @override
  void initState() {
    super.initState();
    _gifService = context.read<AppState>().gifs;
    _gifService.addListener(_onGifsChanged);
    _load();
  }

  int _lastCount = -1;
  void _onGifsChanged() {
    // recarrega quando chegam GIFs novos (download em segundo plano)
    if (_gifService.count != _lastCount) {
      _load();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    _lastCount = app.gifs.count;
    final gifs = await app.gifs.gifsFor(widget.track);
    Uint8List? cover;
    if (gifs.isEmpty) cover = await app.metadata.cover(widget.track.path);
    if (!mounted) return;
    setState(() {
      _gifs = gifs;
      _cover = cover;
      _i = 0;
      _shownAt = DateTime.now();
    });
    app.nowShowingGif(widget.track, gifs.isEmpty ? null : gifs.first);
    _timer?.cancel();
    if (gifs.length > 1) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        if (DateTime.now().difference(_shownAt) >= interval) {
          _go(_i + 1);
        } else {
          setState(() {});
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
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(_shownAt).inMilliseconds / interval.inMilliseconds;
    final remaining = (interval.inSeconds - DateTime.now().difference(_shownAt).inSeconds).clamp(0, interval.inSeconds);
    final app = context.read<AppState>();
    final fetching = app.gifFetcher.isFetching(widget.track);
    return Column(children: [
      GestureDetector(
        onTap: _gifs.length > 1
            ? () => _go(_i + 1)
            : (_gifs.isEmpty && !fetching ? () => app.gifFetcher.fetchFor(widget.track, force: true) : null),
        onLongPress: () => showGifManager(context, widget.track).then((_) => _load()),
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          height: 250,
          decoration: BoxDecoration(color: Colors.black, border: Border.all(color: const Color(0xFF0B2F7A), width: 2)),
          child: Stack(fit: StackFit.expand, children: [
            if (_gifs.isNotEmpty)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Image.file(File(_gifs[_i]), key: ValueKey(_gifs[_i]), fit: BoxFit.cover, gaplessPlayback: true),
              )
            else if (_cover != null)
              Image.memory(_cover!, fit: BoxFit.cover)
            else
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                      fetching
                          ? 'Procurando GIFs de "${widget.track.title}"...'
                          : 'Sem GIFs para esta música.\nToque para buscar na internet, ou segure para escolher do celular.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF99FFFF), fontSize: 13)),
                ),
              ),
            if (fetching && _gifs.isNotEmpty)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: const Text('Baixando GIFs...', style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            if (_gifs.length > 1)
              Positioned(
                right: 6,
                bottom: 6,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text('GIF ${_i + 1} de ${_gifs.length} · troca em $remaining s',
                      style: const TextStyle(color: Colors.white, fontSize: 11)),
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
                    child: Image.file(File(_gifs[k]), fit: BoxFit.cover, cacheWidth: 120, errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26)),
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
          child: FractionallySizedBox(widthFactor: elapsed.clamp(0.0, 1.0), child: Container(color: Xp.navy)),
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
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Xp.bgTop,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
      Future<void> saveExtras() => app.gifs.setSongExtras(t.artist, parsedTitle, extras.text);
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
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: TextField(
                    controller: extras,
                    onSubmitted: (_) => saveExtras(),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(),
                      labelText: 'Palavras extras para buscar (ex.: rock lee vs gaara)',
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                      'Fixados: ${pinned.length} de $maxGifsPerTrack. Os GIFs ficam na pasta GIFs e funcionam sem internet. '
                      'Alfinete fixa ou solta; lixeira tira da música (o arquivo só é apagado se nenhuma outra música usa).',
                      style: const TextStyle(fontSize: 12, color: Xp.blueText)),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(10),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: gifs.length,
                    itemBuilder: (ctx, i) {
                      final isPinned = pinned.contains(gifs[i]);
                      return Stack(fit: StackFit.expand, children: [
                        Image.file(File(gifs[i]), fit: BoxFit.cover, cacheWidth: 240),
                        Positioned(
                          right: 2,
                          top: 2,
                          child: GestureDetector(
                            onTap: () async {
                              if (isPinned) {
                                await app.db.unpinGif(t.id!, gifs[i]);
                              } else if (pinned.length < maxGifsPerTrack) {
                                await app.db.pinGif(t.id!, gifs[i]);
                              } else {
                                messenger.showSnackBar(const SnackBar(content: Text('Máximo de $maxGifsPerTrack GIFs por música.')));
                              }
                              app.gifs.changed();
                              setSt(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              color: isPinned ? const Color(0xFFFFD400) : Colors.black45,
                              child: Icon(Icons.push_pin, size: 16, color: isPinned ? Colors.black : Colors.white),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 2,
                          top: 2,
                          child: GestureDetector(
                            onTap: () async {
                              await app.gifs.deleteGif(gifs[i], trackId: t.id);
                              setSt(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              color: Colors.black45,
                              child: const Icon(Icons.delete_outline, size: 16, color: Colors.white),
                            ),
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
}

class SeekBar extends StatelessWidget {
  final AudioPlayer player;
  const SeekBar({super.key, required this.player});

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: player.positionStream,
        builder: (context, snap) {
          final pos = snap.data ?? Duration.zero;
          final dur = player.duration ?? Duration.zero;
          final max = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Column(children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Xp.navy,
                  inactiveTrackColor: Colors.white,
                  thumbColor: const Color(0xFFDCE6F7),
                  trackHeight: 6,
                ),
                child: Slider(
                  value: pos.inMilliseconds.toDouble().clamp(0, max),
                  max: max,
                  onChanged: (v) => player.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(fmtDuration(pos), style: const TextStyle(fontSize: 11, color: Xp.blueText)),
                  Text(fmtDuration(dur), style: const TextStyle(fontSize: 11, color: Xp.blueText)),
                ]),
              ),
            ]),
          );
        },
      );
}
