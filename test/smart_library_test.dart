import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/library_search.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/play_stats.dart';
import 'package:player_nostalgico/recommender.dart';
import 'package:player_nostalgico/smart_collections.dart';

var _id = 0;
Track tr(String title, String artist, {String album = unknownAlbum, String genre = '', Mood? mood, bool fav = false, int added = 0, int? year}) => Track(
    id: ++_id,
    path: '/m/$artist/$title.mp3',
    title: title,
    artist: artist,
    album: album,
    genre: genre,
    mood: mood?.name ?? '',
    favorite: fav,
    addedAt: added,
    modifiedAt: 0,
    year: year);

void main() {
  final numb = tr('Numb', 'Linkin Park', album: 'Meteora', genre: 'Nu Metal', fav: true, added: 5);
  final faint = tr('Faint', 'Linkin Park', album: 'Meteora', genre: 'Nu Metal', added: 4);
  final acao = tr('Ação e Reação', 'Charlie Brown Jr.', album: 'Imunidade Musical', genre: 'Rock', added: 3);
  final cafe = tr('Café da Manhã', 'Anônimo', genre: 'MPB', mood: Mood.calmo, added: 2);
  final miku = tr('World is Mine', 'supercell', album: 'supercell', genre: 'J-Pop', mood: Mood.festa, added: 1);
  final bare = tr('faixa 03', unknownArtist); // sem metadados
  final lib = [numb, faint, acao, cafe, miku, bare];

  test('normaliza acentos, maiúsculas e símbolos', () {
    expect(normalizeText('  AÇÃO!! e  Reação '), 'acao e reacao');
    expect(normalizeText('【MV】 ワールド'), 'mv ワールド');
    expect(editDistance('linkn', 'linkin', 2), 1);
    expect(editDistance('naruto', 'nrauto', 1), 1); // letras trocadas contam como 1 erro
  });

  test('busca por título, artista, álbum, gênero e clima', () {
    final idx = LibraryIndex.build(lib);
    List<Track> q(String s) => [for (final (t, _) in idx.search(s)) t];
    expect(q('numb').first, numb);
    expect(q('linkin').toSet(), {numb, faint});
    expect(q('meteora').toSet(), {numb, faint});
    expect(q('j-pop'), [miku]);
    expect(q('calmo'), [cafe]);
    expect(q('festa'), contains(miku));
    expect(q('faixa'), [bare]);
  });

  test('ignora acentos, maiúsculas e aceita pedaço de palavra', () {
    final idx = LibraryIndex.build(lib);
    List<Track> q(String s) => [for (final (t, _) in idx.search(s)) t];
    expect(q('acao').first, acao);
    expect(q('REAÇÃO').first, acao);
    expect(q('cafe manha'), [cafe]);
    expect(q('anon'), [cafe]);
    expect(q('lin park').toSet(), {numb, faint});
  });

  test('tolera pequenos erros de digitação e ordena pelo mais parecido', () {
    final idx = LibraryIndex.build(lib);
    List<Track> q(String s) => [for (final (t, _) in idx.search(s)) t];
    expect(q('linkn park').toSet(), {numb, faint});
    expect(q('supercel'), [miku]);
    expect(q('nubm'), [numb]);
    expect(q('xyzzy'), isEmpty);
    // título exato vem antes de quem só bate pelo artista
    final r = idx.search('faint');
    expect(r.first.$1, faint);
  });

  test('índice reaproveitado enquanto a biblioteca não muda', () {
    expect(identical(LibraryIndex.of(lib), LibraryIndex.of(lib)), isTrue);
    expect(identical(LibraryIndex.of(lib), LibraryIndex.of([...lib])), isFalse);
  });

  test('filtros combinados e ordenação', () {
    final rock = tr('Outra', 'Linkin Park', genre: 'Rock', mood: Mood.acao);
    final all = [...lib, rock];
    expect(queryLibrary(all, filter: const TrackFilter(artist: 'Linkin Park', genre: 'nu metal')).toSet(), {numb, faint});
    expect(queryLibrary(all, filter: const TrackFilter(artist: 'Linkin Park', mood: Mood.acao, genre: 'Rock')), [rock]);
    expect(queryLibrary(all, filter: const TrackFilter(artist: 'Linkin Park', favoritesOnly: true)), [numb]);
    expect(queryLibrary(all, query: 'linkin', filter: const TrackFilter(genre: 'Rock')), [rock]);

    expect(queryLibrary(lib, sort: TrackSort.title).first, acao);
    expect(queryLibrary(lib, sort: TrackSort.added).first, numb);
    expect(queryLibrary(lib, sort: TrackSort.favorites).first, numb);
    final stats = PlayStats(plays: {miku.id!: 9, faint.id!: 3}, lastPlayed: {faint.id!: 100, miku.id!: 50});
    expect(queryLibrary(lib, sort: TrackSort.plays, stats: stats).take(2), [miku, faint]);
    expect(queryLibrary(lib, sort: TrackSort.recent, stats: stats).take(2), [faint, miku]);
    // sem busca e "relevância": cai na ordem por artista (como a lista normal)
    expect(queryLibrary(lib).length, lib.length);
  });

  test('coleções automáticas acompanham biblioteca e histórico', () {
    final now = DateTime(2026, 11, 16);
    Track withAdded(Track t, int daysAgo) => Track(id: t.id, path: t.path, title: t.title, artist: t.artist, album: t.album, genre: t.genre, mood: t.mood, favorite: t.favorite, addedAt: now.subtract(Duration(days: daysAgo)).millisecondsSinceEpoch, modifiedAt: 0);
    final l = [withAdded(numb, 2), withAdded(faint, 90), withAdded(acao, 400), withAdded(bare, 1)];
    var stats = PlayStats(plays: {numb.id!: 5, faint.id!: 1});
    var cols = {for (final c in buildSmartCollections(l, stats, current: l.first, now: now)) c.id: c};
    expect(cols['top']!.tracks.map((t) => t.id), [numb.id, faint.id]);
    expect(cols['rare']!.tracks.map((t) => t.id), containsAll([acao.id, bare.id, faint.id]));
    expect(cols['rare']!.tracks.map((t) => t.id), isNot(contains(numb.id)));
    expect(cols['added']!.tracks.map((t) => t.id).toSet(), {numb.id, bare.id});
    expect(cols['fav']!.tracks.single.id, numb.id);
    expect(cols['similar']!.tracks.first.id, faint.id);
    expect(cols.keys, contains('mood:acao')); // rock -> clima ação pelo gênero
    // tocou mais: a coleção muda
    stats = PlayStats(plays: {numb.id!: 5, faint.id!: 1, acao.id!: 8});
    cols = {for (final c in buildSmartCollections(l, stats, now: now)) c.id: c};
    expect(cols['top']!.tracks.first.id, acao.id);
    expect(cols.containsKey('similar'), isFalse);
  });

  test('recomendações: afinidade ponderada, sem concentrar num artista e com músicas novas', () {
    final many = [for (var i = 0; i < 10; i++) tr('Ghost $i', 'Ghost', album: 'Album ${i % 2}', genre: 'Rock')];
    final others = [tr('R1', 'Foo Fighters', genre: 'Rock'), tr('R2', 'Pitty', genre: 'Rock'), tr('P1', 'Pop', genre: 'Pop')];
    final all = [...many, ...others];
    final now = DateTime(2026, 11, 16, 20);
    final plays = [
      for (var i = 0; i < 6; i++) Play(trackId: many[i % 3].id!, playedAt: now.subtract(Duration(days: 2, minutes: i)).millisecondsSinceEpoch, secondsListened: 200, skipped: false),
    ];
    final mix = Recommender(all, plays, now: now).mix(limit: 5);
    final ghost = mix.where((r) => r.track.artist == 'Ghost').toList();
    expect(ghost.length, lessThanOrEqualTo(3));
    final perAlbum = <String, int>{};
    for (final r in ghost) {
      perAlbum[r.track.album] = (perAlbum[r.track.album] ?? 0) + 1;
    }
    expect(perAlbum.values.every((n) => n <= 2), isTrue);
    expect(mix.map((r) => r.track.artist), containsAll(['Foo Fighters', 'Pitty']));
    expect(mix.any((r) => r.reason.contains('nunca tocou')), isTrue);

    final radio = Recommender(all, plays, now: now).radio(many.first);
    expect(radio.first.track.artist, 'Ghost');
    expect(radio.map((r) => r.track.artist).take(6), contains('Foo Fighters'));
  });

  test('sem metadados: nada quebra e nenhuma música some da biblioteca', () {
    final empties = [for (var i = 0; i < 5; i++) tr('t$i', unknownArtist)];
    expect(Recommender.affinity(empties[0], empties[1]), 0); // "Artista desconhecido" não conta como mesmo artista
    expect(Recommender(empties, const []).mix(), isEmpty);
    expect(Recommender(empties, const []).radio(empties.first), isEmpty);
    expect(Recommender.similar(empties.first, empties), isEmpty);
    expect(queryLibrary(empties).length, 5);
    expect(queryLibrary(empties, query: 't3'), [empties[3]]);
    final cols = buildSmartCollections(empties, PlayStats.empty, current: empties.first);
    expect(cols.firstWhere((c) => c.id == 'rare').tracks.length, 5);
  });
}
