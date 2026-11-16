import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/crossfade.dart';

/// Player principal falso: o relógio do fake_async faz a música andar.
class FakeMain implements FadeDeck {
  final FakeAsync async;
  final List<String> queue;
  int index = 0;
  bool loopOne = false;
  bool _playing = false;
  Duration _base = Duration.zero;
  Duration _since = Duration.zero;
  double volume = 1;
  final volumes = <double>[];
  int advances = 0;
  final _changes = StreamController<void>.broadcast(sync: true);
  @override
  Duration? duration = const Duration(seconds: 60);

  FakeMain(this.async, this.queue);

  @override
  Duration get position => _playing ? _base + (async.elapsed - _since) : _base;
  @override
  bool get playing => _playing;
  @override
  bool get canAdvance => !loopOne && index + 1 < queue.length;
  @override
  String? get currentPath => queue[index];
  @override
  Future<void> setVolume(double v) async {
    volume = v;
    volumes.add(v);
  }

  void play() {
    _since = async.elapsed;
    _playing = true;
    _changes.add(null);
  }

  void pause() {
    _base = position;
    _playing = false;
    _changes.add(null);
  }

  void seek(Duration d) {
    _base = d;
    _since = async.elapsed;
    _changes.add(null);
  }

  /// Comando manual (botão próxima / escolher na fila).
  void jump(int i) {
    index = i;
    seek(Duration.zero);
  }

  @override
  Future<void> advance() async {
    advances++;
    jump(index + 1);
  }

  /// Fim natural sem crossfade (o player troca de faixa sozinho).
  void tick() {
    if (_playing && position >= duration! && index + 1 < queue.length) jump(index + 1);
  }

  @override
  Stream<void> get changes => _changes.stream;
}

class FakeTail implements TailDeck {
  String? loaded;
  bool playing = false;
  double volume = 1;
  int loads = 0;
  @override
  Future<void> load(String path, Duration at) async {
    loads++;
    loaded = path;
  }

  @override
  Future<void> seek(Duration at) async {}
  @override
  void start() => playing = true;
  @override
  Future<void> setVolume(double v) async => volume = v;
  @override
  Future<void> stop() async {
    playing = false;
    loaded = null;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late FakeTail tail;
  (FakeMain, Crossfader) setup(FakeAsync a, {bool on = true}) {
    tail = FakeTail();
    final m = FakeMain(a, ['/a.mp3', '/b.mp3', '/c.mp3']);
    final c = Crossfader(m, () => tail)..enabled = on;
    return (m, c);
  }

  test('curva de volume suave: sem buraco nem estouro no meio', () {
    expect(crossfadeVolumes(0), (1.0, 0.0));
    final (o, i) = crossfadeVolumes(.5);
    expect(o, closeTo(.707, .01));
    expect(i, closeTo(.707, .01));
    for (var t = 0.0; t <= 1; t += .05) {
      final (a, b) = crossfadeVolumes(t);
      expect(a * a + b * b, closeTo(1, 1e-9)); // potência constante
    }
    expect(crossfadeVolumes(1).$1, closeTo(0, 1e-9));
  });

  test('fim natural: as duas tocam juntas, uma desce e a outra sobe, e no fim só sobra a próxima', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.play();
      a.elapse(const Duration(seconds: 54));
      expect(tail.loaded, isNull, reason: 'só prepara perto do fim');
      a.elapse(const Duration(milliseconds: 1000)); // 55s: preparou o final da atual
      expect(tail.loaded, '/a.mp3');
      expect(tail.playing, isFalse);
      a.elapse(const Duration(milliseconds: 1100)); // 56,1s: começou a transição
      expect(tail.playing, isTrue);
      expect(m.advances, 1);
      expect(m.currentPath, '/b.mp3');
      a.elapse(const Duration(seconds: 2));
      expect(tail.playing, isTrue, reason: 'sobreposição real');
      expect(tail.volume, inInclusiveRange(.5, .9));
      expect(m.volume, inInclusiveRange(.5, .9));
      a.elapse(const Duration(milliseconds: 2200));
      expect(tail.playing, isFalse, reason: 'a música anterior parou');
      expect(m.volume, 1);
      expect(m.advances, 1, reason: 'uma troca só (sem registro duplicado)');
    });
  });

  test('desligado: nada de segundo player, a música termina como antes', () {
    fakeAsync((a) {
      final (m, _) = setup(a, on: false);
      m.play();
      a.elapse(const Duration(seconds: 61));
      expect(tail.loads, 0);
      expect(m.advances, 0);
      expect(m.volumes, isEmpty);
    });
  });

  test('avanço manual antes do fim: troca na hora, sem transição, e a próxima ainda terá crossfade', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      a.elapse(const Duration(seconds: 20));
      c.cancel(); // o PlayerService chama antes de qualquer comando do usuário
      m.jump(1);
      a.elapse(const Duration(seconds: 30));
      expect(tail.loads, 0);
      expect(m.advances, 0);
      a.elapse(const Duration(seconds: 27)); // fim natural da segunda música
      expect(m.advances, 1);
      expect(m.currentPath, '/c.mp3');
    });
  });

  test('avanço manual DURANTE a transição: o final da anterior para na hora', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      a.elapse(const Duration(seconds: 57));
      expect(tail.playing, isTrue);
      c.cancel();
      m.jump(2);
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      expect(c.fading, isFalse);
      a.elapse(const Duration(seconds: 3));
      expect(m.volume, 1, reason: 'a rampa não continua depois de cancelada');
    });
  });

  test('pausar durante a transição para o som que sobrava; preparar e pausar também cancela', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      a.elapse(const Duration(seconds: 57));
      m.pause();
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      expect(c.fading, isFalse);
    });
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.play();
      a.elapse(const Duration(milliseconds: 55200)); // preparado
      m.pause();
      a.elapse(const Duration(seconds: 10));
      expect(tail.playing, isFalse);
      expect(m.advances, 0);
    });
  });

  test('seek para trás remarca; repetir a faixa e última da fila não têm transição', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      a.elapse(const Duration(milliseconds: 55200));
      c.cancel();
      m.seek(const Duration(seconds: 10));
      a.elapse(const Duration(seconds: 30));
      expect(m.advances, 0);
      a.elapse(const Duration(seconds: 20)); // 60s - 4s = 56s na música
      expect(m.advances, 1);
    });
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.loopOne = true;
      m.play();
      a.elapse(const Duration(seconds: 59));
      expect(tail.loads, 0);
    });
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.jump(2);
      m.play();
      a.elapse(const Duration(seconds: 59));
      expect(tail.loads, 0);
    });
  });

  test('desligar no meio termina a transição; ligar de novo vale para a próxima', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      a.elapse(const Duration(seconds: 57));
      c.enabled = false;
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      c.enabled = true;
      a.elapse(const Duration(seconds: 56));
      expect(m.advances, 2);
    });
  });

  test('música curtinha (menos de 12s) não tem transição', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.duration = const Duration(seconds: 10);
      m.play();
      a.elapse(const Duration(seconds: 9));
      expect(tail.loads, 0);
    });
  });
}
