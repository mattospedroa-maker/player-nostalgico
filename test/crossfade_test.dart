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

  /// O celular atrasou: a música andou sem ninguém avisar (o relógio da transição acorda tarde).
  void drift(Duration d) => _base += d;

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
  Duration? loadedAt;
  final seeks = <Duration>[];
  final volumes = <double>[];
  @override
  Future<void> load(String path, Duration at) async {
    loads++;
    loaded = path;
    loadedAt = at;
  }

  @override
  Future<void> seek(Duration at) async => seeks.add(at);
  @override
  void start() => playing = true;
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
      a.elapse(const Duration(milliseconds: 100)); // depois da troca rápida, o principal passa para a próxima
      expect(m.advances, 1);
      expect(m.currentPath, '/b.mp3');
      a.elapse(const Duration(milliseconds: 1900));
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

  test('saída longa e entrada curta: a próxima chega ao máximo antes, a anterior continua sumindo', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      c.setTimes(const Duration(seconds: 8), const Duration(seconds: 2));
      m.play();
      a.elapse(const Duration(seconds: 50));
      expect(tail.loaded, isNull);
      a.elapse(const Duration(milliseconds: 2200)); // 52,2s: começa 8s antes do fim
      expect(tail.playing, isTrue);
      expect(m.currentPath, '/b.mp3');
      a.elapse(const Duration(seconds: 3)); // passou os 2s de entrada
      expect(m.volume, closeTo(1, 1e-9), reason: 'a próxima já no volume cheio');
      expect(tail.playing, isTrue, reason: 'a anterior ainda está sumindo');
      expect(tail.volume, inInclusiveRange(.3, .95));
      a.elapse(const Duration(seconds: 5));
      expect(tail.playing, isFalse);
      expect(c.fading, isFalse);
      expect(m.advances, 1);
    });
  });

  test('saída curta e entrada longa: a anterior para no fim dela e a próxima continua subindo', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      c.setTimes(const Duration(seconds: 2), const Duration(seconds: 6));
      m.play();
      a.elapse(const Duration(milliseconds: 58200)); // começa 2s antes do fim
      expect(tail.playing, isTrue);
      a.elapse(const Duration(seconds: 2, milliseconds: 300));
      expect(tail.playing, isFalse, reason: 'a anterior acabou');
      expect(c.fading, isTrue);
      expect(m.volume, inInclusiveRange(.3, .9));
      a.elapse(const Duration(seconds: 4));
      expect(c.fading, isFalse);
      expect(m.volume, 1);
    });
  });

  test('entrada 0: a próxima já entra no volume cheio', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      c.setTimes(const Duration(seconds: 3), Duration.zero);
      m.play();
      a.elapse(const Duration(milliseconds: 57300));
      expect(tail.playing, isTrue);
      a.elapse(const Duration(milliseconds: 200));
      expect(m.volume, 1);
      expect(tail.volume, lessThan(1));
    });
  });

  test('trocar os tempos com a transição já marcada remarca no horário novo', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      a.elapse(const Duration(seconds: 40));
      c.setTimes(const Duration(seconds: 10), const Duration(seconds: 4));
      a.elapse(const Duration(seconds: 8)); // 48s
      expect(tail.loaded, isNull);
      a.elapse(const Duration(milliseconds: 700)); // 48,7s
      expect(tail.loaded, '/a.mp3', reason: 'prepara antes dos 10s finais');
      a.elapse(const Duration(milliseconds: 1500)); // 50,2s
      expect(tail.playing, isTrue);
      expect(m.advances, 1);
    });
  });

  test('curvas separadas: cada lado segue o próprio tempo', () {
    final (o, i) = fadeVolumes(1, .5);
    expect(o, closeTo(0, 1e-9));
    expect(i, closeTo(.707, .01));
    expect(fadeVolumes(0, 0), (1.0, 0.0));
  });

  test('troca sem buraco: o segundo player já espera no ponto certo e só recebe o "toca", sem buscar de novo', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.play();
      a.elapse(const Duration(milliseconds: 55800));
      expect(tail.loadedAt, const Duration(seconds: 56));
      expect(tail.playing, isFalse);
      expect(tail.volume, 0, reason: 'preparado mudo');
      a.elapse(const Duration(milliseconds: 160)); // 55,96s: 60 ms antes do ponto, para o som sair na hora
      expect(tail.playing, isTrue);
      expect(tail.seeks, isEmpty, reason: 'nada de buscar de novo na hora da troca');
      expect(m.volume, 1, reason: 'o principal continua soando até o segundo sair');
      expect(m.advances, 0);
      // troca rápida: a mesma música nos dois, volumes somando 1 (nunca um buraco)
      for (var i = 0; i < 6; i++) {
        a.elapse(const Duration(milliseconds: 25));
        expect(tail.volume + m.volume, closeTo(1, 1e-9));
      }
      expect(m.advances, 0);
      a.elapse(const Duration(milliseconds: 50));
      expect(m.advances, 1);
      expect(m.volumes.last, lessThan(.05), reason: 'o principal só troca de faixa depois de mudo');
      expect(tail.volume, closeTo(1, .05));
    });
  });

  test('celular ocupado (relógio atrasado): o segundo player é reposicionado antes de tocar', () {
    fakeAsync((a) {
      final (m, _) = setup(a);
      m.play();
      a.elapse(const Duration(milliseconds: 55800));
      m.drift(const Duration(milliseconds: 120));
      a.elapse(const Duration(milliseconds: 200));
      expect(tail.playing, isTrue);
      expect(tail.seeks, hasLength(1));
      a.elapse(const Duration(seconds: 1));
      expect(m.advances, 1);
    });
  });

  test('avanço manual na troca rápida: volta tudo ao normal na hora', () {
    fakeAsync((a) {
      final (m, c) = setup(a);
      m.play();
      a.elapse(const Duration(milliseconds: 56050));
      expect(tail.playing, isTrue);
      expect(m.volume, lessThan(1));
      c.cancel();
      m.jump(2);
      a.elapse(const Duration(seconds: 1));
      expect(tail.playing, isFalse);
      expect(m.volume, 1);
      expect(m.advances, 0, reason: 'a troca automática não acontece depois do comando');
    });
  });
}
