import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/recommender.dart';

var _id = 0;
Track tr(String title, String artist, {String genre = '', Mood? mood, String album = unknownAlbum}) => Track(
    id: ++_id, path: '/m/$artist/$title.mp3', title: title, artist: artist, album: album, genre: genre,
    mood: mood?.name ?? '', addedAt: 0, modifiedAt: 0);

void main() {
  // playlist triste de rock alternativo
  final exit = tr('Exit Music', 'Radiohead', genre: 'Alternative Rock', mood: Mood.triste);
  final fix = tr('Fix You', 'Coldplay', genre: 'Alternative Rock', mood: Mood.triste);
  final youth = tr('Youth', 'Daughter', genre: 'Indie Pop', mood: Mood.calmo);
  final playlist = [exit, fix, youth];

  final sparks = tr('Sparks', 'Coldplay', genre: 'Alternative Rock', mood: Mood.calmo);
  final lovesong = tr('Lovesong', 'The Cure', genre: 'Alternative Rock', mood: Mood.triste);
  final liability = tr('Liability', 'Lorde', genre: 'Indie Pop', mood: Mood.triste);
  final party = tr('Party Rock Anthem', 'LMFAO', genre: 'Electro House', mood: Mood.festa);
  final partyRock = tr('Song 2', 'Blur', genre: 'Alternative Rock', mood: Mood.festa);
  final samba = tr('Mas que Nada', 'Jorge Ben', genre: 'Samba');
  final hardRock = tr('Back in Black', 'AC/DC', genre: 'Hard Rock');
  final library = [exit, fix, youth, sparks, lovesong, liability, party, partyRock, samba, hardRock];

  List<Track> picks(List<PlaylistSuggestion> r) => [for (final s in r) s.track];

  test('sugere o mesmo gênero e clima, fora da playlist, e diz o porquê', () {
    final r = Recommender.forPlaylist(playlist, library);
    final ts = picks(r);
    expect(ts, isNot(contains(exit)));
    expect(ts, isNot(contains(fix)));
    expect(ts.first, lovesong); // gênero + clima triste + artista novo
    expect(ts, containsAll([sparks, liability]));
    expect(ts, isNot(contains(samba))); // nada em comum
    expect(ts, isNot(contains(party))); // festa, gênero diferente
    final love = r.firstWhere((s) => s.track == lovesong);
    expect(love.genre, 'Alternative Rock');
    expect(love.mood, Mood.triste);
  });

  test('clima que briga (festa numa playlist triste) fica atrás', () {
    final ts = picks(Recommender.forPlaylist(playlist, library));
    if (ts.contains(partyRock)) expect(ts.indexOf(partyRock), greaterThan(ts.indexOf(sparks)));
    // mesma família de gênero ("Hard Rock" ~ "Alternative Rock") conta menos que gênero igual
    if (ts.contains(hardRock)) expect(ts.indexOf(hardRock), greaterThan(ts.indexOf(lovesong)));
  });

  test('playlist com nome de clima usa o clima como regra', () {
    expect(Recommender.moodOfPlaylistName('romântico'), Mood.romantico);
    expect(Recommender.moodOfPlaylistName('  TRISTE '), Mood.triste);
    expect(Recommender.moodOfPlaylistName('Noite chuvosa'), isNull);
    final ts = picks(Recommender.forPlaylist([exit], library, playlistName: 'Triste'));
    expect(ts.take(2), containsAll([lovesong, fix]));
    expect(ts, isNot(contains(partyRock)));
  });

  test('no máximo 2 do mesmo artista e playlist vazia não sugere nada', () {
    final many = [for (var i = 0; i < 5; i++) tr('Faixa $i', 'Mesmo Artista', genre: 'Alternative Rock', mood: Mood.triste)];
    final ts = picks(Recommender.forPlaylist(playlist, [...library, ...many], limit: 4));
    expect(ts.where((t) => t.artist == 'Mesmo Artista').length, lessThanOrEqualTo(2));
    expect(Recommender.forPlaylist(const [], library), isEmpty);
  });

  test('música pulada várias vezes cai na lista', () {
    final plays = [for (var i = 0; i < 3; i++) Play(trackId: lovesong.id!, playedAt: i, secondsListened: 5, skipped: true)];
    final ts = picks(Recommender.forPlaylist(playlist, library, plays: plays));
    expect(ts.first, isNot(lovesong));
  });

  test('biblioteca grande: conta rápida', () {
    final big = [for (var i = 0; i < 5000; i++) tr('M$i', 'Artista ${i % 400}', genre: ['Rock', 'Pop', 'Indie Pop', 'Alternative Rock'][i % 4], mood: Mood.values[i % 6])];
    final sw = Stopwatch()..start();
    Recommender.forPlaylist([...playlist, ...big.take(40)], big);
    expect(sw.elapsedMilliseconds, lessThan(500));
  });
}
