import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/genre.dart';
import 'package:player_nostalgico/genre_finder.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/organizer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Track track(String artist, {String genre = '', String title = 'Electric'}) =>
    Track(path: '/m/$artist/$title.mp3', title: title, artist: artist, album: 'A', genre: genre, addedAt: 0, modifiedAt: 0);

void main() {
  test('"Music" (categoria do YouTube) e afins contam como gênero vazio', () {
    for (final g in ['', 'Music', 'music ', 'Other', 'Unknown', 'Desconhecido', '(12)', '255', 'Entertainment', 'People & Blogs', 'Music\u0000']) {
      expect(isGenericGenre(g), isTrue, reason: g);
    }
    for (final g in ['Rock', 'Indie Rock', 'Pop', 'J-Pop', 'MPB', 'Alternative Rock', 'Musical']) {
      expect(isGenericGenre(g), isFalse, reason: g);
    }
    expect(realGenre(['Music']), '');
    expect(realGenre(['Music', 'Alternative Rock']), 'Alternative Rock');
    expect(realGenre(const []), '');
  });

  test('gênero pelas tags do Last.fm: a mais usada que parece gênero', () {
    expect(
        genreFromTags(const [MusicTag('seen live', 100), MusicTag('alternative rock', 80), MusicTag('norwegian', 60), MusicTag('rock', 50)]),
        'Alternative Rock');
    expect(genreFromTags(const [MusicTag('favorites', 100), MusicTag('norwegian', 50)]), isNull);
    expect(genreFromTags(const []), isNull);
  });

  test('MusicBrainz ignora tags genéricas', () {
    final g = MusicBrainzClient.parseArtistGenre({
      'artists': [
        {
          'name': 'Madrugada',
          'score': 100,
          'tags': [
            {'name': 'music', 'count': 9},
            {'name': 'alternative rock', 'count': 4},
          ]
        }
      ]
    }, 'Madrugada');
    expect(g, 'Alternative Rock');
  });

  group('GenreFinder', () {
    GenreFinder finder({String? mb, bool mbFails = false, TagResult lastFm = const TagResult(TagStatus.noKey), List<MusicTag>? cached}) =>
        GenreFinder(
          musicBrainz: (_) async => mbFails ? throw Exception('offline') : mb,
          lastFmArtist: (_) async => lastFm,
          cachedTrackTags: (_) => cached,
        );

    test('MusicBrainz primeiro', () async {
      final r = await finder(mb: 'Alternative Rock', lastFm: const TagResult(TagStatus.ok, [MusicTag('pop', 100)])).find('Madrugada', [track('Madrugada')]);
      expect(r.genre, 'Alternative Rock');
    });

    test('sem MusicBrainz: tags já guardadas, depois Last.fm do artista', () async {
      var r = await finder(cached: const [MusicTag('indie', 100)]).find('X', [track('X')]);
      expect(r.genre, 'Indie');
      r = await finder(lastFm: const TagResult(TagStatus.ok, [MusicTag('seen live', 100), MusicTag('indie pop', 90)])).find('X', [track('X')]);
      expect([r.genre, r.reached], ['Indie Pop', true]);
    });

    test('sem internet: não marca como tentado', () async {
      var r = await finder(mbFails: true).find('X', [track('X')]);
      expect([r.genre, r.reached], [null, false]);
      r = await finder(lastFm: const TagResult(TagStatus.network)).find('X', [track('X')]);
      expect(r.reached, isFalse);
      r = await finder().find('X', [track('X')]); // achou nada, mas o MusicBrainz respondeu
      expect([r.genre, r.reached], [null, true]);
    });
  });

  test('URL do artist.getTopTags', () {
    final u = LastFmClient.artistUrlFor('Madrugada', 'k');
    expect(u.queryParameters['method'], 'artist.gettoptags');
    expect(u.queryParameters['artist'], 'Madrugada');
    final parsed = LastFmClient.parse(200, jsonEncode({'toptags': {'tag': [{'name': 'alternative rock', 'count': 100}]}}));
    expect(genreFromTags(parsed.tags), 'Alternative Rock');
  });

  test('banco troca "Music" pelo gênero real, sem passar por cima de outro valor', () async {
    sqfliteFfiInit();
    final db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
    addTearDown(() => db.db.close());
    final id = await db.upsertTrack(track('Madrugada', genre: 'Music'));
    await db.fillGenre(id, 'Rock'); // espera '' e acha "Music": não mexe
    expect((await db.allTracks()).single.genre, 'Music');
    await db.fillGenre(id, '', current: 'Music');
    await db.fillGenre(id, 'Alternative Rock');
    expect((await db.allTracks()).single.genre, 'Alternative Rock');
  });

  test('clima automático usa o gênero real (o "Music" não dava pista nenhuma)', () {
    expect(MoodClues.guess(genre: 'Music').mood, isNull);
    expect(MoodClues.guess(genre: 'Heavy Metal').mood, isNotNull);
  });
}
