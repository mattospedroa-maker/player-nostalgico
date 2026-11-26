import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/recommender.dart';
import 'package:player_nostalgico/style_learning.dart';
import 'package:player_nostalgico/styles.dart';

var _id = 0;
final _tags = <String, List<MusicTag>>{};
Track tr(String title, String artist, {String genre = '', Mood? mood, List<String> tags = const []}) {
  final t = Track(
      id: ++_id, path: '/m/$artist/$title.mp3', title: title, artist: artist, album: unknownAlbum, genre: genre,
      mood: mood?.name ?? '', addedAt: 0, modifiedAt: 0);
  _tags[t.path] = [for (var i = 0; i < tags.length; i++) MusicTag(tags[i], 100 - i * 8)];
  return t;
}

Play play(Track t, DateTime at, {bool skipped = false}) =>
    Play(trackId: t.id!, playedAt: at.millisecondsSinceEpoch, secondsListened: skipped ? 5 : 200, skipped: skipped);

void main() {
  setUp(() {
    Styles.trackTags = (t) => _tags[t.path];
    MoodClues.tagsOf = (t) => _tags[t.path];
    Styles.artistTags = (_) => null;
    StyleLearning.current = StyleLearning.build(const {}, const {}, const []);
    Styles.learnedPair = (_, _) => 0;
    Styles.invalidate();
    MoodClues.invalidate();
  });
  tearDown(() {
    Styles.trackTags = (_) => null;
    MoodClues.tagsOf = (_) => null;
    Styles.invalidate();
  });

  test('1 · sem gênero nem estilo, as tags do Last.fm ainda aproximam (e viram o motivo)', () {
    final a = tr('a', 'X', tags: ['dreamy', 'rainy', 'melancholic']);
    final b = tr('b', 'Y', tags: ['dreamy', 'rainy']);
    final c = tr('c', 'Z', tags: ['party']);
    expect(Recommender.affinity(a, b), greaterThan(Recommender.affinity(a, c)));
    final (_, why) = Recommender.affinityWhy(a, b);
    expect(why, startsWith('tags em comum'));
    expect(Recommender.similar(a, [a, b, c]).first.track, b);
  });

  test('2 · clima dominante de verdade pesa; clima só automático não', () {
    final pl = [
      for (var i = 0; i < 4; i++) tr('p$i', 'P$i', genre: 'Rock', mood: i < 2 ? Mood.triste : null, tags: ['sad']),
    ];
    // 2 escolhidas à mão + 2 automáticas "triste" (tag sad) = 100% triste, metade escolhida
    expect(Recommender.dominantMood(pl), Mood.triste);
    final auto = [for (var i = 0; i < 4; i++) tr('q$i', 'Q$i', genre: 'Rock', tags: ['sad'])];
    expect(Recommender.dominantMood(auto), isNull, reason: 'nenhuma escolhida no selo');
    final sad = tr('triste', 'S', genre: 'Pop', tags: ['sad']);
    final epic = tr('epico', 'E', genre: 'Rock', mood: Mood.epico);
    final r = [for (final s in Recommender.forPlaylist(pl, [...pl, sad, epic])) s.track];
    expect(r.first, sad, reason: 'mesmo sem o gênero, o clima dominante passa na frente');
  });

  test('3 · pular a mesma música várias vezes não condena o artista', () {
    final now = DateTime(2026, 11, 25, 20);
    final hit = tr('hit', 'Banda', genre: 'Rock');
    final other = tr('outra', 'Banda', genre: 'Rock');
    final fav = tr('fav', 'Banda', genre: 'Rock');
    final lib = [hit, other, fav];
    final listened = [for (var i = 1; i <= 5; i++) play(fav, now.subtract(Duration(days: i)))];
    final sameSkip = [for (var i = 1; i <= 5; i++) play(hit, now.subtract(Duration(days: i, hours: 2)), skipped: true)];
    double scoreOf(List<Play> plays, Track t) =>
        Recommender(lib, plays, now: now).mix().where((r) => r.track == t).firstOrNull?.score ?? 0;
    expect(scoreOf([...listened, ...sameSkip], other), scoreOf(listened, other), reason: 'só a faixa pulada perde');
    expect(scoreOf([...listened, ...sameSkip], hit), lessThan(scoreOf(listened, hit)));
    final x = tr('x', 'Banda', genre: 'Rock'), y = tr('y', 'Banda', genre: 'Rock'), z = tr('z', 'Banda', genre: 'Rock');
    final lib2 = [...lib, x, y, z];
    final skips3 = [for (final t in [x, y, z]) play(t, now.subtract(const Duration(days: 2)), skipped: true)];
    double s2(List<Play> p) => Recommender(lib2, p, now: now).mix().where((r) => r.track == other).firstOrNull?.score ?? 0;
    expect(s2([...listened, ...skips3]), lessThan(s2(listened)), reason: '3 músicas diferentes puladas: aí o artista perde');
  });

  test('4 · Redescobrir: música da outra estação vai para o fim, não some', () {
    final now = DateTime(2026, 11, 25);
    final summer = tr('verão', 'A'), novemberHit = tr('novembro', 'B');
    final plays = [
      for (var i = 0; i < 6; i++) play(summer, DateTime(2025, 6, 10 + i)),
      for (var i = 0; i < 4; i++) play(novemberHit, DateTime(2025, 11, 5 + i)),
    ];
    final r = [for (final x in Recommender([summer, novemberHit], plays, now: now).rediscover()) x.track];
    expect(r, [novemberHit, summer], reason: 'a de junho tem mais execuções, mas fica depois agora em novembro');
  });

  test('5 · o motivo é o termo que mais pesou', () {
    final now = DateTime(2026, 11, 25, 20);
    final a = tr('a', 'Artista', genre: 'Rock');
    final b = tr('b', 'Outro', genre: 'Rock', mood: Mood.calmo);
    final plays = [for (var i = 1; i <= 6; i++) play(a, now.subtract(Duration(days: i)))];
    final mix = Recommender([a, b], plays, now: now).mix();
    expect(mix.firstWhere((r) => r.track == a).reason, startsWith('porque você ouve Artista'));
    expect(mix.firstWhere((r) => r.track == b).reason, startsWith('gênero Rock'));
    // playlist: quem entra por estar junto nas suas playlists mostra isso
    final p1 = tr('p1', 'P1', genre: 'Jazz'), p2 = tr('p2', 'P2', genre: 'Jazz'), friend = tr('amiga', 'F', genre: 'Metal');
    StyleLearning.current = StyleLearning.build({
      1: [p1.id!, friend.id!],
      2: [p2.id!, friend.id!],
      3: [p1.id!, friend.id!, p2.id!],
    }, {1: 'a', 2: 'b', 3: 'c'}, [p1, p2, friend]);
    final s = Recommender.forPlaylist([p1, p2], [p1, p2, friend]).firstWhere((x) => x.track == friend);
    expect(s.reason, 'junto nas suas playlists');
  });
}
