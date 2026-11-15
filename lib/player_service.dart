import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

import 'audio_handler.dart';
import 'gif_fetcher.dart' show GifFetcher;
import 'db.dart';
import 'models.dart';

/// O que tocar quando a fila acaba.
enum MixMode { artist, vibe }

/// Toca a fila de músicas e registra o histórico (usado pela recomendação).
class PlayerService extends ChangeNotifier {
  final AppDb db;
  final AudioPlayer player = AudioPlayer();
  List<Track> _queue = const [];
  int? _index;
  DateTime? _startedAt;
  int? _startedTrackId;
  final _subs = <StreamSubscription>[];
  List<Track> _original = const [];
  bool _shuffle = false;
  bool _fromMix = false;
  final _rnd = Random();

  /// Biblioteca inteira (o AppState preenche), para montar o mix automático.
  List<Track> Function() library = () => const [];

  /// Músicas que entraram sozinhas pelo mix (podem ser trocadas quando o modo muda).
  final Set<Track> _autoAdded = Set.identity();
  MixMode mixMode = MixMode.vibe;
  void Function(MixMode)? onMixModeChanged;

  /// Próximas músicas (para mostrar "A seguir").
  List<Track> get upcoming => _index == null || _nextPos >= _queue.length ? const [] : _queue.sublist(_nextPos);

  final PlayerAudioHandler? handler;

  PlayerService(this.db, {this.handler}) {
    handler
      ?..player = player
      ..onNext = next
      ..onPrevious = previous;
    _subs.add(player.playbackEventStream.listen((_) => handler?.broadcast(), onError: (_, _) {}));
    _subs.add(player.playingStream.listen((_) => handler?.broadcast()));
    _subs.add(player.currentIndexStream.listen((i) {
      _logCurrent(skipped: false);
      _index = i;
      _startedAt = DateTime.now();
      _startedTrackId = current?.id;
      _publishMediaItem();
      notifyListeners();
      unawaited(_extendMix());
    }));
    _subs.add(player.playerStateStream.listen((_) => notifyListeners()));
    _subs.add(player.loopModeStream.listen((_) => notifyListeners()));
  }

  List<Track> get queue => _queue;
  Track? get current => (_index != null && _index! < _queue.length) ? _queue[_index!] : null;
  bool get playing => player.playing;
  bool get shuffle => _shuffle;

  /// Fila que se adapta: aleatório ou "Mix do momento". Pular afasta parecidas; favoritar aproxima.
  bool get adaptive => _shuffle || _fromMix;
  LoopMode get loop => player.loopMode;

  Future<void> playQueue(List<Track> tracks, {int start = 0, bool mix = false}) async {
    if (tracks.isEmpty) return;
    _logCurrent(skipped: true);
    _fromMix = mix;
    _original = List.of(tracks);
    _queue = List.of(tracks);
    if (_shuffle) {
      final first = _queue.removeAt(start.clamp(0, _queue.length - 1));
      _queue.shuffle(_rnd);
      _queue.insert(0, first);
      start = 0;
    }
    final sources = [for (final t in _queue) _source(t)];
    await player.setAudioSources(sources, initialIndex: start.clamp(0, sources.length - 1));
    _index = player.currentIndex;
    _autoAdded.clear();
    _publishMediaItem();
    unawaited(_extendMix());
    unawaited(player.play());
    notifyListeners();
  }

  AudioSource _source(Track t) => AudioSource.file(t.path, tag: t);

  /// Nome, artista e duração na notificação / tela de bloqueio.
  void _publishMediaItem() {
    final t = current;
    final h = handler;
    if (t == null || h == null) return;
    h.queue.add([for (final q in _queue) MediaItem(id: q.path, title: q.title, artist: q.artist)]);
    h.mediaItem.add(MediaItem(
      id: t.path,
      title: t.title,
      artist: t.artist == unknownArtist ? null : t.artist,
      album: t.album == unknownAlbum ? null : t.album,
      genre: t.genre.isEmpty ? null : t.genre,
      duration: t.durationMs > 0 ? Duration(milliseconds: t.durationMs) : null,
      artUri: h.art[t.path],
    ));
    h.broadcast();
  }

  Future<void> togglePlay() => player.playing ? player.pause() : player.play();

  Future<void> next() async {
    final skipped = current;
    _logCurrent(skipped: true);
    _startedTrackId = null;
    await player.seekToNext();
    if (skipped != null && adaptive) await pushSimilarBack(skipped);
  }

  /// Troca o tipo de mix na hora: as músicas que o mix colocou são refeitas; a atual continua.
  Future<void> setMixMode(MixMode m) async {
    if (m == mixMode) return;
    mixMode = m;
    onMixModeChanged?.call(m);
    // tira as que vieram do mix (de trás para frente) e monta de novo
    for (var i = _queue.length - 1; i >= _nextPos; i--) {
      if (_autoAdded.contains(_queue[i])) {
        _autoAdded.remove(_queue[i]);
        _queue.removeAt(i);
        await player.removeAudioSourceAt(i);
      }
    }
    await _extendMix(force: true);
    notifyListeners();
  }

  bool _extending = false;

  /// Quando faltam poucas músicas, completa a fila com o mix (a música nunca para).
  Future<void> _extendMix({bool force = false}) async {
    final seed = current;
    if (seed == null || _extending || player.loopMode != LoopMode.off) return;
    if (!force && _queue.length - _nextPos >= 3) return;
    _extending = true;
    try {
      final picks = pickMix(seed, library(), mode: mixMode, exclude: _queue.map((t) => t.id).toSet(), count: 10, rnd: _rnd);
      if (picks.isEmpty) return;
      await player.addAudioSources([for (final t in picks) _source(t)]);
      _queue.addAll(picks);
      _autoAdded.addAll(picks);
      notifyListeners();
    } catch (_) {
      // fila mudou no meio: tenta na próxima troca de música
    } finally {
      _extending = false;
    }
  }

  /// Escolhe músicas para o mix. "Do mesmo artista": só o artista (se acabar, completa com a vibe).
  /// "Da mesma vibe": mesmo gênero / mesmo clima, misturando artistas (no máximo 2 de cada).
  static List<Track> pickMix(Track seed, List<Track> library,
      {required MixMode mode, Set<int?> exclude = const {}, int count = 10, Random? rnd}) {
    final r = rnd ?? Random();
    final pool = library.where((t) => t.id != seed.id && !exclude.contains(t.id)).toList()..shuffle(r);
    final out = <Track>[];
    if (mode == MixMode.artist && seed.artist != unknownArtist) {
      out.addAll(pool.where((t) => t.artist == seed.artist).take(count));
    }
    if (out.length < count) {
      final seedMood = GifFetcher.moodCategories(seed.genre).join();
      final seedMain = seed.genre.toLowerCase().split(RegExp(r'[\s/,;-]+')).where((w) => w.length > 1).lastOrNull ?? '';
      double vibe(Track t) {
        var v = 0.0;
        final g = t.genre.toLowerCase();
        if (g.isNotEmpty && g == seed.genre.toLowerCase()) v += 3;
        if (seedMain.isNotEmpty && g.contains(seedMain)) v += 1.5;
        if (seedMood.isNotEmpty && GifFetcher.moodCategories(t.genre).join() == seedMood) v += 1;
        if (t.artist == seed.artist && t.artist != unknownArtist) v += 1;
        if (t.favorite) v += .5;
        return v + r.nextDouble(); // um pouco de sorte para variar
      }

      final ranked = pool.where((t) => !out.contains(t)).toList()..sort((a, b) => vibe(b).compareTo(vibe(a)));
      final perArtist = <String, int>{};
      for (final t in out) {
        perArtist[t.artist] = (perArtist[t.artist] ?? 0) + 1;
      }
      for (final t in ranked) {
        if (out.length >= count) break;
        final n = perArtist[t.artist] ?? 0;
        if (mode == MixMode.vibe && n >= 2) continue;
        perArtist[t.artist] = n + 1;
        out.add(t);
      }
    }
    return out;
  }

  /// Parecença entre duas músicas: mesmo artista pesa mais, depois gênero e álbum.
  static double similarity(Track a, Track b) {
    var s = 0.0;
    if (a.artist.isNotEmpty && a.artist == b.artist && a.artist != unknownArtist) s += 2;
    if (a.genre.isNotEmpty && a.genre.toLowerCase() == b.genre.toLowerCase()) s += 1;
    if (a.album.isNotEmpty && a.album == b.album && a.album != unknownAlbum) s += .5;
    return s;
  }

  int get _nextPos => (_index ?? -1) + 1;

  /// Depois de pular: as parecidas com a pulada vão para o fim da fila (as mais parecidas por último).
  Future<void> pushSimilarBack(Track skipped) async {
    if (_nextPos >= _queue.length) return;
    final upcoming = _queue.sublist(_nextPos);
    final keep = upcoming.where((t) => similarity(t, skipped) == 0).toList();
    final back = upcoming.where((t) => similarity(t, skipped) > 0).toList()
      ..sort((a, b) => similarity(a, skipped).compareTo(similarity(b, skipped)));
    await _applyUpcoming([...keep, ...back]);
  }

  /// Depois de favoritar: parecidas sobem para logo depois da atual, e entram até 3 parecidas da biblioteca.
  Future<void> pullSimilarForward(Track fav, List<Track> library) async {
    if (_index == null) return;
    final upcoming = _queue.sublist(_nextPos);
    final ids = _queue.map((t) => t.id).toSet();
    final extra = (library.where((t) => !ids.contains(t.id) && similarity(t, fav) > 0).toList()..shuffle(_rnd)).take(3).toList();
    if (extra.isNotEmpty) {
      await player.insertAudioSources(_nextPos, [for (final t in extra) _source(t)]);
      _queue.insertAll(_nextPos, extra);
      upcoming.insertAll(0, extra);
    }
    final near = upcoming.where((t) => similarity(t, fav) > 0).toList()..shuffle(_rnd);
    final rest = upcoming.where((t) => similarity(t, fav) == 0).toList();
    // intercala: parecida, outra, parecida... para não virar só um tipo
    final out = <Track>[];
    while (near.isNotEmpty || rest.isNotEmpty) {
      if (near.isNotEmpty) out.add(near.removeAt(0));
      if (near.isNotEmpty && out.length < 4) out.add(near.removeAt(0));
      if (rest.isNotEmpty) out.add(rest.removeAt(0));
    }
    await _applyUpcoming(out);
    notifyListeners();
  }

  /// Reordena as próximas músicas (a atual não é tocada).
  Future<void> _applyUpcoming(List<Track> desired) async {
    final start = _nextPos;
    for (var i = 0; i < desired.length; i++) {
      final pos = start + i;
      final j = _queue.indexWhere((t) => identical(t, desired[i]), pos);
      if (j < 0 || j == pos) continue;
      await player.moveAudioSource(j, pos);
      _queue.insert(pos, _queue.removeAt(j));
    }
    notifyListeners();
  }

  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3)) return player.seek(Duration.zero);
    await player.seekToPrevious();
  }

  /// Aleatório feito pelo app (para a fila poder se adaptar ao que você pula e curte).
  Future<void> toggleShuffle() async {
    _shuffle = !_shuffle;
    if (_index != null && _nextPos < _queue.length) {
      final upcoming = _queue.sublist(_nextPos);
      if (_shuffle) {
        upcoming.shuffle(_rnd);
      } else {
        final order = {for (var i = 0; i < _original.length; i++) _original[i]: i};
        upcoming.sort((a, b) => (order[a] ?? 1 << 30).compareTo(order[b] ?? 1 << 30));
      }
      await _applyUpcoming(upcoming);
    }
    notifyListeners();
  }

  Future<void> cycleLoop() => player.setLoopMode(switch (player.loopMode) {
        LoopMode.off => LoopMode.all,
        LoopMode.all => LoopMode.one,
        LoopMode.one => LoopMode.off,
      });

  /// Atualiza caminhos na fila depois que o organizador moveu arquivos.
  void replaceTrack(Track updated) {
    _queue = [for (final t in _queue) t.id == updated.id ? updated : t];
    if (current?.id == updated.id) _publishMediaItem();
    notifyListeners();
  }

  void _logCurrent({required bool skipped}) {
    final id = _startedTrackId;
    final start = _startedAt;
    if (id == null || start == null) return;
    final secs = DateTime.now().difference(start).inSeconds;
    _startedTrackId = null;
    if (secs < 5) return;
    unawaited(db.logPlay(id, secs, skipped && secs < 30));
  }

  @override
  void dispose() {
    _logCurrent(skipped: false);
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}
