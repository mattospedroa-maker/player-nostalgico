import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show Listenable;
import 'package:just_audio/just_audio.dart';

import 'error_log.dart';

/// Tempos padrão da transição suave (o usuário ajusta em Opções → Reprodução).
const defaultFadeOut = Duration(seconds: 4);
const defaultFadeIn = Duration(seconds: 4);

/// Limites dos controles em Opções (em segundos). A saída precisa de pelo menos 1 s;
/// a entrada pode ser 0 (a próxima já começa no volume cheio).
const fadeOutRange = (1, 15);
const fadeInRange = (0, 15);

/// Curva de volume de potência constante: no meio as duas ficam em ~71%, então a soma não "afunda"
/// nem estoura. [t] vai de 0 (começo) a 1 (fim). Devolve (volume da que sai, volume da que entra).
(double, double) crossfadeVolumes(double t) => fadeVolumes(t, t);

/// Volumes com saída e entrada de tamanhos diferentes: [tOut] é quanto da saída já passou (0 a 1)
/// e [tIn] quanto da entrada. Cada um segue a mesma curva de potência constante.
(double, double) fadeVolumes(double tOut, double tIn) => (cos(tOut.clamp(0.0, 1.0) * pi / 2), sin(tIn.clamp(0.0, 1.0) * pi / 2));

/// O que a janela Opções mexe da transição (o PlayerService; um falso nos testes).
abstract class CrossfadeSettings implements Listenable {
  bool get crossfade;
  Duration get fadeOut;
  Duration get fadeIn;
  void setCrossfade(bool on);
  void setCrossfadeTimes(Duration out, Duration inn);
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

  /// Arquivo que entra depois deste (null se não tem).
  String? get nextPath;
  Future<void> setVolume(double v);

  /// Passa para a próxima música da fila, do começo (como se a atual tivesse terminado).
  Future<void> advance();

  /// Passa (mudo) para a música [path], que é a próxima da fila (ou já é a atual), no ponto [at].
  Future<void> advanceTo(String path, Duration at);

  /// Reposiciona a música atual (só usado com o player principal mudo).
  Future<void> seek(Duration at);

  /// Avisa quando algo que muda o horário da transição acontece (play/pause, troca de faixa, seek, fila, repetir).
  Stream<void> get changes;
}

/// Segundo player: toca a música que entra desde o começo e, depois, até o fim dela.
abstract class TailDeck {
  /// Abre [path] parado no começo, com o som já carregado (o "toca" depois sai na hora).
  Future<void> load(String path);
  void start();
  Duration get position;
  Duration? get duration;
  Future<void> setVolume(double v);
  Future<void> stop();
  Future<void> dispose();
}

enum _Phase {
  /// Só o principal tocando, nada preparado.
  idle,

  /// Abrindo a próxima música no segundo player.
  preparing,

  /// A próxima está no segundo player, parada no começo e muda, esperando a hora.
  ready,

  /// Transição 1: o principal termina a música dele sumindo; o segundo player começa a próxima do zero.
  fadeA,

  /// O segundo player é quem soa a música inteira; o principal acompanha mudo (fila, tela, notificação).
  owned,

  /// Transição 2: o segundo player termina a música dele sumindo; o principal começa a próxima do zero.
  fadeB,
}

/// Crossfade só no fim natural da música, com os dois players se revezando.
///
/// Por que assim: antes o segundo player assumia o FINAL da mesma música que o principal estava tocando,
/// no meio dela. Dois players nunca ficam alinhados no milissegundo, então qualquer diferença virava
/// uma travadinha (um pedacinho repetido ou pulado) e, se o segundo demorava a soar, um clique.
/// Agora nenhuma música troca de player no meio enquanto se ouve:
///
/// - Transição 1 (o principal está soando): a próxima já está aberta no segundo player, parada no começo.
///   Na hora, ele começa do zero e sobe; o principal só desce até o fim da música dele. Quando a que sai
///   já sumiu, o principal passa mudo para a próxima, no mesmo ponto do segundo player, e fica acompanhando
///   (a tela, a fila, a notificação e o histórico continuam vindo dele).
/// - Transição 2 (o segundo player está soando): o principal, mudo, pula para a próxima do começo e sobe;
///   o segundo player só desce até o fim da música dele e para. O principal volta a ser quem soa.
///
/// Os volumes seguem a posição real de cada música (não um relógio separado): se o celular atrasar
/// um pouco, a curva continua no ponto certo, e uma música que demora a começar entra no volume ~0,
/// sem estalo.
///
/// Avanço manual nunca usa crossfade, e qualquer comando do usuário ([cancel]) volta tudo para o
/// principal na hora (se o segundo player estava soando, o principal assume do ponto em que estava).
class Crossfader {
  final FadeDeck main;
  final TailDeck Function() _makeTail;

  /// Quanto tempo a música que acaba leva para sumir (a transição começa esse tempo antes do fim).
  Duration fadeOut;

  /// Quanto tempo a próxima leva para chegar ao volume cheio.
  Duration fadeIn;

  Duration get fade => fadeOut;

  /// Com quanta antecedência a próxima música é aberta no segundo player (com folga, para estar
  /// pronta mesmo com o celular ocupado).
  static const _preload = Duration(seconds: 8);

  /// A que sai chega ao volume zero um pouco antes do fim real do arquivo (a duração do MP3 é estimada).
  static const _endMargin = Duration(milliseconds: 200);

  /// O principal mudo é posicionado um tiquinho à frente, para compensar o tempo de buscar.
  static const _seekLag = Duration(milliseconds: 40);

  /// Diferença tolerada entre o principal mudo e o segundo player antes de reposicionar.
  static const _maxDrift = Duration(milliseconds: 60);
  static const _alignAfter = Duration(milliseconds: 1500);

  static const _tick = Duration(milliseconds: 20);

  TailDeck? _tail;
  StreamSubscription<void>? _sub;
  Timer? _timer;
  Timer? _ramp;
  Timer? _align;
  int _gen = 0;
  bool _enabled = false;
  _Phase _phase = _Phase.idle;

  /// Música aberta (ou tocando) no segundo player.
  String? _tailPath;

  /// Transição 1: música que está saindo pelo principal. Transição 2: a que entrou no principal.
  String? _mainPath;

  /// Posição (na música que sai) em que a descida começou.
  Duration _outFrom = Duration.zero;

  /// Tempos da transição em andamento (trocar nas Opções não mexe nela).
  Duration _curOut = defaultFadeOut;
  Duration _curIn = defaultFadeIn;

  /// Transição 1: o principal já está indo (mudo) para a próxima.
  bool _handing = false;

  /// Transição 2: o principal já está na próxima / o segundo player já parou.
  bool _mainIn = false;
  bool _tailOut = false;

  /// Último volume mandado para cada player (evita mandar o mesmo valor de novo).
  double? _mainVol;
  double? _tailVol;

  /// Avisado quando uma transição começa ou termina.
  void Function()? onFadingChanged;

  /// Quando devolve true, não faz transição (ex.: podcast tocando ou entrando: conversa não tem crossfade).
  bool Function()? hold;

  Crossfader(this.main, this._makeTail, {this.fadeOut = defaultFadeOut, this.fadeIn = defaultFadeIn}) {
    _sub = main.changes.listen((_) => _onChange());
  }

  bool get enabled => _enabled;
  bool get fading => _phase == _Phase.fadeA || _phase == _Phase.fadeB;

  /// O segundo player é quem está soando a música atual (o principal acompanha mudo).
  bool get tailOwns => _phase == _Phase.owned;

  set enabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    if (v) {
      _onChange();
    } else {
      cancel(); // desligou no meio: termina na hora, sem sobrar som
    }
  }

  /// Troca os tempos. Uma transição em andamento termina com os tempos antigos; a próxima usa os novos.
  void setTimes(Duration out, Duration inn) {
    if (out == fadeOut && inn == fadeIn) return;
    fadeOut = out;
    fadeIn = inn;
    _onChange();
  }

  /// Depois de um comando do usuário: marca a próxima transição natural (a função continua ligada).
  void reschedule() => _onChange();

  // ---------- quem está soando ----------

  Duration? get _soundingDuration => _phase == _Phase.owned ? (_tail?.duration ?? main.duration) : main.duration;

  bool get _ready {
    if (!_enabled || !main.playing || !main.canAdvance) return false;
    if (hold?.call() ?? false) return false;
    final d = _soundingDuration;
    return d != null && d >= fadeOut * 3; // música curtinha não tem crossfade
  }

  void _onChange() {
    switch (_phase) {
      case _Phase.fadeA:
        if (!main.playing) return cancel(); // pausou (ou o sistema pausou) no meio
        final p = main.currentPath;
        if (p == _mainPath || _handing) return;
        if (p == _tailPath) {
          // o arquivo acabou antes do previsto: o principal já está na próxima. Emudece na hora e
          // alinha logo em seguida (fora deste aviso, que ainda está sendo entregue)
          unawaited(_setMain(0));
          final gen = _gen;
          scheduleMicrotask(() => unawaited(_handOver(gen)));
          return;
        }
        cancel();
      case _Phase.owned:
        final tail = _tail;
        if (tail == null || !main.playing || main.currentPath != _tailPath) return cancel();
        // "repetir uma" fez o principal voltar ao começo: ele assume (as duas estão na virada da música)
        if (main.position + const Duration(seconds: 2) < tail.position) return cancel();
        _scheduleSwitchBack();
      case _Phase.fadeB:
        if (!main.playing) return cancel();
        if (_mainIn && main.currentPath != _mainPath) cancel();
      case _Phase.idle:
      case _Phase.preparing:
      case _Phase.ready:
        _schedule();
    }
  }

  // ---------- transição 1: principal sai, segundo player entra ----------

  /// Marca a preparação ou o começo da transição 1 (ou desmarca, se não cabe).
  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_phase == _Phase.preparing) return; // a preparação confere tudo de novo no fim
    if (!_ready) return _dropTail();
    final left = main.duration! - main.position;
    final startIn = left - fadeOut - _endMargin;
    if (startIn < -const Duration(milliseconds: 300)) return _dropTail(); // tarde demais: termina normal
    if (_phase == _Phase.ready) {
      if (_tailPath == main.nextPath && startIn <= _preload * 2) {
        _timer = Timer(_atLeastZero(startIn), () => _startA(_gen));
        return;
      }
      _dropTail(); // a fila mudou, ou voltou a música: abre de novo mais perto da hora
    }
    _timer = Timer(_atLeastZero(startIn - _preload), () => unawaited(_prepare(_gen)));
  }

  Future<void> _prepare(int gen) async {
    final path = main.nextPath;
    if (gen != _gen || _phase != _Phase.idle || path == null || !_ready) return;
    _phase = _Phase.preparing;
    final tail = _tail ??= _makeTail();
    try {
      await tail.load(path);
      _tailVol = null;
      await _setTail(0); // só aparece na transição
    } catch (e) {
      if (gen != _gen) return;
      errorLog.info('Transição', 'Não deu para preparar a transição suave', e);
      _phase = _Phase.idle;
      _tailPath = null;
      unawaited(tail.stop().catchError((Object _) {}));
      return; // não deu para abrir: a música termina do jeito normal
    }
    if (gen != _gen) return; // um comando do usuário já desfez tudo
    _phase = _Phase.ready;
    _tailPath = path;
    _schedule();
  }

  void _startA(int gen) {
    if (gen != _gen || _phase != _Phase.ready) return;
    final tail = _tail;
    final left = main.duration == null ? Duration.zero : main.duration! - main.position;
    if (tail == null || !_ready || main.nextPath != _tailPath || left < _endMargin + const Duration(milliseconds: 300)) {
      _dropTail();
      _schedule();
      return;
    }
    _curOut = fadeOut;
    _curIn = fadeIn;
    _phase = _Phase.fadeA;
    _mainPath = main.currentPath;
    _outFrom = main.duration! - _curOut - _endMargin;
    _handing = false;
    onFadingChanged?.call();
    tail.start(); // começa do zero, mudo: a curva sobe pela posição real dela
    _startRamp(gen);
  }

  /// A que saía pelo principal já sumiu: o principal passa, mudo, para a próxima no ponto do segundo player.
  Future<void> _handOver(int gen) async {
    final tail = _tail;
    final path = _tailPath;
    if (gen != _gen || _phase != _Phase.fadeA || _handing || tail == null || path == null) return;
    _handing = true;
    unawaited(_setMain(0));
    try {
      await main.advanceTo(path, tail.position + _seekLag);
    } catch (e) {
      _abort(gen, e);
      return;
    }
    if (gen != _gen) return;
    _handing = false;
    _mainPath = null;
    _phase = _Phase.owned;
    onFadingChanged?.call();
    _alignLater(gen, 2);
    _scheduleSwitchBack();
  }

  /// Confere se o principal mudo está no mesmo ponto do segundo player (para o caso de você pausar
  /// ou buscar: aí o principal volta a soar de onde estava).
  void _alignLater(int gen, int tries) {
    _align?.cancel();
    _align = Timer(_alignAfter, () async {
      final tail = _tail;
      if (gen != _gen || _phase != _Phase.owned || tail == null || main.currentPath != _tailPath) return;
      final drift = main.position - tail.position;
      if (drift.abs() <= _maxDrift) return;
      try {
        await main.seek(tail.position + _seekLag);
      } catch (_) {
        return;
      }
      if (tries > 1) _alignLater(gen, tries - 1);
    });
  }

  // ---------- transição 2: segundo player sai, principal entra ----------

  void _scheduleSwitchBack() {
    _timer?.cancel();
    _timer = null;
    final tail = _tail;
    if (_phase != _Phase.owned || tail == null || !_ready) return; // sem transição: o principal assume na virada
    final d = _soundingDuration!;
    final startIn = d - tail.position - fadeOut - _endMargin;
    if (startIn < -const Duration(milliseconds: 300)) return;
    _timer = Timer(_atLeastZero(startIn), () => unawaited(_startB(_gen)));
  }

  Future<void> _startB(int gen) async {
    final tail = _tail;
    if (gen != _gen || _phase != _Phase.owned || tail == null) return;
    if (!_ready || main.currentPath != _tailPath || main.nextPath == null) return;
    _curOut = fadeOut;
    _curIn = fadeIn;
    _phase = _Phase.fadeB;
    _outFrom = _soundingDuration! - _curOut - _endMargin;
    _mainIn = false;
    _tailOut = false;
    _align?.cancel();
    onFadingChanged?.call();
    _startRamp(gen);
    try {
      await _setMain(0);
      await main.advance(); // a próxima entra do começo pelo caminho normal da fila (ainda muda)
    } catch (e) {
      _abort(gen, e);
      return;
    }
    if (gen != _gen) return;
    _mainPath = main.currentPath;
    _mainIn = true;
  }

  // ---------- volumes ----------

  void _startRamp(int gen) {
    _ramp?.cancel();
    _ramp = Timer.periodic(_tick, (_) => _step(gen));
    _step(gen);
  }

  void _step(int gen) {
    final tail = _tail;
    if (gen != _gen || tail == null) return;
    switch (_phase) {
      case _Phase.fadeA:
        unawaited(_setTail(_rise(tail.position)));
        if (_handing) return;
        final tOut = _frac(main.position - _outFrom, _curOut);
        unawaited(_setMain(cos(tOut * pi / 2)));
        if (tOut >= 1) unawaited(_handOver(gen));
      case _Phase.owned:
        final v = _rise(tail.position);
        unawaited(_setTail(v));
        if (v >= 1) _stopRamp(); // a próxima chegou ao volume cheio
      case _Phase.fadeB:
        if (!_tailOut) {
          final tOut = _frac(tail.position - _outFrom, _curOut);
          unawaited(_setTail(cos(tOut * pi / 2)));
          if (tOut >= 1) {
            _tailOut = true; // a que saía acabou de sumir: solta o arquivo e o decodificador
            _tailPath = null;
            unawaited(tail.stop().catchError((Object _) {}));
          }
        }
        if (_mainIn) {
          final v = _rise(main.position);
          unawaited(_setMain(v));
          if (v >= 1 && _tailOut) _finish();
        }
      case _Phase.idle:
      case _Phase.preparing:
      case _Phase.ready:
        _stopRamp();
    }
  }

  /// Volume da que entra, pela posição dela (começa em 0, chega a 1 depois de [_curIn]).
  double _rise(Duration pos) => _curIn == Duration.zero ? 1.0 : sin(_frac(pos, _curIn) * pi / 2);

  static double _frac(Duration part, Duration total) =>
      total <= Duration.zero ? 1.0 : (part.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);

  static Duration _atLeastZero(Duration d) => d.isNegative ? Duration.zero : d;

  Future<void> _setMain(double v) {
    if (_mainVol != null && (_mainVol! - v).abs() < 0.002 && v != 0 && v != 1) return Future.value();
    if (_mainVol == v) return Future.value();
    _mainVol = v;
    return main.setVolume(v).catchError((Object _) {});
  }

  Future<void> _setTail(double v) {
    final tail = _tail;
    if (tail == null) return Future.value();
    if (_tailVol != null && (_tailVol! - v).abs() < 0.002 && v != 0 && v != 1) return Future.value();
    if (_tailVol == v) return Future.value();
    _tailVol = v;
    return tail.setVolume(v).catchError((Object _) {});
  }

  void _stopRamp() {
    _ramp?.cancel();
    _ramp = null;
  }

  void _finish() {
    _stopRamp();
    _phase = _Phase.idle;
    _mainPath = null;
    _mainIn = false;
    _tailOut = false;
    unawaited(_setMain(1));
    onFadingChanged?.call();
    _schedule();
  }

  void _abort(int gen, Object e) {
    errorLog.info('Transição', 'A transição suave foi cancelada no meio', e);
    if (gen == _gen) cancel();
  }

  /// Solta a próxima que estava aberta e esperando (a fila mudou, voltou a música, desligou...).
  void _dropTail() {
    if (_phase != _Phase.ready) return;
    _phase = _Phase.idle;
    _tailPath = null;
    unawaited(_tail?.stop().catchError((Object _) {}));
  }

  /// Comando do usuário (próxima, anterior, escolher música, seek, pausa, nova fila, desligar):
  /// desmarca a transição; se o segundo player estava soando, ele para e o principal volta a soar na hora.
  void cancel() {
    _gen++;
    _timer?.cancel();
    _timer = null;
    _align?.cancel();
    _align = null;
    _stopRamp();
    final wasFading = fading;
    final usedTail = _phase != _Phase.idle;
    _phase = _Phase.idle;
    _tailPath = null;
    _mainPath = null;
    _handing = false;
    _mainIn = false;
    _tailOut = false;
    if (usedTail) {
      unawaited(_tail?.stop().catchError((Object _) {}));
      _mainVol = null;
      unawaited(_setMain(1));
    }
    if (wasFading) onFadingChanged?.call();
  }

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

  String? _pathAt(int? i) {
    final seq = player.sequence;
    if (i == null || i < 0 || i >= seq.length) return null;
    final s = seq[i];
    return s is UriAudioSource && s.uri.isScheme('file') ? s.uri.toFilePath() : null;
  }

  @override
  String? get currentPath => _pathAt(player.currentIndex);
  @override
  String? get nextPath => _pathAt(player.nextIndex);

  @override
  Future<void> setVolume(double v) => player.setVolume(v);
  @override
  Future<void> advance() => player.seekToNext();
  @override
  Future<void> seek(Duration at) => player.seek(at);

  @override
  Future<void> advanceTo(String path, Duration at) async {
    if (currentPath == path) return player.seek(at); // o arquivo acabou sozinho antes: já está nela
    final next = player.nextIndex;
    if (_pathAt(next) != path) throw StateError('a próxima da fila mudou durante a transição');
    await player.seek(at, index: next);
  }

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
/// quem manda é o player principal (se ele pausar, o crossfade para este e o principal volta a soar).
class JustAudioTail implements TailDeck {
  final AudioPlayer _p = AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: false);

  @override
  Future<void> load(String path) async {
    await _p.setAudioSource(AudioSource.file(path), initialPosition: Duration.zero);
    // só volta quando o começo da música já está carregado (o "toca" depois sai na hora)
    if (_p.processingState != ProcessingState.ready) {
      await _p.processingStateStream.firstWhere((s) => s == ProcessingState.ready).timeout(const Duration(seconds: 5));
    }
  }

  @override
  void start() => unawaited(_p.play().catchError((Object _) {}));
  @override
  Duration get position => _p.position;
  @override
  Duration? get duration => _p.duration;
  @override
  Future<void> setVolume(double v) => _p.setVolume(v);

  @override
  Future<void> stop() => _p.stop(); // solta o arquivo e o decodificador até a próxima transição

  @override
  Future<void> dispose() => _p.dispose();
}
