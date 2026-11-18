import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/gif_feedback.dart';
import 'package:player_nostalgico/gif_fetcher.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/lyrics.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';

/// Escolha dos GIFs por música: ordem do clima, andamento, cenas da letra e 👎 por categoria. Sem rede.
void main() {
  tearDown(() {
    MoodClues.tagsOf = (_) => null;
    MoodClues.learnFrom(const []);
  });

  Track track({String genre = '', String mood = '', int? bpm, String title = 'Música'}) =>
      Track(id: 1, path: '/m/$title.mp3', title: title, artist: 'Banda', album: 'Disco', genre: genre, mood: mood, bpm: bpm, addedAt: 0, modifiedAt: 0);

  group('passo 1: ordem das categorias pelo clima', () {
    test('triste 1.5, romântico 0.6 -> cry, hug, pat, kiss, cuddle (sem punch, mesmo com rock)', () {
      final cats = GifFetcher.categoriesFromScores({Mood.triste: 1.5, Mood.romantico: 0.6}, tagAnime: ['punch', 'kick', 'hug']);
      expect(cats, ['cry', 'hug', 'pat', 'kiss', 'cuddle']);
    });

    test('só festa -> dance, happy, highfive, clap, laugh', () {
      expect(GifFetcher.categoriesFromScores({Mood.festa: 1.0}), ['dance', 'happy', 'highfive', 'clap', 'laugh']);
    });

    test('festa 0.9, triste 0.8 (empate) -> intercala', () {
      expect(GifFetcher.categoriesFromScores({Mood.festa: 0.9, Mood.triste: 0.8}), ['dance', 'cry', 'happy', 'hug', 'highfive', 'pat']);
    });

    test('usuário marcou Calmo: ignora pontos, BPM e letra', () {
      MoodClues.tagsOf = (_) => [const MusicTag('party', 100), const MusicTag('rock', 80)];
      final t = track(genre: 'Rock', mood: Mood.calmo.name, bpm: 170);
      expect(GifFetcher.moodsFor(t, tagAnime: ['dance', 'punch'], bpm: 170, energy: 0.9), ['sleep', 'yawn', 'cuddle', 'pat', 'smile']);
    });

    test('sem ponto nenhum: o fallback de antes', () {
      expect(GifFetcher.categoriesFromScores({}), isEmpty);
      expect(GifFetcher.categoriesFromScores({Mood.festa: 0}), isEmpty);
      expect(GifFetcher.moodsFor(track(genre: 'Pop')), GifFetcher.moodCategories('Pop'));
      expect(GifFetcher.moodsFor(track(genre: 'Pop'), tagAnime: ['stare']), ['stare']);
      expect(GifFetcher.moodsFor(track()), GifFetcher.neutralMoods);
    });
  });

  group('passo 2: andamento', () {
    test('alternative rock, BPM 72, tag sad -> começa no triste, sem dance', () {
      final t = track(genre: 'Alternative Rock', bpm: 72);
      final tags = [const MusicTag('alternative rock', 100), const MusicTag('sad', 40)];
      final cats = GifFetcher.moodsFor(t, tags: tags);
      expect(cats.take(2), ['cry', 'hug']);
      expect(cats, contains('sleep'));
      expect(cats, isNot(contains('dance')));
    });

    test('música lenta vira o empate festa x triste a favor do triste', () {
      final slow = MoodClues.withTempo({Mood.festa: 0.9, Mood.triste: 0.8}, bpm: 72);
      expect(slow[Mood.triste], closeTo(1.12, 1e-9));
      expect(slow[Mood.festa], closeTo(0.405, 1e-9));
      final cats = GifFetcher.categoriesFromScores(slow);
      expect(cats.take(3), ['cry', 'hug', 'pat']);
      expect(cats, isNot(contains('dance')));
    });

    test('rápida sobe festa/ação/épico e desce calmo; meio-termo não muda', () {
      expect(MoodClues.tempoFactors(bpm: 140), {Mood.festa: 1.3, Mood.acao: 1.3, Mood.epico: 1.3, Mood.calmo: 0.5});
      expect(MoodClues.tempoFactors(energy: 0.8)[Mood.festa], 1.3);
      expect(MoodClues.tempoFactors(energy: 0.2)[Mood.triste], 1.4);
      expect(MoodClues.tempoFactors(bpm: 100), isEmpty);
    });

    test('BPM fora de 40–220 conta como ausente', () {
      expect(MoodClues.tempoFactors(bpm: 30), isEmpty);
      expect(MoodClues.tempoFactors(bpm: 250), isEmpty);
      expect(FileMetadataReader.parseBpm('128'), 128);
      expect(FileMetadataReader.parseBpm('92.6'), 93);
      expect(FileMetadataReader.parseBpm('0'), isNull);
      expect(FileMetadataReader.parseBpm('300'), isNull);
      expect(FileMetadataReader.parseBpm(''), isNull);
    });

    test('Last.fm track.getInfo: bpm e energia só se vierem', () {
      final none = LastFmClient.parseTempo(200, '{"track":{"name":"x","duration":"200000"}}')!;
      expect(none.isEmpty, isTrue);
      final some = LastFmClient.parseTempo(200, '{"track":{"bpm":"74","energy":0.3}}')!;
      expect(some.bpm, 74);
      expect(some.energy, 0.3);
      expect(LastFmClient.parseTempo(200, '{"track":{"bpm":"999"}}')!.bpm, isNull);
      expect(LastFmClient.parseTempo(200, '{"error":6,"message":"Track not found"}')!.isEmpty, isTrue);
      expect(LastFmClient.parseTempo(200, '{"error":29}'), isNull); // limite: tenta outra hora
      expect(LastFmClient.parseTempo(500, 'oops'), isNull);
    });
  });

  group('passo 3: cenas da letra', () {
    test('"rain on the highway" -> rain, car, sem repetir', () {
      expect(LyricScenes.extract('rain on the highway').map((s) => s.key), ['rain', 'car']);
      final again = LyricScenes.extract('Rain, rain on the highway\nthe car in the rain, storm on the road');
      expect(again.map((s) => s.key), ['rain', 'car']);
      expect(again.map((s) => s.query), ['rain window night', 'night drive aesthetic']);
    });

    test('português, no máximo 4 cenas e só os primeiros 600 caracteres', () {
      final pt = LyricScenes.extract('Na madrugada, a chuva na cidade, o mar e a neve, depois a guerra');
      expect(pt.map((s) => s.key), ['night', 'rain', 'city', 'ocean']);
      expect(pt.first.query, 'night scenery');
      final late = '${'la ' * 250}snow';
      expect(LyricScenes.extract(late), isEmpty);
      expect(LyricScenes.extract('o carro na estrada').map((s) => s.key), ['car']);
      expect(LyricScenes.extract('marcha e cartas'), isEmpty); // só palavra inteira
    });

    test('cache guarda só as cenas, nunca a letra', () {
      final dir = Directory.systemTemp.createTempSync('lyrics_cache');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File(p.join(dir.path, '.lyrics.json'));
      final c = LyricsCache(f);
      expect(c.get('A', 'B'), isNull);
      c.put('A', 'B', LyricScenes.extract('rain on the highway'));
      expect(f.readAsStringSync(), isNot(contains('highway')));
      expect(LyricsCache(f).get('a', 'b')!.map((s) => s.key), ['rain', 'car']);
      c.put('A', 'Sem letra', const []);
      expect(LyricsCache(f).get('A', 'Sem letra'), isEmpty);
    });

    test('respostas do LRCLIB e do lyrics.ovh', () {
      expect(LyricsClient.parseLrclib('{"plainLyrics":"rain"}'), 'rain');
      expect(LyricsClient.parseLrclib('{"plainLyrics":null,"syncedLyrics":"[00:01.00] car"}'), 'car');
      expect(LyricsClient.parseLrclib('{"instrumental":true}'), isNull);
      expect(LyricsClient.parseOvh('{"lyrics":"snow"}'), 'snow');
      expect(LyricsClient.parseOvh('{"error":"No lyrics found"}'), isNull);
      expect(LyricsClient.lrclibUrl('A', 'B', 'C').queryParameters, {'artist_name': 'A', 'track_name': 'B', 'album_name': 'C'});
    });
  });

  group('passo 4: 👎 por categoria no artista', () {
    test('um 👎 não tira; dois tiram', () {
      final dir = Directory.systemTemp.createTempSync('fb_cat');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fb = GifFeedback(File(p.join(dir.path, '.preferencias.json')));
      fb.dislikeCategory('Banda', 'cry');
      expect(fb.categoryDislikes('banda', 'cry'), 1);
      fb.dislikeCategory('Banda', 'cry');
      expect(fb.categoryDislikes('Banda', 'cry'), 2);
      expect(fb.categoryDislikes('Banda', 'hug'), 0);
      expect(fb.categoryDislikes('Outra', 'cry'), 0);
    });
  });
}
