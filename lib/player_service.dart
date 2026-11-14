import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

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

  PlayerService(this.db) {
    _subs.add(player.currentIndexStream.listen((i) {
      _logCurrent(skipped: false);
      _index = i;
      _startedAt = DateTime.now();
      _startedTrackId = current?.id;
      notifyListeners();
    }));
    _subs.add(player.playerStateStream.listen((_) => notifyListeners()));
    _subs.add(player.shuffleModeEnabledStream.listen((_) => notifyListeners()));
    _subs.add(player.loopModeStream.listen((_) => notifyListeners()));
  }

  List<Track> get queue => _queue;
  Track? get current => (_index != null && _index! < _queue.length) ? _queue[_index!] : null;
  bool get playing => player.playing;
  bool get shuffle => player.shuffleModeEnabled;
  LoopMode get loop => player.loopMode;

  Future<void> playQueue(List<Track> tracks, {int start = 0}) async {
    if (tracks.isEmpty) return;
    _logCurrent(skipped: true);
    _queue = List.of(tracks);
    final sources = [
      for (final t in _queue)
        AudioSource.file(
          t.path,
          tag: MediaItem(
            id: t.path,
            title: t.title,
            artist: t.artist,
            album: t.album,
            genre: t.genre.isEmpty ? null : t.genre,
            duration: t.durationMs > 0 ? Duration(milliseconds: t.durationMs) : null,
          ),
        ),
    ];
    await player.setAudioSources(sources, initialIndex: start.clamp(0, sources.length - 1));
    unawaited(player.play());
    notifyListeners();
  }

  Future<void> togglePlay() => player.playing ? player.pause() : player.play();

  Future<void> next() async {
    _logCurrent(skipped: true);
    _startedTrackId = null;
    await player.seekToNext();
  }

  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3)) return player.seek(Duration.zero);
    await player.seekToPrevious();
  }

  Future<void> toggleShuffle() => player.setShuffleModeEnabled(!player.shuffleModeEnabled);

  Future<void> cycleLoop() => player.setLoopMode(switch (player.loopMode) {
        LoopMode.off => LoopMode.all,
        LoopMode.all => LoopMode.one,
        LoopMode.one => LoopMode.off,
      });

  /// Atualiza caminhos na fila depois que o organizador moveu arquivos.
  void replaceTrack(Track updated) {
    _queue = [for (final t in _queue) t.id == updated.id ? updated : t];
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
