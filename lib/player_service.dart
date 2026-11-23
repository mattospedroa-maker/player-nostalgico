import 'dart:async';
import 'dart:io';
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
import 'podcasts.dart';
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

  /// Ids das músicas que você pôs na fila com "Tocar a seguir" / "Adicionar à fila". Ficam logo
  /// depois da atual, na ordem em que entraram; aleatório, mix e reordenações não mexem nelas.
  final Set<int?> _userQueued = {};

  /// Você pôs esta música com "Tocar a seguir" / "Adicionar à fila" e ela ainda não tocou.
  bool isUserQueued(Track t) => _userQueued.contains(t.id);

  /// Muda a cada fila nova escolhida: uma reordenação antiga em andamento desiste no meio.
  int _gen = 0;
  MixMode mixMode = MixMode.vibe;
  void Function(MixMode)? onMixModeChanged;

  /// Músicas editadas/movidas enquanto estão na fila (para mostrar o nome novo).
  final Map<int?, Track> _overrides = {};

  /// Música que o usuário escolheu primeiro: o mix "da mesma vibe" segue o clima dela.
  int? mixSeedId;

  /// Artista usado na última vez que o mix "do mesmo artista" completou a fila.
  String? _mixArtist;

  final PlayerAudioHandler? handler;

  // ---------- podcasts ----------
  /// O AppState diz quem é podcast (arquivo dentro da pasta Podcasts).
  bool Function(Track) isPodcast = (_) => false;

  /// Onde cada episódio parou (o AppState preenche).
  PodcastProgress? podcastProgress;

  /// Velocidade dos podcasts (músicas tocam sempre em 1x).
  double podcastSpeed = 1.0;
  void Function(double)? onPodcastSpeedChanged;

  /// Velocidades do botão de podcast, em ciclo.
  static const podcastSpeeds = [1.0, 1.25, 1.5, 2.0];

  /// A fila foi escolhida na área de Podcasts: depois do episódio vem outro episódio, nunca música do mix.
  bool _podcastMode = false;
  bool get podcastMode => _podcastMode;

  bool get currentIsPodcast {
    final c = current;
    return c != null && isPodcast(c);
  }

  int? _preparedId;
  Timer? _podcastSaver;

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
    crossfader = Crossfader(JustAudioDeck(player), tail ?? JustAudioTail.new)
      // conversa não tem transição: nem saindo de um podcast nem entrando num
      ..hold = (() => currentIsPodcast || (upcoming.isNotEmpty && isPodcast(upcoming.first)));
    // onde o episódio parou: anotado a cada 5 s enquanto toca
    _podcastSaver = Timer.periodic(const Duration(seconds: 5), (_) => _savePodcastPosition());
    handler
      ?..player = player
      ..onNext = next
      ..onPrevious = previous
      ..onSeek = seek;
    _subs.add(player.playbackEventStream.listen((_) => handler?.broadcast(), onError: (_, _) {}));
    _subs.add(player.playingStream.listen((_) => handler?.broadcast()));
    _subs.add(player.currentIndexStream.listen((i) {
      final now = current;
      _userQueued.remove(now?.id); // começou a tocar: saiu do bloco "a seguir"
      _prepareKind(now);
      if (now?.id != _startedTrackId) {
        _logCurrent(skipped: false);
        _startedAt = DateTime.now();
        _startedTrackId = now?.id;
      }
      _publishMediaItem();
      notifyListeners();
      unawaited(_serial(_followArtist));
      if (_overrides.isNotEmpty) unawaited(_serial(_relinkMoved).catchError((Object e) => errorLog.info('Fila', 'Não deu para trocar o caminho de uma música movida', e)));
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

  Future<void> playQueue(List<Track> tracks, {int start = 0, bool mix = false, bool podcast = false}) async {
    if (tracks.isEmpty) return;
    crossfader.cancel(); // escolheu outra música: troca na hora, sem transição
    _savePodcastPosition();
    _logCurrent(skipped: true);
    _gen++; // qualquer reordenação da fila velha que ainda esteja na frente para de mexer
    await _serial(() async {
      _fromMix = mix;
      _podcastMode = podcast;
      _preparedId = null;
      _original = [for (final t in tracks) t.id];
      final list = List.of(tracks);
      var first = start.clamp(0, list.length - 1);
      if (_shuffle && !podcast) {
        final t = list.removeAt(first);
        list.shuffle(_rnd);
        list.insert(0, t);
        first = 0;
      }
      _autoAdded.clear();
      _userQueued.clear();
      _mixArtist = null;
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
      _prepareKind(current);
      _publishMediaItem();
      await _extendMix();
    });
    unawaited(player.play());
    notifyListeners();
  }

  /// Toca um episódio escolhido na área de Podcasts: depois dele vêm [following] (outros episódios), nunca música.
  Future<void> playPodcast(Track episode, {List<Track> following = const []}) =>
      playQueue([episode, ...following.where((t) => t.id != episode.id)], podcast: true);

  /// Toca um episódio no meio das músicas: entra logo depois da atual, toca agora, e quando acaba
  /// a fila de músicas continua de onde estava. Sem músicas tocando, vira uma fila de podcast normal.
  Future<void> playPodcastBetweenSongs(Track episode) async {
    if (_podcastMode || current == null || currentIsPodcast) return playPodcast(episode);
    crossfader.cancel();
    _savePodcastPosition();
    _logCurrent(skipped: true);
    await _serial(() async {
      final pos = _nextPos;
      await player.insertAudioSource(pos, _source(episode));
      await player.seek(Duration.zero, index: pos);
    });
    unawaited(player.play());
    notifyListeners();
  }

  /// Volta/avança alguns segundos (botões -15 / +30 dos podcasts).
  Future<void> seekBy(Duration d) async {
    final total = player.duration;
    var to = player.position + d;
    if (to < Duration.zero) to = Duration.zero;
    if (total != null && to > total - const Duration(seconds: 1)) to = total - const Duration(seconds: 1);
    await seek(to);
  }

  /// Próxima velocidade dos podcasts (1x → 1.25x → 1.5x → 2x → 1x).
  Future<void> cyclePodcastSpeed() async {
    final i = podcastSpeeds.indexOf(podcastSpeed);
    podcastSpeed = podcastSpeeds[(i + 1) % podcastSpeeds.length];
    onPodcastSpeedChanged?.call(podcastSpeed);
    if (currentIsPodcast) await player.setSpeed(podcastSpeed);
    notifyListeners();
  }

  /// Faixa nova começou: podcast continua de onde parou e usa a velocidade escolhida; música sempre em 1x.
  void _prepareKind(Track? now) {
    if (now == null || now.id == _preparedId) return;
    _preparedId = now.id;
    if (isPodcast(now)) {
      unawaited(player.setSpeed(podcastSpeed).catchError((Object _) {}));
      final at = podcastProgress?.resumeAt(now.path);
      if (at != null) unawaited(player.seek(at).catchError((Object _) {}));
    } else if (player.speed != 1.0) {
      unawaited(player.setSpeed(1.0).catchError((Object _) {}));
    }
  }

  /// Anota onde o episódio que está tocando parou (perto do fim = ouvido).
  void _savePodcastPosition() {
    final c = current;
    final prog = podcastProgress;
    if (c == null || prog == null || !isPodcast(c)) return;
    final pos = player.position;
    if (pos <= Duration.zero) return;
    prog.save(c.path, pos, player.duration ?? (c.durationMs > 0 ? Duration(milliseconds: c.durationMs) : null));
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
      // pausa primeiro: se o segundo player estava soando a música, ele para junto e o principal
      // (já pausado) é quem volta a tocar depois, sem os dois soarem juntos nem por um instante
      await player.pause();
      crossfader.cancel();
      _savePodcastPosition();
    } else {
      unawaited(player.play());
    }
  }

  /// Seek feito pelo usuário (barra, notificação): interrompe uma transição em andamento.
  Future<void> seek(Duration position) async {
    crossfader.cancel();
    await player.seek(position);
    _savePodcastPosition();
  }

  /// Tocar uma música da fila direto (sem transição).
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= player.sequence.length) return;
    crossfader.cancel();
    _guard.reset(); // escolha do usuário: se falhar de novo, conta do zero
    await player.seek(Duration.zero, index: index);
  }

  /// Próxima música (botão ⏭ da tela, menu Tocar e notificação).
  ///
  /// Avanço manual sempre vai para a próxima faixa, mesmo com "Repetir uma" ligado (antes o just_audio
  /// voltava para o começo da mesma música). E nunca fica esperando para sempre outra tarefa da fila
  /// (mix, troca de caminho, reordenar): se ela demorar, o avanço acontece assim mesmo.
  Future<void> next() async {
    crossfader.cancel(); // avanço manual: nunca com transição
    _savePodcastPosition();
    _guard.reset();
    final skipped = current;
    _logCurrent(skipped: true);
    var done = false;
    Future<void> advance() async {
      if (done) return;
      done = true;
      // garante que existe uma próxima (o mix completa a fila antes de avançar)
      if (nextIndexFor(_index, player.sequence.length, player.loopMode) == null) await _extendMix();
      final to = nextIndexFor(_index, player.sequence.length, player.loopMode);
      if (to != null) await player.seek(Duration.zero, index: to);
    }

    try {
      await _serial(advance).timeout(_manualWait);
    } on TimeoutException {
      errorLog.info('Fila', 'A fila estava ocupada com outra tarefa; avançou sem esperar');
      await advance();
    }
    if (skipped != null && adaptive) unawaited(pushSimilarBack(skipped));
  }

  /// Quanto um botão (próxima/anterior) espera uma tarefa da fila em andamento antes de agir assim mesmo.
  static const _manualWait = Duration(seconds: 2);

  /// Para onde o avanço manual vai a partir de [index] numa fila de [length] músicas.
  /// "Repetir uma" não prende o botão na mesma música; "Repetir tudo" volta ao começo depois da última.
  @visibleForTesting
  static int? nextIndexFor(int? index, int length, LoopMode loop) {
    if (index == null || length == 0) return null;
    if (index + 1 < length) return index + 1;
    return loop == LoopMode.off ? null : 0;
  }

  /// Para onde o "anterior" manual vai (mesma regra do [nextIndexFor], ao contrário).
  @visibleForTesting
  static int? previousIndexFor(int? index, int length, LoopMode loop) {
    if (index == null || length == 0) return null;
    if (index > 0) return index - 1;
    return loop == LoopMode.off ? null : length - 1;
  }

  /// Troca o tipo de mix na hora: as músicas que o mix colocou são refeitas; a atual continua.
  ///
  /// Escolher no painel "Depois desta, tocar" vale na hora: se as próximas ainda são da lista que
  /// você tocou (álbum, playlist, busca), o resto dela sai e entra o mix. As que você pôs com
  /// "Tocar a seguir" / "Adicionar à fila" ficam. Antes o mix só entrava quando a lista acabava,
  /// então trocar de vibe para artista não mudava nada no "A seguir".
  Future<void> setMixMode(MixMode m) async {
    final changed = m != mixMode;
    if (!changed && !hasListAhead) return;
    mixMode = m;
    if (changed) onMixModeChanged?.call(m);
    notifyListeners();
    await _serial(_mixInsteadOfList);
    notifyListeners();
  }

  /// Ainda tem música da lista tocada nas próximas (nem do mix, nem posta por você).
  bool get hasListAhead => listAhead(upcoming, (t) => _userQueued.contains(t.id) || _autoAdded.contains(t.id));

  /// Alguma das [upcoming] não é do mix nem da sua fila ([fromMixOrQueue])?
  @visibleForTesting
  static bool listAhead<T>(List<T> upcoming, bool Function(T) fromMixOrQueue) => upcoming.any((t) => !fromMixOrQueue(t));

  /// Tira tudo depois do bloco "Tocar a seguir" e põe o mix no lugar. Só roda dentro de [_serial].
  /// Fila de podcasts, repetir ligado ou mix sem músicas: só refaz o que o mix tinha posto.
  Future<void> _mixInsteadOfList() async {
    final seed = mixSeed;
    if (_podcastMode || currentIsPodcast || seed == null || isPodcast(seed) || player.loopMode != LoopMode.off) {
      return _rebuildMix();
    }
    final keepEnd = queueEndPos(queue, _nextPos, (t) => _userQueued.contains(t.id));
    final keep = {current?.id, for (final t in queue.sublist(_nextPos, keepEnd)) t.id};
    final failedIds = {for (final t in library()) if (_failed.containsKey(t.path)) t.id};
    final picks = pickMix(seed, library(), mode: mixMode, exclude: {...keep, ...failedIds}, count: 10, rnd: _rnd);
    if (picks.isEmpty) return _rebuildMix();
    final end = player.sequence.length;
    try {
      if (keepEnd < end) await player.removeAudioSourceRange(keepEnd, end);
      await player.addAudioSources([for (final t in picks) _source(t)]);
      _autoAdded
        ..clear()
        ..addAll(picks.map((t) => t.id));
      _mixArtist = seed.artist;
    } catch (e) {
      errorLog.warn('Mix', 'Não deu para trocar as próximas pelo mix', error: e);
    }
  }

  /// Refaz as próximas músicas que o mix colocou (ex.: mudou o tipo de mix ou o clima da primeira música).
  Future<void> refreshMix() async {
    await _serial(_rebuildMix);
    notifyListeners();
  }

  /// Tira as próximas que o mix colocou e completa de novo. Só roda dentro de [_serial].
  Future<void> _rebuildMix() async {
    final q = queue;
    for (var i = q.length - 1; i >= _nextPos; i--) {
      if (_autoAdded.remove(q[i].id)) await player.removeAudioSourceAt(i);
    }
    await _extendMix(force: true);
  }

  /// A música mudou. No "do mesmo artista", se agora toca outro artista (ex.: o artista anterior
  /// acabou e entrou uma da vibe), as próximas do mix passam a ser desse artista. Só roda dentro de [_serial].
  Future<void> _followArtist() async {
    if (currentIsPodcast) return; // episódio no meio das músicas: o mix de músicas fica como estava
    final now = current;
    final was = _mixArtist;
    if (mixMode == MixMode.artist &&
        now != null &&
        was != null &&
        now.artist != unknownArtist &&
        !ArtistNames.current.shares(now.artist, was) &&
        upcoming.any((t) => _autoAdded.contains(t.id))) {
      await _rebuildMix();
    } else {
      await _extendMix();
    }
  }

  /// A música que guia o mix. "Do mesmo artista": a que está tocando agora (é o artista dela que
  /// você quer ouvir). "Da mesma vibe": a primeira escolhida (com o clima atual dela).
  Track? get mixSeed {
    // podcast no meio das músicas: o mix continua guiado pelas músicas, nunca pelo episódio
    if (currentIsPodcast) return _firstChosen;
    if (mixMode == MixMode.artist) return current ?? _firstChosen;
    return _firstChosen ?? current;
  }

  Track? get _firstChosen {
    final id = mixSeedId;
    if (id != null) {
      for (final t in library()) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  /// Quando faltam poucas músicas, completa a fila com o mix (a música nunca para).
  /// Só roda dentro de [_serial].
  Future<void> _extendMix({bool force = false}) async {
    final seed = mixSeed;
    // fila de podcasts: o mix de músicas nunca entra (o mix de podcasts vem numa fase própria)
    if (_podcastMode || seed == null || isPodcast(seed) || player.loopMode != LoopMode.off) return;
    final q = queue;
    if (!force && q.length - _nextPos >= 3) return;
    final failedIds = {for (final t in library()) if (_failed.containsKey(t.path)) t.id};
    final picks = pickMix(seed, library(), mode: mixMode, exclude: {...q.map((t) => t.id), ...failedIds}, count: 10, rnd: _rnd);
    if (picks.isEmpty) return;
    try {
      await player.addAudioSources([for (final t in picks) _source(t)]);
      _autoAdded.addAll(picks.map((t) => t.id));
      _mixArtist = seed.artist;
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
    if (t.path != _sourcePath(i) && File(t.path).existsSync()) {
      // a música foi movida (editar, organizar): abre do lugar novo em vez de dar como quebrada
      await player.removeAudioSourceAt(i);
      await player.insertAudioSource(i, _source(t));
      try {
        await player.seek(Duration.zero, index: i);
        unawaited(player.play());
      } catch (_) {
        // se nem assim abrir, o aviso de erro chega de novo e aí ela é marcada
      }
      return;
    }
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
        final id = (player.sequence[index].tag as Track).id;
        await player.removeAudioSourceAt(index);
        if (!player.sequence.any((x) => (x.tag as Track).id == id)) _userQueued.remove(id);
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
  ///
  /// Troca o pedaço todo de uma vez (antes movia música por música: com a biblioteca inteira na
  /// fila levava minutos, e escolher um álbum nesse meio tempo ficava esperando e parecia não fazer nada).
  /// As que você pôs com "Tocar a seguir" / "Adicionar à fila" continuam na frente.
  Future<void> _applyUpcoming(List<Track> desired) async {
    final gen = _gen;
    final start = _nextPos;
    final now = upcoming;
    final want = keepQueuedFirst(desired, now, (t) => _userQueued.contains(t.id), key: (t) => t.id);
    if (want.length != now.length || start <= 0) return; // fila mudou no meio: não mexe
    var same = true;
    for (var i = 0; i < want.length; i++) {
      if (want[i].id != now[i].id) {
        same = false;
        break;
      }
    }
    if (same || gen != _gen || start != _nextPos) return;
    final end = player.sequence.length;
    await player.removeAudioSourceRange(start, end);
    await player.addAudioSources([for (final t in want) _source(t)]);
    notifyListeners();
  }

  /// [desired] com as músicas do bloco "a seguir" (as primeiras de [current] marcadas por [queued])
  /// na frente, na mesma ordem de antes.
  @visibleForTesting
  static List<T> keepQueuedFirst<T>(List<T> desired, List<T> current, bool Function(T) queued, {Object? Function(T)? key}) {
    final k = key ?? (T t) => t;
    final lead = <T>[];
    for (final t in current) {
      if (!queued(t)) break;
      lead.add(t);
    }
    if (lead.isEmpty) return desired;
    final leadKeys = {for (final t in lead) k(t)};
    return [...lead, ...desired.where((t) => !leadKeys.contains(k(t)))];
  }

  /// Onde "Adicionar à fila" põe as músicas: depois da atual e de tudo que você já pôs na fila,
  /// antes do resto (assim elas tocam logo e depois a fila volta de onde estava).
  @visibleForTesting
  static int queueEndPos<T>(List<T> sequence, int nextPos, bool Function(T) queued) {
    var p = nextPos;
    while (p < sequence.length && queued(sequence[p])) {
      p++;
    }
    return p;
  }

  /// "Tocar a seguir" ([next] = true) ou "Adicionar à fila" ([next] = false).
  ///
  /// As músicas entram depois da que está tocando; quando acabam, a fila continua de onde estava.
  /// "Tocar a seguir" passa na frente de tudo; "Adicionar à fila" entra depois das que você já pôs.
  /// Podcast nunca entra na fila de músicas. Sem nada tocando (ou com uma fila de podcasts),
  /// começa a tocar as músicas escolhidas. Devolve quantas músicas entraram.
  Future<int> enqueue(List<Track> tracks, {required bool next}) async {
    final songs = tracks.where((t) => !isPodcast(t)).toList();
    if (songs.isEmpty) return 0;
    if (current == null || _podcastMode) {
      await playQueue(songs);
      return songs.length;
    }
    final added = await _serial(() async {
      final now = current;
      final list = songs.where((t) => t.id != now?.id).toList();
      if (list.isEmpty) return 0;
      final ids = {for (final t in list) t.id};
      // já estavam mais para frente na fila: saem de lá e vêm para cá (sem tocar duas vezes)
      final seq = player.sequence;
      for (var i = seq.length - 1; i >= _nextPos; i--) {
        if (ids.contains((seq[i].tag as Track).id)) await player.removeAudioSourceAt(i);
      }
      final pos = next ? _nextPos : queueEndPos(queue, _nextPos, (t) => _userQueued.contains(t.id));
      await player.insertAudioSources(pos, [for (final t in list) _source(_display(t))]);
      _userQueued.addAll(ids);
      _autoAdded.removeAll(ids);
      return list.length;
    });
    notifyListeners();
    return added;
  }

  Future<void> previous() async {
    crossfader.cancel();
    if (player.position > const Duration(seconds: 3)) return player.seek(Duration.zero);
    final to = previousIndexFor(_index, player.sequence.length, player.loopMode);
    if (to != null) await player.seek(Duration.zero, index: to);
  }

  /// Liga/desliga o aleatório sem mexer na fila atual (ela vai ser trocada logo em seguida por uma
  /// nova, já na ordem certa). Reordenar a fila velha antes era o que travava "Tocar tudo" num álbum.
  void setShuffleForNextQueue(bool on) {
    if (on == _shuffle) return;
    _shuffle = on;
    notifyListeners();
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
  /// A música mudou (nome, artista, pasta...). Se o arquivo mudou de lugar, a fila passa a tocar
  /// o caminho novo: as que estão na fila são trocadas na hora; a que está tocando continua (o
  /// arquivo aberto segue tocando) e é trocada assim que a fila sair dela ou se ela precisar abrir de novo.
  void replaceTrack(Track updated) {
    if (!player.sequence.any((s) => (s.tag as Track).id == updated.id)) return;
    _overrides[updated.id] = updated;
    if (current?.id == updated.id) _publishMediaItem();
    notifyListeners();
    unawaited(_serial(_relinkMoved).catchError((Object e) {
      errorLog.warn('Fila', 'Não deu para atualizar a fila com o caminho novo de "${updated.title}"', error: e);
    }));
  }

  /// Tira da fila uma música que saiu da biblioteca (apagada, repetida removida). Se for a que está
  /// tocando, pula para a próxima antes.
  Future<void> forgetTrack(int? id) async {
    if (id == null) return;
    if (current?.id == id) await next();
    await _serial(() async {
      final seq = player.sequence;
      for (var i = seq.length - 1; i >= 0; i--) {
        if ((seq[i].tag as Track).id == id && i != _index) await player.removeAudioSourceAt(i);
      }
      _overrides.remove(id);
      _autoAdded.remove(id);
      _userQueued.remove(id);
    });
    notifyListeners();
  }

  /// Caminho que o player realmente abre na posição [i] (pode estar velho se a música foi movida).
  String _sourcePath(int i) => (player.sequence[i].tag as Track).path;

  /// Troca na fila as músicas movidas pelo caminho novo (menos a que está tocando agora).
  /// Só roda dentro de [_serial].
  Future<void> _relinkMoved() async {
    for (var i = 0; i < player.sequence.length; i++) {
      if (i == _index) continue;
      final shown = _display(player.sequence[i].tag as Track);
      if (shown.path == _sourcePath(i)) continue;
      await player.removeAudioSourceAt(i);
      await player.insertAudioSource(i, _source(shown));
    }
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
    _savePodcastPosition();
    _podcastSaver?.cancel();
    _logCurrent(skipped: false);
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(crossfader.dispose());
    player.dispose();
    super.dispose();
  }
}
