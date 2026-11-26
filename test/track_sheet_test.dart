import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/styles.dart';
import 'package:player_nostalgico/track_sheet.dart';

Track _t(String title, String artist, {String album = 'Álbum', String genre = '', int? id, int? year}) => Track(
    id: id, path: '/m/$artist/$title.mp3', title: title, artist: artist, album: album, genre: genre, year: year, addedAt: 0, modifiedAt: 0);

void main() {
  setUp(Styles.invalidate);

  test('trilha de faroeste: título, álbum, gênero e IA levam a faroeste e trilha de filme', () {
    final t = _t('The Good, the Bad and the Ugly', 'Ennio Morricone', album: 'Il buono, il brutto, il cattivo (Original Soundtrack)', genre: 'Soundtrack');
    final s = TrackSheet.build(t, ai: AiFacts.fromJson({'scenes': ['faroeste'], 'sound': ['Assobio'], 'like': ['filme de faroeste']}));
    expect(s.sceneKeys, containsAll(['faroeste', 'cinema']));
    expect(s.sound, ['assobio']);
    expect(s.aiRead, isTrue);
  });

  test('sem IA, só pelo estilo e pelo título: metal sinfônico com "battle" vira guerra', () {
    final t = _t('Battle of the Ages', 'Banda', genre: 'Symphonic Metal');
    expect(TrackSheet.build(t).sceneKeys, contains('guerra'));
  });

  test('música sem nenhuma pista não ganha cena', () {
    expect(TrackSheet.build(_t('Faixa 01', 'Alguém')).scenes, isEmpty);
  });

  test('cena tirada à mão não volta; cena posta à mão entra primeiro', () {
    final t = _t('Battle of the Ages', 'Banda', genre: 'Symphonic Metal');
    final s = TrackSheet.build(t, edits: const StyleEdits({'praia'}, {'guerra'}));
    expect(s.sceneKeys.first, 'praia');
    expect(s.sceneKeys, isNot(contains('guerra')));
  });

  test('cenas da letra viram tema quando a IA ainda não leu', () {
    final s = TrackSheet.build(_t('Song', 'X'), lyricKeys: ['rain', 'night']);
    expect(s.topics, ['chuva', 'noite']);
  });

  test('resposta da IA: ignora cenas fora da lista e números fora do lote', () {
    final got = TrackSheet.parseAnswer({
      'tracks': [
        {'i': 1, 'scenes': ['faroeste', 'inventada'], 'topics': ['duelo', 'duelo', 'xerife']},
        {'i': '2', 'scenes': ['praia']},
        {'i': 9, 'scenes': ['festa']},
        'lixo',
      ]
    }, 2);
    expect(got.keys, [0, 1]);
    expect(got[0]!.scenes, ['faroeste']);
    expect(got[0]!.topics, ['duelo', 'xerife']);
    expect(got[1]!.scenes, ['praia']);
  });

  test('pedido à IA numera as músicas e lista as cenas', () {
    final p = TrackSheet.prompt([_t('Big Iron', 'Marty Robbins', album: 'Gunfighter Ballads', year: 1959), _t('B', 'C')]);
    expect(p, contains('1. Marty Robbins — Big Iron (álbum: Gunfighter Ballads, 1959)'));
    expect(p, contains('2. C — B'));
    expect(p, contains('faroeste (faroeste)'));
  });

  test('hábitos: período com metade dos plays e fim de semana acima de 60%', () {
    const h = ListeningHabits({1: [0, 0, 1, 4, 4], 2: [1, 1, 0, 0, 0]});
    expect(h.labelsFor(1), ['noite', 'fim de semana']);
    expect(h.labelsFor(2), isEmpty); // menos de 3 plays
    expect(h.mainPart(1), 3);
  });

  test('ficha guardada em arquivo volta igual', () async {
    final dir = await Directory.systemTemp.createTemp('fatos');
    final t = _t('Big Iron', 'Marty Robbins');
    final a = TrackFactsStore(dir.path)
      ..putAi(t, AiFacts.fromJson({'scenes': ['faroeste'], 'country': 'EUA'}))
      ..putEdits(t, const StyleEdits({'estrada'}, {}));
    await a.save();
    final b = TrackFactsStore(dir.path);
    expect(b.ai(t)!.scenes, ['faroeste']);
    expect(b.ai(t)!.country, 'EUA');
    expect(b.edits(t).added, {'estrada'});
    expect(b.hasAi(_t('Outra', 'X')), isFalse);
    await dir.delete(recursive: true);
  });
}
