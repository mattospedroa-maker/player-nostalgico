import 'dart:async';
import 'dart:math';

import 'package:just_audio/just_audio.dart';

import 'error_log.dart';

/// Duração da transição suave (crossfade). Mude aqui para ajustar em todo o app.
const crossfadeDuration = Duration(seconds: 4);

/// Curva de volume de potência constante: no meio as duas ficam em ~71%, então a soma não "afunda"
/// nem estoura. [t] vai de 0 (começo) a 1 (fim). Devolve (volume da que sai, volume da que entra).
(double, double) crossfadeVolumes(double t) {
  final x = t.clamp(0.0, 1.0) * pi / 2;
  return (cos(x), sin(x));
}

/// O player principal, visto pelo crossfade (dá para trocar por um falso nos testes).
abstract class FadeDeck {
  Duration get position;
  Duration? get duration;
  bool get playing;

  /// Existe uma próxima música para entrar sozinha (e não está repetindo a mesma faixa).
  bool get canAdvance;

  /// Arquivo que está tocando agora.
  String? get currentPath;
  Future<void> setVolume(double v);

  /// Passa para a próxima música da fila (como se a atual tivesse terminado).
  Future<void> advance();

  /// Avisa quando algo que muda o horário da transição acontece (play/pause, troca de faixa, seek, fila, repetir).
  Stream<void> get changes;
}

/// Segundo player, só para o finalzinho da música que está saindo.
abstract class TailDeck {
  Future<void> load(String path, Duration at);
  Future<void> seek(Duration at);
  void start();
  Future<void> setVolume(double v);
  Future<void> stop();
  Future<void> dispose();
}

/// Crossfade só no fim natural da música.
///
/// Como funciona: pouco antes dos últimos [crossfadeDuration], o finalzinho da música atual é preparado
/// num segundo player (só esse arquivo, lido do disco aos poucos, sem carregar na memória). Na hora,
/// o segundo player continua a música atual do ponto exato, o player principal já passa para a próxima
/// faixa com volume 0, e os dois volumes se cruzam (um desce, o outro sobe) com as músicas tocando juntas.
/// No fim, o segundo player para e solta o arquivo; o principal segue normal, com a fila, a notificação
/// e o histórico de sempre (a troca de faixa é a mesma de quando uma música termina).
///
/// Avanço manual nunca usa crossfade: a transição só é marcada pelo relógio da música chegando ao fim,
/// e qualquer comando do usuário ([cancel]) desmarca ou interrompe a transição na hora.
class Crossfader {
  final FadeDeck main;
  final TailDeck Function() _makeTail;
  final Duration fade;

  /// Tempo para o segundo player abrir o arquivo antes da transição.
  static const _preload = Duration(milliseconds: 1500);

  /// Atraso médio para o segundo player começar a soar (o principal troca de faixa depois disso).
  static const _handoff = Duration(milliseconds: 80);
  static const _tick = Duration(milliseconds: 50);

  TailDeck? _tail;
  StreamSubscription<void>? _sub;
  Timer? _timer;
  Timer? _ramp;
  int _gen = 0;
  bool _enabled = false;
  bool _preparing = false;
  bool _fading = false;

  /// Avisado quando uma transição começa ou termina.
  void Function()? onFadingChanged;

  Crossfader(this.main, this._makeTail, {this.fade = crossfadeDuration}) {
    _sub = main.changes.listen((_) => _schedule());
  }

  bool get enabled => _enabled;
  bool get fading => _fading;

  set enabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    if (v) {
      _schedule();
    } else {
      cancel(); // desligou no meio: termina na hora, sem sobrar som
    }
  }

  /// Marca o próximo momento da transição (ou desmarca, se não cabe).
  void _schedule() {
    if (_fading) {
      if (!main.playing) cancel(); // pausou (ou o sistema pausou) no meio: para o final da que saía
      return;
    }
    if (_preparing) return; // a preparação confere tudo de novo antes de começar
    _timer?.cancel();
    _timer = null;
    if (!_ready) return;
    final remaining = main.duration! - main.position;
    if (remaining <= fade + const Duration(milliseconds: 300)) return; // tarde demais: termina normal
    final wait = remaining - fade - _preload;
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _prepare);
  }

  bool get _ready {
    if (!_enabled || !main.playing || !main.canAdvance) return false;
    final d = main.duration;
    return d != null && d >= fade * 3; // música curtinha não tem crossfade
  }

  Future<void> _prepare() async {
    final gen = _gen;
    final path = main.currentPath;
    final d = main.duration;
    if (path == null || d == null || !_ready) return;
    _preparing = true;
    final tail = _tail ??= _makeTail();
    try {
      await tail.load(path, d - fade);
    } catch (e) {
      errorLog.info('Transição', 'Não deu para preparar a transição suave', e);
      _preparing = false;
      return; // não deu para abrir: a música termina do jeito normal
    }
    if (gen != _gen || main.currentPath != path || !_ready) {
      _preparing = false;
      unawaited(tail.stop());
      _schedule();
      return;
    }
    final wait = d - fade - main.position - _handoff;
    if (wait < const Duration(milliseconds: -300) || wait > _preload * 2) {
      _preparing = false;
      unawaited(tail.stop());
      _schedule(); // voltou a música enquanto preparava: marca de novo (ou já passou da hora: termina normal)
      return;
    }
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () => _start(gen, path));
  }

  Future<void> _start(int gen, String path) async {
    final tail = _tail;
    final left = main.duration == null ? Duration.zero : main.duration! - main.position;
    final onTime = left <= fade + const Duration(milliseconds: 600) && left >= fade - const Duration(milliseconds: 800);
    if (tail == null || gen != _gen || main.currentPath != path || !_ready || !onTime) {
      _preparing = false;
      if (tail != null) unawaited(tail.stop());
      _schedule();
      return;
    }
    _fading = true;
    _preparing = false;
    onFadingChanged?.call();
    try {
      // o segundo player continua a música atual do ponto em que ela vai estar quando ele começar a soar
      await tail.seek(main.position + _handoff);
      await tail.setVolume(1);
      if (gen != _gen) return;
      tail.start();
      await Future<void>.delayed(_handoff);
      if (gen != _gen) return;
      await main.setVolume(0);
      await main.advance(); // a próxima entra pelo caminho normal da fila
    } catch (e) {
      errorLog.info('Transição', 'A transição suave foi cancelada no meio', e);
      if (gen == _gen) cancel();
      return;
    }
    if (gen != _gen) return;
    final steps = fade.inMilliseconds / _tick.inMilliseconds;
    _ramp = Timer.periodic(_tick, (timer) {
      if (gen != _gen) return;
      final t = timer.tick / steps;
      final (out, inn) = crossfadeVolumes(t);
      if (t >= 1) {
        _finish();
      } else {
        unawaited(tail.setVolume(out));
        unawaited(main.setVolume(inn));
      }
    });
  }

  void _finish() {
    _ramp?.cancel();
    _ramp = null;
    _fading = false;
    unawaited(_tail?.stop());
    unawaited(main.setVolume(1));
    onFadingChanged?.call();
    _schedule();
  }

  /// Comando do usuário (próxima, anterior, escolher música, seek, nova fila, desligar):
  /// desmarca a transição e, se ela estava acontecendo, para o final da música que saía na hora.
  void cancel() {
    _gen++;
    _timer?.cancel();
    _timer = null;
    _ramp?.cancel();
    _ramp = null;
    final wasActive = _fading || _preparing;
    _preparing = false;
    if (_fading) {
      _fading = false;
      onFadingChanged?.call();
    }
    if (wasActive) {
      unawaited(_tail?.stop());
      unawaited(main.setVolume(1));
    }
  }

  /// Depois de um comando do usuário: marca a próxima transição natural (a função continua ligada).
  void reschedule() => _schedule();

  Future<void> dispose() async {
    cancel();
    await _sub?.cancel();
    await _tail?.dispose();
  }
}

/// [FadeDeck] em cima do player do just_audio.
class JustAudioDeck implements FadeDeck {
  final AudioPlayer player;
  JustAudioDeck(this.player);

  @override
  Duration get position => player.position;
  @override
  Duration? get duration => player.duration;
  @override
  bool get playing => player.playing && player.processingState != ProcessingState.completed;
  @override
  bool get canAdvance => player.loopMode != LoopMode.one && player.hasNext;

  @override
  String? get currentPath {
    final i = player.currentIndex;
    final seq = player.sequence;
    if (i == null || i < 0 || i >= seq.length) return null;
    final s = seq[i];
    return s is UriAudioSource && s.uri.isScheme('file') ? s.uri.toFilePath() : null;
  }

  @override
  Future<void> setVolume(double v) => player.setVolume(v);
  @override
  Future<void> advance() => player.seekToNext();

  @override
  Stream<void> get changes {
    late final StreamController<void> c;
    final subs = <StreamSubscription<Object?>>[];
    c = StreamController<void>(
      onListen: () {
        for (final s in <Stream<Object?>>[
          player.playingStream,
          player.currentIndexStream,
          player.durationStream,
          player.positionDiscontinuityStream,
          player.loopModeStream,
          player.sequenceStream,
          player.processingStateStream,
        ]) {
          subs.add(s.listen((_) => c.add(null), onError: (Object _, StackTrace _) {}));
        }
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return c.stream;
  }
}

/// [TailDeck] com um segundo player do just_audio. Não pede o foco de áudio nem cuida de interrupções:
/// quem manda é o player principal (se ele pausar, a transição é cancelada e este para junto).
class JustAudioTail implements TailDeck {
  final AudioPlayer _p = AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: false);
  String? _loaded;

  @override
  Future<void> load(String path, Duration at) async {
    if (_loaded != path) {
      await _p.setAudioSource(AudioSource.file(path), initialPosition: at);
      _loaded = path;
    } else {
      await _p.seek(at);
    }
  }

  @override
  Future<void> seek(Duration at) => _p.seek(at);
  @override
  void start() => unawaited(_p.play());
  @override
  Future<void> setVolume(double v) => _p.setVolume(v);

  @override
  Future<void> stop() async {
    _loaded = null;
    await _p.stop(); // solta o arquivo e o decodificador até a próxima transição
  }

  @override
  Future<void> dispose() => _p.dispose();
}
