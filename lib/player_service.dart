import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

import 'artist_names.dart';
import 'audio_handler.dart';
import 'crossfade.dart';
import 'db.dart';
import 'error_log.dart';
import 'models.dart';
import 'mood.dart';
import 'recommender.dart';
import 'skip_guard.dart';

/// O que tocar quando a fila acaba.
enum MixMode { artist, vibe }

/// Toca a fila de músicas e registra o histórico (usado pela recomendação).
/// A fila mostrada vem sempre da lista real do player, e toda mudança na fila passa por uma fila única
/// de operações, para a tela nunca mostrar uma música diferente da que está tocando.
class PlayerService extends ChangeNotifier implements CrossfadeSettings {
  final AppDb db;
  final AudioPlayer player = AudioPlayer();
  DateTime? _startedAt;
  int? _startedTrackId;
  final _subs = <StreamSubscription>[];
  List<int?> _original = const [];
  bool _shuffle = false;
  bool _fromMix = false;
  final _rnd = Random();

  /// Biblioteca inteira (o AppState preenche), para montar o mix automático.
  List<Track> Function() library = () => const [];

  /// Ids das músicas que entraram sozinhas pelo mix (podem ser trocadas quando o modo muda).
  final Set<int?> _autoAdded = {};
  MixMode mixMode = MixMode.vibe;
  void Function(MixMode)? onMixModeChanged;

  /// Músicas editadas/movidas enquanto estão na fila (para mostrar o nome novo).
  final Map<int?, Track> _overrides = {};

  /// Música que o usuário escolheu primeiro: o mix "da mesma vibe" segue o clima dela.
  int? mixSeedId;

  final PlayerAudioHandler? handler;

  /// Transição suave entre músicas (só no fim natural de cada uma).
  late final Crossfader crossfader;
  void Function(bool)? onCrossfadeChanged;
  void Function(Duration out, Duration inn)? onCrossfadeTimesChanged;

  /// Avisado depois que uma música entra no histórico.
  void Function()? onPlayLogged;

  /// Músicas que não abriram (caminho -> falha). Continuam na fila, marcadas, até a fila mudar.
  final Map<String, PlaybackFailure> _failed = {};
  final _guard = SkipGuard();

  /// Avisado quando uma música não abre e o player pula para a próxima.
  void Function(Track track, PlaybackFailure failure)? onTrackFailed;

  /// Avisado quando nenhuma música da fila abriu e o player parou.
  void Function(List<Track> failed)? onAllFailed;

  /// Músicas da fila que não abriram (na ordem em que falharam).
  List<PlaybackFailure> get failures => _failed.values.toList();

  /// A música não abriu nesta fila.
  PlaybackFailure? failureOf(Track t) => _failed[t.path];

  PlayerService(this.db, {this.handler, TailDeck Function()? tail}) {
    crossfader = Crossfader(JustAudioDeck(player), tail ?? JustAudioTail.new);
    handler
      ?..player = player
      ..onNext = next
      ..onPrevious = previous
      ..onSeek = seek;
    _subs.add(player.playbackEventStream.listen((_) => handler?.broadcast(), onError: (_, _) {}));
    _subs.add(player.playingStream.listen((_) => handler?.broadcast()));
    _subs.add(player.currentIndexStream.listen((i) {
      final now = current;
      if (now?.id != _startedTrackId) {
        _logCurrent(skipped: false);
        _startedAt = DateTime.now();
        _startedTrackId = now?.id;
      }
      _publishMediaItem();
      notifyListeners();
      unawaited(_serial(_extendMix));
    }));
    _subs.add(player.sequenceStream.listen((_) {
      _publishMediaItem();
      notifyListeners();
    }));
    _subs.add(player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.ready) _guard.onReady();
      notifyListeners();
    }));
    _subs.add(player.errorStream.listen((e) => unawaited(_serial(() => _skipBroken(e.index))), onError: (_, _) {}));
    _subs.add(player.loopModeStream.listen((_) => notifyListeners()));
  }

  // ---------- fila única de operações ----------
  Future<void> _chain = Future.value();
  Future<T> _serial<T>(Future<T> Function() op) {
    final c = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        c.complete(await op());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Track _display(Track t) => _overrides[t.id] ?? t;

  /// A fila real do player.
  List<Track> get queue => [for (final s in player.sequence) _display(s.tag as Track)];
  int? get _index => player.currentIndex;
  Track? get current {
    final i = _index;
    final seq = player.sequence;
    return (i != null && i >= 0 && i < seq.length) ? _display(seq[i].tag as Track) : null;
  }

  /// Próximas músicas (para mostrar "A seguir").
  List<Track> get upcoming {
    final q = queue;
    return _index == null || _nextPos >= q.length ? const [] : q.sublist(_nextPos);
  }

  bool get playing => player.playing;

  @override
  bool get crossfade => crossfader.enabled;

  /// Liga/desliga o crossfade na hora (desligar no meio de uma transição termina ela na hora).
  @override
  void setCrossfade(bool on) {
    if (on == crossfader.enabled) return;
    crossfader.enabled = on;
    onCrossfadeChanged?.call(on);
    notifyListeners();
  }

  @override
  Duration get fadeOut => crossfader.fadeOut;
  @override
  Duration get fadeIn => crossfader.fadeIn;

  /// Tempos da transição (Opções → Reprodução): quanto a que sai leva para sumir e a próxima para aparecer.
  @override
  void setCrossfadeTimes(Duration out, Duration inn) {
    if (out == crossfader.fadeOut && inn == crossfader.fadeIn) return;
    crossfader.setTimes(out, inn);
    onCrossfadeTimesChanged?.call(out, inn);
    notifyListeners();
  }
  bool get shuffle => _shuffle;

  /// Fila que se adapta: aleatório ou "Mix do momento". Pular afasta parecidas; favoritar aproxima.
  bool get adaptive => _shuffle || _fromMix;
  LoopMode get loop => player.loopMode;
  int get _nextPos => (_index ?? -1) + 1;

  Future<void> playQueue(List<Track> tracks, {int start = 0, bool mix = false}) async {
    if (tracks.isEmpty) return;
    crossfader.cancel(); // escolheu outra música: troca na hora, sem transição
    _logCurrent(skipped: true);
    await _serial(() async {
      _fromMix = mix;
      _original = [for (final t in tracks) t.id];
      final list = List.of(tracks);
      var first = start.clamp(0, list.length - 1);
      if (_shuffle) {
        final t = list.removeAt(first);
        list.shuffle(_rnd);
        list.insert(0, t);
        first = 0;
      }
      _autoAdded.clear();
      _overrides.clear();
      _failed.clear();
      _guard.reset();
      mixSeedId = list[first].id;
      try {
        await player.setAudioSources([for (final t in list) _source(t)], initialIndex: first);
      } on PlayerException {
        // a primeira não abriu: o aviso de erro do player chega também e [_skipBroken] pula para a próxima
      }
      _startedAt = DateTime.now();
      _startedTrackId = current?.id;
      _publishMediaItem();
      await _extendMix();
    });
    unawaited(player.play());
    notifyListeners();
  }

  AudioSource _source(Track t) => AudioSource.file(t.path, tag: t);

  /// Nome, artista e duração na notificação / tela de bloqueio.
  void _publishMediaItem() {
    final t = current;
    final h = handler;
    if (t == null || h == null) return;
    h.queue.add([for (final q in queue) MediaItem(id: q.path, title: q.title, artist: q.artist)]);
    final item = MediaItem(
      id: t.path,
      title: t.title,
      artist: t.artist == unknownArtist ? null : t.artist,
      album: t.album == unknownAlbum ? null : t.album,
      genre: t.genre.isEmpty ? null : t.genre,
      duration: t.durationMs > 0 ? Duration(milliseconds: t.durationMs) : null,
      artUri: h.art[t.path],
    );
    if (h.mediaItem.value != item) h.mediaItem.add(item);
    h.broadcast();
  }

  Future<void> togglePlay() async {
    if (player.playing) {
      crossfader.cancel();
      await player.pause();
    } else {
      unawaited(player.play());
    }
  }

  /// Seek feito pelo usuário (barra, notificação): interrompe uma transição em andamento.
  Future<void> seek(Duration position) async {
    crossfader.cancel();
    await player.seek(position);
  }

  /// Tocar uma música da fila direto (sem transição).
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= player.sequence.length) return;
    crossfader.cancel();
    _guard.reset(); // escolha do usuário: se falhar de novo, conta do zero
    await player.seek(Duration.zero, index: index);
  }

  Future<void> next() async {
    crossfader.cancel(); // avanço manual: nunca com transição
    _guard.reset();
    final skipped = current;
    _logCurrent(skipped: true);
    // garante que existe uma próxima (o mix completa a fila antes de avançar)
    await _serial(_extendMix);
    await player.seekToNext();
    if (skipped != null && adaptive) await pushSimilarBack(skipped);
  }

  /// Troca o tipo de mix na hora: as músicas que o mix colocou são refeitas; a atual continua.
  Future<void> setMixMode(MixMode m) async {
    if (m == mixMode) return;
    mixMode = m;
    onMixModeChanged?.call(m);
    notifyListeners();
    await refreshMix();
  }

  /// Refaz as próximas músicas que o mix colocou (ex.: mudou o tipo de mix ou o clima da primeira música).
  Future<void> refreshMix() async {
    await _serial(() async {
      final q = queue;
      for (var i = q.length - 1; i >= _nextPos; i--) {
        if (_autoAdded.remove(q[i].id)) await player.removeAudioSourceAt(i);
      }
      await _extendMix(force: true);
    });
    notifyListeners();
  }

  /// A música que guia o mix: a primeira escolhida (com o clima atual dela), senão a que está tocando.
  Track? get mixSeed {
    final id = mixSeedId;
    if (id != null) {
      for (final t in library()) {
        if (t.id == id) return t;
      }
    }
    return current;
  }

  /// Quando faltam poucas músicas, completa a fila com o mix (a música nunca para).
  /// Só roda dentro de [_serial].
  Future<void> _extendMix({bool force = false}) async {
    final seed = mixSeed;
    if (seed == null || player.loopMode != LoopMode.off) return;
    final q = queue;
    if (!force && q.length - _nextPos >= 3) return;
    final failedIds = {for (final t in library()) if (_failed.containsKey(t.path)) t.id};
    final picks = pickMix(seed, library(), mode: mixMode, exclude: {...q.map((t) => t.id), ...failedIds}, count: 10, rnd: _rnd);
    if (picks.isEmpty) return;
    try {
      await player.addAudioSources([for (final t in picks) _source(t)]);
      _autoAdded.addAll(picks.map((t) => t.id));
    } catch (e) {
      errorLog.warn('Mix', 'Não deu para completar a fila com o mix automático', error: e);
    }
    notifyListeners();
  }

  /// A música da posição [index] não abriu: marca, avisa e pula para a próxima que ainda não falhou.
  /// Se todas falharam, para e avisa uma vez só (nunca fica pulando em loop). Só roda dentro de [_serial].
  Future<void> _skipBroken(int? index) async {
    final seq = player.sequence;
    final i = index ?? _index;
    if (i == null || i < 0 || i >= seq.length) return;
    final t = _display(seq[i].tag as Track);
    final failure = _failed[t.path] ??= PlaybackFailure(t.path, PlaybackFailure.reasonFor(t.path));
    if (t.id == _startedTrackId) _startedTrackId = null; // não entra no histórico
    // sem músicas suficientes na frente, o mix completa a fila antes de decidir
    if (player.loopMode == LoopMode.off && seq.length - i - 1 < 3) await _extendMix();
    final q = queue;
    final to = _guard.onError(i, q.length,
        wrap: player.loopMode == LoopMode.all, failed: (j) => _failed.containsKey(q[j].path));
    if (to == -1) return;
    if (to == null) {
      await player.pause();
      notifyListeners();
      onAllFailed?.call([for (final s in q) if (_failed.containsKey(s.path)) s]);
      return;
    }
    notifyListeners();
    onTrackFailed?.call(t, failure);
    try {
      await player.seek(Duration.zero, index: to);
      unawaited(player.play());
    } catch (_) {
      // a próxima também não abriu: o aviso de erro dela chega e passa por aqui de novo
    }
  }

  /// Tenta tocar de novo uma música que não abriu (ex.: o cartão de memória voltou).
  Future<void> retry(Track t) async {
    _failed.remove(t.path);
    final i = queue.indexWhere((q) => q.path == t.path);
    notifyListeners();
    if (i >= 0) await jumpTo(i);
  }

  /// Escolhe músicas para o mix. "Do mesmo artista": só o artista (se acabar, completa com a vibe).
  /// "Da mesma vibe": mesmo gênero / mesmo clima, misturando artistas (no máximo 2 de cada).
  static List<Track> pickMix(Track seed, List<Track> library,
      {required MixMode mode, Set<int?> exclude = const {}, int count = 10, Random? rnd}) {
    final r = rnd ?? Random();
    final pool = library.where((t) => t.id != seed.id && !exclude.contains(t.id)).toList()..shuffle(r);
    final out = <Track>[];
    if (mode == MixMode.artist && seed.artist != unknownArtist) {
      final names = ArtistNames.current;
      out.addAll(pool.where((t) => names.shares(t.artist, seed.artist)).take(count));
    }
    if (out.length < count) {
      final seedMood = seed.effectiveMood;
      final seedChose = seed.chosenMood != null;
      // mesma pontuação da recomendação (artista, álbum, gênero, clima, época) + a regra do clima escolhido
      double vibe(Track t) {
        var v = Recommender.affinity(seed, t);
        // clima: se o usuário escolheu o clima da primeira música, ele manda mais que o gênero
        if (seedMood != null) {
          if (seedChose && t.effectiveMood == seedMood) v += 5;
          if (t.chosenMood != null && t.chosenMood != seedMood) v -= seedChose ? 3 : 1.5;
        }
        if (t.favorite) v += .5;
        return v + r.nextDouble(); // um pouco de sorte para variar
      }

      // pontuação calculada uma vez por música (antes era refeita a cada comparação da ordenação,
      // com um sorteio novo a cada vez: lento em bibliotecas grandes e com ordem instável)
      final taken = out.toSet();
      final scored = [for (final t in pool) if (!taken.contains(t)) (t, vibe(t))]..sort((a, b) => b.$2.compareTo(a.$2));
      final ranked = [for (final s in scored) s.$1];
      final perArtist = <String, int>{};
      String who(Track t) => ArtistNames.current.key(t.artist);
      for (final t in out) {
        perArtist[who(t)] = (perArtist[who(t)] ?? 0) + 1;
      }
      for (final t in ranked) {
        if (out.length >= count) break;
        final n = perArtist[who(t)] ?? 0;
        if (mode == MixMode.vibe && n >= 2) continue;
        perArtist[who(t)] = n + 1;
        out.add(t);
      }
    }
    return out;
  }

  /// Parecença entre duas músicas: mesmo artista pesa mais, depois gênero e álbum.
  static double similarity(Track a, Track b) {
    var s = 0.0;
    if (a.artist.isNotEmpty && a.artist != unknownArtist && ArtistNames.current.shares(a.artist, b.artist)) s += 2;
    if (a.genre.isNotEmpty && a.genre.toLowerCase() == b.genre.toLowerCase()) s += 1;
    if (a.album.isNotEmpty && a.album == b.album && a.album != unknownAlbum) s += .5;
    return s;
  }

  /// Depois de pular: as parecidas com a pulada vão para o fim da fila (as mais parecidas por último).
  Future<void> pushSimilarBack(Track skipped) => _serial(() async {
        final up = upcoming;
        if (up.isEmpty) return;
        final keep = up.where((t) => similarity(t, skipped) == 0).toList();
        final back = up.where((t) => similarity(t, skipped) > 0).toList()
          ..sort((a, b) => similarity(a, skipped).compareTo(similarity(b, skipped)));
        await _applyUpcoming([...keep, ...back]);
      });

  /// Depois de favoritar: parecidas sobem para logo depois da atual, e entram até 3 parecidas da biblioteca.
  Future<void> pullSimilarForward(Track fav, List<Track> library) => _serial(() async {
        if (_index == null) return;
        final ids = queue.map((t) => t.id).toSet();
        final extra = (library.where((t) => !ids.contains(t.id) && similarity(t, fav) > 0).toList()..shuffle(_rnd)).take(3).toList();
        if (extra.isNotEmpty) {
          await player.insertAudioSources(_nextPos, [for (final t in extra) _source(t)]);
          _autoAdded.addAll(extra.map((t) => t.id));
        }
        final up = upcoming;
        final near = up.where((t) => similarity(t, fav) > 0).toList()..shuffle(_rnd);
        final rest = up.where((t) => similarity(t, fav) == 0).toList();
        // intercala: parecida, outra, parecida... para não virar só um tipo
        final out = <Track>[];
        while (near.isNotEmpty || rest.isNotEmpty) {
          if (near.isNotEmpty) out.add(near.removeAt(0));
          if (near.isNotEmpty && out.length < 4) out.add(near.removeAt(0));
          if (rest.isNotEmpty) out.add(rest.removeAt(0));
        }
        await _applyUpcoming(out);
        notifyListeners();
      });

  /// Tira uma música da fila (a que está tocando não sai).
  Future<void> removeAt(int index) => _serial(() async {
        if (index == _index || index < 0 || index >= player.sequence.length) return;
        await player.removeAudioSourceAt(index);
        notifyListeners();
      });

  /// Embaralha só as próximas músicas (a atual continua tocando).
  Future<void> shuffleUpcoming() => _serial(() async {
        final up = [...upcoming];
        if (up.length < 2) return;
        up.shuffle(_rnd);
        await _applyUpcoming(up);
      });

  /// Reordena as próximas músicas (a atual não é tocada). Só roda dentro de [_serial].
  Future<void> _applyUpcoming(List<Track> desired) async {
    final start = _nextPos;
    for (var i = 0; i < desired.length; i++) {
      final pos = start + i;
      final q = queue;
      final j = q.indexWhere((t) => t.id == desired[i].id, pos);
      if (j < 0 || j == pos) continue;
      await player.moveAudioSource(j, pos);
    }
    notifyListeners();
  }

  Future<void> previous() async {
    crossfader.cancel();
    if (player.position > const Duration(seconds: 3)) return player.seek(Duration.zero);
    await player.seekToPrevious();
  }

  /// Aleatório feito pelo app (para a fila poder se adaptar ao que você pula e curte).
  Future<void> toggleShuffle() async {
    _shuffle = !_shuffle;
    notifyListeners();
    await _serial(() async {
      final up = upcoming;
      if (up.isEmpty) return;
      if (_shuffle) {
        up.shuffle(_rnd);
      } else {
        final order = {for (var i = 0; i < _original.length; i++) _original[i]: i};
        up.sort((a, b) => (order[a.id] ?? 1 << 30).compareTo(order[b.id] ?? 1 << 30));
      }
      await _applyUpcoming(up);
    });
  }

  Future<void> cycleLoop() => player.setLoopMode(switch (player.loopMode) {
        LoopMode.off => LoopMode.all,
        LoopMode.all => LoopMode.one,
        LoopMode.one => LoopMode.off,
      });

  /// Atualiza caminhos na fila depois que o organizador moveu arquivos.
  void replaceTrack(Track updated) {
    if (!queue.any((t) => t.id == updated.id)) return;
    _overrides[updated.id] = updated;
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
    unawaited(db.logPlay(id, secs, skipped && secs < 30).then((_) => onPlayLogged?.call()));
  }

  @override
  void dispose() {
    _logCurrent(skipped: false);
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(crossfader.dispose());
    player.dispose();
    super.dispose();
  }
}
