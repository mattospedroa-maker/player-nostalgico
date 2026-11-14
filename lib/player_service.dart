import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

import 'audio_handler.dart';
import 'db.dart';
import 'models.dart';

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
    _publishMediaItem();
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
    ));
  }

  Future<void> togglePlay() => player.playing ? player.pause() : player.play();

  Future<void> next() async {
    final skipped = current;
    _logCurrent(skipped: true);
    _startedTrackId = null;
    await player.seekToNext();
    if (skipped != null && adaptive) await pushSimilarBack(skipped);
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
