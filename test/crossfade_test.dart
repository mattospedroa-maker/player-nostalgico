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
  final advancedTo = <Duration>[];
  final seeks = <Duration>[];
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
  String? get nextPath => index + 1 < queue.length ? queue[index + 1] : null;
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

  /// O celular atrasou: a música andou sem ninguém avisar.
  void drift(Duration d) => _base += d;

  void _to(Duration d) {
    _base = d;
    _since = async.elapsed;
    _changes.add(null);
  }

  @override
  Future<void> seek(Duration d) async {
    seeks.add(d);
    _to(d);
  }

  /// Comando manual (botão próxima / escolher na fila).
  void jump(int i) {
    index = i;
    _to(Duration.zero);
  }

  @override
  Future<void> advance() async {
    advances++;
    jump(index + 1);
  }

  @override
  Future<void> advanceTo(String path, Duration at) async {
    advancedTo.add(at);
    if (currentPath != path) {
      if (nextPath != path) throw StateError('fila mudou');
      index++;
    }
    _to(at);
  }

  /// Fim natural sem crossfade (o player troca de faixa sozinho; "repetir uma" volta ao começo).
  void tick() {
    if (!_playing || position < duration!) return;
    if (loopOne) return _to(Duration.zero);
    if (index + 1 < queue.length) jump(index + 1);
  }

  /// A fila mudou (sem trocar a música atual).
  void notify() => _changes.add(null);

  @override
  Stream<void> get changes => _changes.stream;
}

class FakeTail implements TailDeck {
  final FakeAsync async;
  FakeTail(this.async);
  String? loaded;
  bool playing = false;
  double volume = 1;
  int loads = 0;
  int starts = 0;
  Duration _since = Duration.zero;
  final volumes = <double>[];
  @override
  Duration? duration = const Duration(seconds: 60);

  @override
  Future<void> load(String path) async {
    loads++;
    loaded = path;
    playing = false;
  }

  @override
  void start() {
    starts++;
    playing = true;
    _since = async.elapsed;
  }

  @override
  Duration get position {
    if (!playing) return Duration.zero;
    final p = async.elapsed - _since;
    return p > duration! ? duration! : p;
  }

  @override
  Future<void> setVolume(double v) async {
    volume = v;
    volumes.add(v);
  }

  @override
  Future<void> stop() async {
    playing = false;
    loaded = null;
  }

  @override
  Future<void> dispose() async {}
}

Duration secs(num s) => Duration(microseconds: (s * 1e6).round());

void main() {
  late FakeTail tail;
  (FakeMain, Crossfader) setup(FakeAsync a, {bool on = true, List<String>? queue}) {
    tail = FakeTail(a);
    final m = FakeMain(a, queue ?? ['/a.mp3', '/b.mp3', '/c.mp3']);
    final c = Crossfader(m, () => tail)..enabled = on;
    return (m, c);
  }

  /// Anda o relógio em passos de 20 ms, deixando o principal trocar de faixa sozinho no fim,
  /// e confere a regra de ouro a cada passo: a mesma música nunca soa nos dois players ao mesmo tempo.
  void run(FakeAsync a, FakeMain m, Duration d) {
    final end = a.elapsed + d;
    while (a.elapsed < end) {
      a.elapse(const Duration(milliseconds: 20));
      m.tick();
      if (tail.playing && tail.volume > 0 && m.volume > 0 && m.playing) {
        expect(m.currentPath, isNot(tail.loaded), reason: 'a mesma música soando nos dois players em ${a.elapsed}');
      }
    }
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

  test('curvas separadas: cada lado segue o próprio tempo', () {
    final (o, i) = fadeVolumes(1, .5);
    expect(o, closeTo(0, 1e-9));
    expect(i, closeTo(.707, .01));
    expect(fadeVolumes(0, 0), (1.0, 0.0));
  });

  test('transição 1: a próxima começa do zero no segundo player; o principal só desce a música dele', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(47));
      expect(tail.loaded, isNull, reason: 'só abre a próxima perto do fim');
      run(a, m, secs(1)); // 48s: a próxima já está aberta, parada no começo e muda
      expect(tail.loaded, '/b.mp3');
      expect(tail.playing, isFalse);
      expect(tail.volume, 0);
      run(a, m, secs(7.9)); // 55,9s: começou (4s + 0,2s antes do fim)
      expect(tail.playing, isTrue);
      expect(c.fading, isTrue);
      expect(m.currentPath, '/a.mp3', reason: 'o principal continua na música dele, sem pular');
      expect(m.volume, inInclusiveRange(.95, 1));
      expect(tail.volume, lessThan(.1));
      run(a, m, secs(2)); // meio da transição
      expect(m.volume, closeTo(.71, .05));
      expect(tail.volume, closeTo(.71, .05));
      run(a, m, secs(2)); // 59,9s: a que saía sumiu
      expect(m.currentPath, '/b.mp3', reason: 'o principal acompanha a próxima, mudo');
      expect(m.volume, 0);
      expect(m.advancedTo.single.inMilliseconds, closeTo(4040, 50), reason: 'no mesmo ponto do segundo player');
      expect(m.advances, 0);
      expect(c.tailOwns, isTrue);
      expect(c.fading, isFalse);
      expect(tail.volume, 1);
      expect(tail.starts, 1, reason: 'o segundo player só recebe o "toca", nunca uma busca');
    });
  });

  test('transição 2: o principal começa a próxima do zero e o segundo player só desce a música dele', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(60));
      expect(c.tailOwns, isTrue);
      run(a, m, secs(51.7)); // 111,7s = 55,9s da segunda música
      expect(m.advances, 1);
      expect(m.currentPath, '/c.mp3');
      expect(c.fading, isTrue);
      expect(tail.playing, isTrue, reason: 'a segunda música continua no segundo player até sumir');
      expect(m.volume, lessThan(.1));
      run(a, m, secs(2));
      expect(m.volume, closeTo(.71, .05));
      expect(tail.volume, closeTo(.71, .05));
      run(a, m, secs(2.1));
      expect(tail.playing, isFalse, reason: 'acabou e soltou o arquivo');
      expect(m.volume, 1);
      expect(c.fading, isFalse);
      expect(c.tailOwns, isFalse);
      expect(m.seeks, isEmpty, reason: 'o principal ficou alinhado, nada de buscar');
    });
  });

  test('fila longa: as transições se revezam sem nunca a mesma música nos dois players', () {
    fakeAsync((a) {
      final (m, c) = setup(a, queue: [for (var i = 0; i < 6; i++) '/$i.mp3']);
      m.play();
      run(a, m, secs(5 * 55.8 + 10));
      expect(m.currentPath, '/5.mp3');
      expect(tail.starts, 3, reason: 'transições 1, 3 e 5 usam o segundo player para a que entra');
      expect(m.advances, 2, reason: 'transições 2 e 4: o principal entra do começo');
      expect(c.fading, isFalse);
    });
  });

  test('desligado: nada de segundo player, a música termina como antes', () {
    fakeAsync((a) {
      final (m, _) = setup(a, on: false);
      m.play();
      run(a, m, secs(61));
      expect(tail.loads, 0);
      expect(m.currentPath, '/b.mp3');
      expect(m.volumes, isEmpty);
    });
  });

  test('avanço manual antes do fim: troca na hora, sem transição, e a próxima ainda terá crossfade', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(20));
      c.cancel(); // o PlayerService chama antes de qualquer comando do usuário
      m.jump(1);
      run(a, m, secs(30));
      expect(tail.loads, 0);
      run(a, m, secs(26));
      expect(tail.playing, isTrue);
      expect(tail.loaded, '/c.mp3');
    });
  });

  test('avanço manual DURANTE a transição: o final da anterior para na hora', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(57));
      expect(tail.playing, isTrue);
      c.cancel();
      m.jump(2);
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      expect(c.fading, isFalse);
      run(a, m, secs(3));
      expect(m.volume, 1, reason: 'a rampa não continua depois de cancelada');
    });
  });

  test('pausar com o segundo player soando: ele para e o principal volta a soar de onde estava', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(70));
      expect(c.tailOwns, isTrue);
      m.pause();
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      expect(c.tailOwns, isFalse);
      expect(m.currentPath, '/b.mp3');
      m.play();
      run(a, m, secs(42)); // continua no principal e a próxima transição acontece normal
      expect(tail.loaded, '/c.mp3');
      expect(tail.playing, isTrue);
    });
  });

  test('pausar durante a transição ou com a próxima preparada também cancela', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(57));
      m.pause();
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      expect(c.fading, isFalse);
    });
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.play();
      run(a, m, secs(50)); // preparada
      m.pause();
      a.elapse(secs(10));
      expect(tail.playing, isFalse);
      expect(tail.loaded, isNull);
    });
  });

  test('seek com o segundo player soando: o principal assume e busca', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(70));
      c.cancel();
      unawaited(m.seek(secs(30)));
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      run(a, m, secs(10));
      expect(m.volume, 1);
    });
  });

  test('seek para trás com a próxima preparada: solta e prepara de novo mais perto da hora', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(50));
      expect(tail.loaded, '/b.mp3');
      c.cancel();
      unawaited(m.seek(secs(10)));
      a.flushMicrotasks();
      expect(tail.loaded, isNull);
      run(a, m, secs(30));
      expect(tail.loaded, isNull);
      run(a, m, secs(16)); // 56s na música
      expect(tail.playing, isTrue);
    });
  });

  test('repetir a faixa e última da fila não têm transição', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.loopOne = true;
      m.play();
      run(a, m, secs(59));
      expect(tail.loads, 0);
    });
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.jump(2);
      m.play();
      run(a, m, secs(59));
      expect(tail.loads, 0);
    });
  });

  test('ligou "repetir uma" com o segundo player soando: o principal assume na virada da música', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(70));
      expect(c.tailOwns, isTrue);
      m.loopOne = true;
      m.notify();
      run(a, m, secs(45)); // 115s: perto do fim da segunda, sem transição
      expect(m.advances, 0);
      expect(tail.playing, isTrue);
      run(a, m, secs(1)); // o principal voltou ao começo da mesma música
      expect(c.tailOwns, isFalse);
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      expect(m.currentPath, '/b.mp3');
      expect(m.position, lessThan(secs(1)));
    });
  });

  test('desligar no meio termina a transição; ligar de novo vale para a próxima', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(57));
      c.enabled = false;
      a.flushMicrotasks();
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      c.enabled = true;
      run(a, m, secs(59)); // a primeira termina sozinha; a segunda tem transição
      expect(tail.loaded, '/c.mp3');
      expect(tail.playing, isTrue);
    });
  });

  test('música curtinha (menos de 12s) não tem transição', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.duration = secs(10);
      m.play();
      run(a, m, secs(9));
      expect(tail.loads, 0);
    });
  });

  test('saída longa e entrada curta: a próxima chega ao máximo antes, a anterior continua sumindo', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      c.setTimes(secs(8), secs(2));
      m.play();
      run(a, m, secs(51.9)); // começa 8,2s antes do fim
      expect(tail.playing, isTrue);
      run(a, m, secs(2.1));
      expect(tail.volume, 1, reason: 'a próxima já no volume cheio');
      expect(m.volume, inInclusiveRange(.6, .95), reason: 'a anterior ainda está sumindo');
      run(a, m, secs(6));
      expect(m.volume, 0);
      expect(c.tailOwns, isTrue);
    });
  });

  test('saída curta e entrada longa: a anterior some e a próxima continua subindo', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      c.setTimes(secs(2), secs(6));
      m.play();
      run(a, m, secs(57.9));
      expect(tail.playing, isTrue);
      run(a, m, secs(2.1));
      expect(c.tailOwns, isTrue);
      expect(m.volume, 0);
      expect(tail.volume, inInclusiveRange(.5, .9));
      run(a, m, secs(4.1));
      expect(tail.volume, 1);
    });
  });

  test('entrada 0: a próxima já entra no volume cheio', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      c.setTimes(secs(3), Duration.zero);
      m.play();
      run(a, m, secs(57.5));
      expect(tail.playing, isTrue);
      expect(tail.volume, 1);
      expect(m.volume, lessThan(1));
    });
  });

  test('trocar os tempos com a transição já marcada remarca no horário novo', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(40));
      c.setTimes(secs(10), secs(4));
      run(a, m, secs(9.7)); // 49,7s
      expect(tail.playing, isFalse);
      run(a, m, secs(.2)); // 49,9s: começou 10,2s antes do fim
      expect(tail.playing, isTrue);
    });
  });

  test('celular atrasado: os volumes seguem a posição real da música, sem degrau', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.play();
      run(a, m, secs(57.8));
      m.drift(secs(1)); // a música andou 1s sem ninguém ver
      run(a, m, const Duration(milliseconds: 20));
      // 58,82s na música = 3,02s dos 4s de descida
      expect(m.volume, closeTo(0.37, .03));
    });
  });

  test('o arquivo acabou antes do previsto: o principal emudece na hora e acompanha a próxima', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(58));
      m.jump(1); // o player trocou sozinho (duração estimada errada)
      a.flushMicrotasks();
      expect(m.volume, 0);
      expect(c.tailOwns, isTrue);
      expect(m.seeks, isEmpty);
      expect(m.position.inMilliseconds, closeTo(2240, 50), reason: 'no ponto do segundo player');
    });
  });

  test('a fila mudou com a próxima já preparada: abre a nova próxima', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.play();
      run(a, m, secs(50));
      expect(tail.loaded, '/b.mp3');
      m.queue[1] = '/x.mp3';
      m.notify();
      a.flushMicrotasks();
      run(a, m, const Duration(milliseconds: 40));
      expect(tail.loaded, '/x.mp3');
      run(a, m, secs(6));
      expect(tail.playing, isTrue);
    });
  });

  test('principal mudo fora do ponto: é reposicionado sem som', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      run(a, m, secs(60));
      expect(c.tailOwns, isTrue);
      m.drift(secs(.3));
      run(a, m, secs(2));
      expect(m.seeks, hasLength(1));
      expect((m.position - tail.position).abs(), lessThan(secs(.06)));
      expect(m.volume, 0);
    });
  });
}
