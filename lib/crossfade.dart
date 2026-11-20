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
/// Como funciona: pouco antes dos últimos [fadeOut], o finalzinho da música atual é preparado
/// num segundo player (só esse arquivo, lido do disco aos poucos, sem carregar na memória), já parado
/// no ponto exato da troca e com o som carregado. Na hora, o segundo player só recebe o "toca" (sem buscar
/// de novo), os dois se cruzam rapidinho no mesmo trecho da música, o player principal fica mudo e passa
/// para a próxima faixa, e os dois volumes se cruzam com as músicas tocando juntas: a que sai desce em [fadeOut]
/// e a que entra sobe em [fadeIn] (os dois começam no mesmo instante; podem ter tamanhos diferentes).
/// No fim, o segundo player para e solta o arquivo; o principal segue normal, com a fila, a notificação
/// e o histórico de sempre (a troca de faixa é a mesma de quando uma música termina).
///
/// Avanço manual nunca usa crossfade: a transição só é marcada pelo relógio da música chegando ao fim,
/// e qualquer comando do usuário ([cancel]) desmarca ou interrompe a transição na hora.
class Crossfader {
  final FadeDeck main;
  final TailDeck Function() _makeTail;

  /// Quanto tempo a música que acaba leva para sumir (a transição começa esse tempo antes do fim).
  Duration fadeOut;

  /// Quanto tempo a próxima leva para chegar ao volume cheio.
  Duration fadeIn;

  Duration get fade => fadeOut;

  /// Tempo para o segundo player abrir o arquivo antes da transição.
  static const _preload = Duration(milliseconds: 1500);

  /// Quanto o som do segundo player demora para sair depois do "toca": ele já está parado no ponto
  /// certo e com o som carregado, então é só o caminho até o alto-falante (curto e quase igual sempre).
  static const _startLag = Duration(milliseconds: 60);

  /// Troca rápida entre os dois players tocando o mesmo trecho da mesma música. Em vez de um corte seco
  /// (que vira buraco se o segundo atrasa um pouco), os dois se cruzam nesse tempo e qualquer diferença
  /// de alguns milissegundos fica escondida.
  static const _swap = Duration(milliseconds: 150);

  /// O relógio da transição acorda um pouco antes e confere a posição de novo, para errar menos.
  static const _aimEarly = Duration(milliseconds: 250);

  /// Se o celular estava ocupado e o "toca" saiu mais atrasado que isso, o segundo player é reposicionado.
  static const _maxLate = Duration(milliseconds: 40);

  /// Plano B quando precisou reposicionar: tempo médio para o segundo player buscar o ponto e soar.
  static const _seekHandoff = Duration(milliseconds: 150);

  static const _tick = Duration(milliseconds: 25);

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

  Crossfader(this.main, this._makeTail, {this.fadeOut = defaultFadeOut, this.fadeIn = defaultFadeIn}) {
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

  /// Troca os tempos. Se uma transição já está acontecendo, ela termina com os tempos antigos;
  /// se só estava marcada (ou preparando), é marcada de novo com os novos.
  void setTimes(Duration out, Duration inn) {
    if (out == fadeOut && inn == fadeIn) return;
    fadeOut = out;
    fadeIn = inn;
    if (_fading) return;
    if (_timer != null || _preparing) cancel();
    _schedule();
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

  /// Quando devolve true, não faz transição (ex.: podcast tocando ou entrando: conversa não tem crossfade).
  bool Function()? hold;

  bool get _ready {
    if (!_enabled || !main.playing || !main.canAdvance) return false;
    if (hold?.call() ?? false) return false;
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
    final at = d - fade; // ponto exato em que o segundo player assume a música que sai
    try {
      await tail.load(path, at);
      await tail.setVolume(0); // só aparece na troca rápida
    } catch (e) {
      errorLog.info('Transição', 'Não deu para preparar a transição suave', e);
      _preparing = false;
      return; // não deu para abrir: a música termina do jeito normal
    }
    if (!_stillValid(gen, path, at)) return;
    _timer = Timer(_untilStart(at) - _aimEarly, () => _aim(gen, path, at));
  }

  /// Quanto falta para dar o "toca" no segundo player (contando o tempo que o som leva para sair).
  Duration _untilStart(Duration at) {
    final w = at - _startLag - main.position;
    return w.isNegative ? Duration.zero : w;
  }

  /// Confere se a transição preparada ainda vale; se não, solta o segundo player e marca de novo.
  bool _stillValid(int gen, String path, Duration at) {
    final wait = at - _startLag - main.position;
    if (gen == _gen && main.currentPath == path && _ready && wait >= const Duration(milliseconds: -300) && wait <= _preload * 2) {
      return true;
    }
    _preparing = false;
    unawaited(_tail?.stop());
    _schedule(); // voltou a música enquanto preparava: marca de novo (ou já passou da hora: termina normal)
    return false;
  }

  /// Acordou um pouco antes: mede a posição de novo e marca o "toca" no milissegundo certo.
  void _aim(int gen, String path, Duration at) {
    if (!_stillValid(gen, path, at)) return;
    _timer = Timer(_untilStart(at), () => _start(gen, path, at));
  }

  Future<void> _start(int gen, String path, Duration at) async {
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
      // Normal: o segundo player já está parado em [at], com o som carregado; é só mandar tocar.
      // Sem buscar de novo, que era a parte demorada e de tempo imprevisível.
      var lag = _startLag;
      final late = main.position - (at - _startLag);
      if (late > _maxLate) {
        // o celular atrasou o relógio: reposiciona (plano B, como era antes)
        await tail.seek(main.position + _seekHandoff);
        if (gen != _gen) return;
        lag = _seekHandoff;
      }
      tail.start();
      await Future<void>.delayed(lag);
      if (gen != _gen) return;
    } catch (e) {
      _abort(gen, e);
      return;
    }
    // troca rápida (linear, porque é a mesma música: os volumes somam sempre 1)
    final swapMs = _swap.inMilliseconds;
    _ramp = Timer.periodic(_tick, (timer) {
      if (gen != _gen) return;
      final x = (timer.tick * _tick.inMilliseconds / swapMs).clamp(0.0, 1.0);
      unawaited(tail.setVolume(x));
      if (x < 1) {
        unawaited(main.setVolume(1 - x));
        return;
      }
      timer.cancel();
      _ramp = null;
      unawaited(_advanceAndFade(gen, tail));
    });
  }

  void _abort(int gen, Object e) {
    errorLog.info('Transição', 'A transição suave foi cancelada no meio', e);
    if (gen == _gen) cancel();
  }

  Future<void> _advanceAndFade(int gen, TailDeck tail) async {
    try {
      await main.setVolume(0); // o principal só troca de faixa depois de mudo
      if (gen != _gen) return;
      await main.advance(); // a próxima entra pelo caminho normal da fila
    } catch (e) {
      _abort(gen, e);
      return;
    }
    if (gen != _gen) return;
    final outMs = fadeOut.inMilliseconds, inMs = fadeIn.inMilliseconds;
    var tailOn = true;
    _ramp = Timer.periodic(_tick, (timer) {
      if (gen != _gen) return;
      final ms = timer.tick * _tick.inMilliseconds;
      final tOut = ms / outMs, tIn = inMs == 0 ? 1.0 : ms / inMs;
      final (out, inn) = fadeVolumes(tOut, tIn);
      if (tOut >= 1 && tIn >= 1) {
        _finish();
        return;
      }
      if (tOut >= 1) {
        if (tailOn) unawaited(tail.stop()); // a que saía acabou; a próxima ainda está subindo
        tailOn = false;
      } else {
        unawaited(tail.setVolume(out));
      }
      unawaited(main.setVolume(inn));
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
      await _p.setAudioSource(_source(path), initialPosition: at);
      _loaded = path;
    } else {
      await _p.seek(at);
    }
    // só volta quando o som do ponto [at] já está carregado (o "toca" depois sai na hora)
    if (_p.processingState != ProcessingState.ready) {
      await _p.processingStateStream.firstWhere((s) => s == ProcessingState.ready).timeout(const Duration(seconds: 3));
    }
  }

  /// MP3 com taxa variável: sem isso o Android "chuta" a posição pelo tamanho do arquivo e o segundo
  /// player pode cair alguns décimos de segundo fora do lugar (a música dá um pulinho na troca). Com o
  /// índice ele lê o arquivo até o ponto e cai no lugar exato. Só para o segundo player, que tem tempo.
  static AudioSource _source(String path) => ProgressiveAudioSource(
    Uri.file(path),
    options: const ProgressiveAudioSourceOptions(
      androidExtractorOptions: AndroidExtractorOptions(mp3Flags: AndroidExtractorOptions.flagMp3EnableIndexSeeking),
    ),
  );

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
