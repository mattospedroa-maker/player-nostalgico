import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/recommender.dart';
import 'package:player_nostalgico/style_learning.dart';
import 'package:player_nostalgico/styles.dart';

var _id = 0;
Track tr(String title, String artist, {String genre = '', String edit = '', int? energy, int? humor}) => Track(
    id: ++_id, path: '/m/$artist/$title.mp3', title: title, artist: artist, album: unknownAlbum, genre: genre,
    addedAt: 0, modifiedAt: 0, stylesEdit: edit, energy: energy, humor: humor);

List<MusicTag> tags(List<String> names) => [for (var i = 0; i < names.length; i++) MusicTag(names[i], 100 - i * 8)];

void main() {
  setUp(() {
    Styles.trackTags = (_) => null;
    Styles.artistTags = (_) => null;
    Styles.learnedPair = (_, _) => 0;
    StyleLearning.current = StyleLearning.build(const {}, const {}, const []);
    Styles.invalidate();
  });

  test('nomes unificados: "post punk", "Post-Punk" e "postpunk" são o mesmo estilo', () {
    expect(Styles.styleOf('post punk')?.name, 'Post-Punk');
    expect(Styles.styleOf('Post-Punk')?.name, 'Post-Punk');
    expect(Styles.styleOf('postpunk')?.name, 'Post-Punk');
    expect(Styles.styleOf('Dream-Pop')?.name, 'Dream Pop');
    expect(Styles.styleOf('seen live'), isNull);
    expect(Styles.styleOf('sad'), isNull); // clima, não estilo
  });

  test('estilos automáticos: tags da música, do artista e o gênero; guarda-chuva por último', () {
    final s = Styles.auto(genre: 'Rock', tags: tags(['rock', 'shoegaze', 'dream pop', 'seen live', '90s']));
    expect(s.take(2), ['Shoegaze', 'Dream Pop']);
    expect(s.last, 'Rock');
    // sem tags da música: as do artista
    expect(Styles.auto(artistTags: tags(['post-punk', 'new wave'])), ['Post-Punk', 'New Wave']);
    expect(Styles.auto(genre: 'Nu Metal'), ['Nu Metal']);
    expect(Styles.auto(), isEmpty);
  });

  test('edições à mão: estilo posto vem primeiro, tirado não volta', () {
    Styles.trackTags = (_) => tags(['shoegaze', 'dream pop', 'noise pop']);
    final t = tr('a', 'Slowdive', edit: '+Slowcore|-Noise Pop');
    expect(Styles.of(t), ['Slowcore', 'Shoegaze', 'Dream Pop']);
    expect(StyleEdits.parse(StyleEdits.parse('+A|-B').encode()).removed, {'B'});
  });

  test('mapa de vizinhos: shoegaze perto de dream pop e post-punk, longe de nu metal', () {
    expect(Styles.similarity('Shoegaze', 'Dream Pop'), greaterThan(.5));
    expect(Styles.similarity('Shoegaze', 'Post-Punk'), greaterThan(.5));
    expect(Styles.similarity('Shoegaze', 'Nu Metal'), 0);
    expect(Styles.similarity('Darkwave', 'Gothic Rock'), greaterThan(Styles.similarity('Darkwave', 'House')));
    expect(Styles.neighborsOf(['Shoegaze']), contains('Slowcore'));
  });

  test('réguas: estilos, tags de clima e BPM; à mão vale e muda o selo', () {
    final calm = Styles.autoVibe(styles: ['Slowcore'], tags: tags(['sad', 'melancholic']), bpm: 70);
    final loud = Styles.autoVibe(styles: ['Metalcore'], tags: tags(['aggressive']), bpm: 170);
    expect(calm.energy, lessThan(30));
    expect(calm.humor, lessThan(20));
    expect(loud.energy, greaterThan(80));
    expect(Styles.autoVibe(styles: ['Dance'], tags: tags(['happy', 'party'])).humor, greaterThan(80));
    final manual = tr('b', 'X', energy: 90, humor: 80);
    expect(Styles.vibeOf(manual).manual, isTrue);
    expect(manual.autoMood, Mood.festa);
    expect(Mood.fromVibe(20, 20), Mood.triste);
    expect(Mood.fromVibe(20, 50), Mood.calmo);
    expect(Mood.fromVibe(50, 50), isNull);
  });

  test('aprende com as playlists: músicas e estilos que você junta se aproximam', () {
    final a = tr('A', 'Artista A', genre: 'Shoegaze');
    final b = tr('B', 'Artista B', genre: 'Hip Hop');
    final c = tr('C', 'Artista C', genre: 'Shoegaze');
    final d = tr('D', 'Artista D', genre: 'Hip Hop');
    final lib = [a, b, c, d];
    final l = StyleLearning.build({
      1: [a.id!, b.id!],
      2: [a.id!, b.id!, c.id!],
      3: [c.id!, d.id!],
      9: [a.id!, d.id!], // playlist de clima: não conta
    }, {1: 'mix', 2: 'noite', 3: 'outra', 9: 'Triste'}, lib);
    expect(l.together(a.id!, b.id!), 2);
    expect(l.together(a.id!, d.id!), 0);
    expect(l.stylePair('Shoegaze', 'Hip Hop'), greaterThan(.5));
    expect(l.artistsTogether('artista a', 'artista b'), 2);
    StyleLearning.current = l;
    Styles.learnedPair = l.stylePair;
    expect(Styles.similarity('Shoegaze', 'Hip Hop'), greaterThan(.3));
    // numa playlist só com A, B (que você sempre junta com A) vem antes de D
    final r = [for (final s in Recommender.forPlaylist([a], lib)) s.track];
    expect(r.indexOf(b), lessThan(r.contains(d) ? r.indexOf(d) : 99));
  });

  test('playlist enorme não trava o aprendizado', () {
    final big = [for (var i = 0; i < 3000; i++) tr('M$i', 'Art ${i % 300}', genre: ['Rock', 'Pop', 'Shoegaze'][i % 3])];
    final sw = Stopwatch()..start();
    StyleLearning.build({1: [for (final t in big) t.id!], 2: [for (final t in big.take(120)) t.id!]}, {1: 'tudo', 2: 'cem'}, big);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
