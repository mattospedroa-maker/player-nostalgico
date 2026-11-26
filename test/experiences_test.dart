import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/experiences.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/play_stats.dart';
import 'package:player_nostalgico/track_sheet.dart';

Track _t(int id, String artist, {int? year}) =>
    Track(id: id, path: '/m/$id.mp3', title: 'Faixa $id', artist: artist, album: 'A', year: year, addedAt: 0, modifiedAt: 0);

Sheet _sheet(List<String> keys) => Sheet([for (final k in keys) (TrackSheet.sceneByKey[k]!, 2.5)], const [], const [], const [], const [], const []);

void main() {
  // 30 músicas de guerra (10 artistas), 12 de chuva, 5 de praia (poucas demais)
  final lib = <Track>[
    for (var i = 1; i <= 30; i++) _t(i, 'Banda ${i % 10}'),
    for (var i = 31; i <= 42; i++) _t(i, 'Chuva ${i % 6}'),
    for (var i = 43; i <= 47; i++) _t(i, 'Praia'),
  ];
  Sheet sheetOf(Track t) => _sheet(t.id! <= 30 ? ['guerra'] : (t.id! <= 42 ? ['chuva'] : ['praia']));
  const hour = 3600000;

  test('receita pega as músicas das cenas, no máximo 3 por artista', () {
    final r = experienceMenu.firstWhere((r) => r.id == 'guerra');
    final got = ExperienceEngine.pick(r, lib, rnd: Random(1), sheetOf: sheetOf);
    expect(got.length, 25);
    expect(got.every((x) => x.$1.id! <= 30), isTrue);
    final per = <String, int>{};
    for (final (t, _) in got) {
      per[t.artist] = (per[t.artist] ?? 0) + 1;
    }
    expect(per.values.every((n) => n <= 3), isTrue);
    expect(got.first.$2, contains('guerra'));
  });

  test('receita sem músicas suficientes não sai', () {
    final r = experienceMenu.firstWhere((r) => r.id == 'praia');
    expect(ExperienceEngine.pick(r, lib, rnd: Random(1), sheetOf: sheetOf), isEmpty);
  });

  test('renovar: cria as que cabem, cada uma com prazo entre 40 e 70 horas', () {
    const now = 1000000000000;
    final s = ExperienceEngine.refresh(ExperienceState.empty, lib, nowMs: now, rnd: Random(2), sheetOf: sheetOf);
    expect(s.active, isNotEmpty);
    expect(s.active.map((e) => e.id).toSet().length, s.active.length);
    for (final e in s.active) {
      expect(e.expiresAt - now, inInclusiveRange(40 * hour, 70 * hour));
      expect(e.trackIds.length, greaterThanOrEqualTo(ExperienceEngine.minTracks));
    }
    expect(s.active.any((e) => e.id == 'guerra'), isTrue);
    expect(s.active.any((e) => e.id == 'chuva'), isTrue);
  });

  test('vencida sai; a que ainda está no prazo fica igual', () {
    const now = 1000000000000;
    final keep = Experience(id: 'x', title: 'X', emoji: '✨', kind: 'menu', trackIds: [for (var i = 1; i <= 10; i++) i], createdAt: now - hour, expiresAt: now + hour);
    final old = Experience(id: 'y', title: 'Y', emoji: '✨', kind: 'menu', trackIds: [for (var i = 1; i <= 10; i++) i], createdAt: now - 80 * hour, expiresAt: now - 1);
    final s = ExperienceEngine.refresh(ExperienceState([keep, old], const []), lib, nowMs: now, rnd: Random(3), sheetOf: sheetOf);
    expect(s.active.any((e) => e.id == 'y'), isFalse);
    expect(s.active.firstWhere((e) => e.id == 'x').expiresAt, now + hour);
  });

  test('músicas apagadas saem da playlist do momento', () {
    const now = 1000000000000;
    final e = Experience(id: 'x', title: 'X', emoji: '✨', kind: 'menu', trackIds: [1, 2, 3, 4, 5, 999], createdAt: now, expiresAt: now + hour);
    final s = ExperienceEngine.refresh(ExperienceState([e], const []), lib, nowMs: now, rnd: Random(3), sheetOf: sheetOf);
    expect(s.active.firstWhere((x) => x.id == 'x').trackIds, [1, 2, 3, 4, 5]);
  });

  test('surpresa: década com 10 músicas ou mais', () {
    final withYears = [for (var i = 1; i <= 12; i++) _t(i, 'Art $i', year: 1994)];
    final got = ExperienceEngine.surprises(withYears, PlayStats.empty, 0, Random(1));
    expect(got.any((x) => x.$1 == 'decada:1990' && x.$2 == 'Viagem aos anos 90'), isTrue);
    expect(got.any((x) => x.$1 == 'ano:1994'), isTrue);
  });

  test('estado salvo volta igual', () {
    final e = Experience(id: 'guerra', title: 'Para ir para a guerra', emoji: '⚔️', kind: 'menu', trackIds: [1, 2], reasons: {1: '⚔️ guerra'}, why: 'w', createdAt: 5, expiresAt: 9);
    final back = ExperienceState.decode(ExperienceState([e], const ['guerra']).encode());
    expect(back.active.single.reasons[1], '⚔️ guerra');
    expect(back.active.single.expiresAt, 9);
    expect(back.recent, ['guerra']);
    expect(ExperienceState.decode('lixo').active, isEmpty);
  });

  test('tempo que falta', () {
    expect(Experience.timeLeft(35 * 60000), '35 min');
    expect(Experience.timeLeft(19 * hour), '19h');
    expect(Experience.timeLeft(52 * hour), '2d 4h');
  });
}
