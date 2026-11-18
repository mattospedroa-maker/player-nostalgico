import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';

void main() {
  tearDown(() {
    MoodClues.tagsOf = (_) => null;
    MoodClues.learnFrom(const []);
  });

  Mood? g(String genre) => MoodClues.guess(genre: genre).mood;

  test('gênero vago não chuta mais Festa/Ação', () {
    for (final genre in ['Rock', 'Pop', 'Hip Hop', 'Rap', 'Indie', 'Alternative Rock', 'Pop Rock', 'Polka', 'Desconhecido', '']) {
      expect(g(genre), isNull, reason: genre);
    }
  });

  test('gênero claro ainda decide', () {
    expect(g('Lo-Fi'), Mood.calmo);
    expect(g('Metalcore'), Mood.acao);
    expect(g('Industrial Metal'), Mood.acao);
    expect(g('Soundtrack'), Mood.epico);
    expect(g('Video Game Music'), Mood.epico);
    expect(g('Funk Carioca'), Mood.festa);
    expect(g('Emo'), Mood.triste);
    expect(g('Bossa Nova'), Mood.calmo);
    expect(g('Post-Rock'), Mood.calmo);
    expect(g('Classic Rock'), isNull); // "classic" não é "clássica"
  });

  test('tags de clima da música vencem o gênero do artista', () {
    // balada de banda de nu metal: tags de gênero no topo, tags de clima mais fracas
    final tags = [const MusicTag('nu metal', 100), const MusicTag('rock', 80), const MusicTag('sad', 25), const MusicTag('emotional', 15)];
    final r = MoodClues.guess(genre: 'Nu Metal', tags: tags);
    expect(r.mood, Mood.triste);
    expect(r.reasons.first, contains('sad'));
  });

  test('tag composta conta ("love songs", "sad songs")', () {
    expect(MoodClues.guess(tags: [const MusicTag('pop', 100), const MusicTag('beautiful love songs', 30)]).mood, Mood.romantico);
  });

  test('título: acústico fica calmo, remix fica festa', () {
    expect(MoodClues.guess(genre: 'Rock', title: 'Numb (Acoustic Version)').mood, Mood.calmo);
    expect(MoodClues.guess(genre: 'Pop', title: 'Song - Nightcore').mood, Mood.festa);
  });

  test('empate fica neutro', () {
    final tags = [const MusicTag('sad', 100), const MusicTag('party', 100)];
    expect(MoodClues.guess(tags: tags).mood, isNull);
  });

  test('aprende com as escolhas no mesmo artista', () {
    var id = 0;
    Track tr(String title, [Mood? m]) =>
        Track(id: ++id, path: '/$id', title: title, artist: 'Banda', album: 'Disco', genre: 'Rock', mood: m?.name ?? '', addedAt: 0, modifiedAt: 0);
    final lib = [tr('a', Mood.triste), tr('b', Mood.triste), tr('c')];
    MoodClues.learnFrom(lib);
    expect(lib[2].effectiveMood, Mood.triste);
    expect(lib[2].chosenMood, isNull);
  });

  test('GIFs: clima automático vem das tags guardadas e entra nas categorias de anime', () {
    final t = Track(id: 1, path: '/x', title: 'In the End', artist: 'Linkin Park', album: 'Hybrid Theory', genre: 'Nu Metal', addedAt: 0, modifiedAt: 0);
    expect(GifFetcher.moodsFor(t), Mood.acao.categories);
    MoodClues.tagsOf = (_) => [const MusicTag('rock', 100), const MusicTag('melancholic', 40)];
    MoodClues.invalidate();
    expect(t.autoMood, Mood.triste);
    final cats = GifFetcher.moodsFor(t, tagAnime: ['stare', 'punch', 'cry']);
    expect(cats.first, Mood.triste.categories.first);
    expect(cats.take(2), ['cry', 'stare']);
    expect(cats, isNot(contains('punch'))); // soco briga com música melancólica
    expect(cats, containsAll(Mood.triste.categories));
  });

  test('sem pista nenhuma: categorias neutras/do gênero, como antes', () {
    final t = Track(id: 2, path: '/y', title: 'X', artist: 'Y', album: 'Z', genre: 'Pop', addedAt: 0, modifiedAt: 0);
    expect(t.autoMood, isNull);
    expect(GifFetcher.moodsFor(t), GifFetcher.moodCategories('Pop'));
  });
}
