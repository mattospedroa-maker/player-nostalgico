import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/artist_names.dart';
import 'package:player_nostalgico/library_search.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/player_service.dart';

Track _t(int id, String artist) =>
    Track(id: id, path: '/m/$id.mp3', title: 'música $id', artist: artist, album: 'Álbum', addedAt: 0, modifiedAt: 0);

void main() {
  tearDown(() => ArtistNames.current = ArtistNames.from(const []));

  test('parcerias do print viram um artista só: MC VV', () {
    const names = [
      'MC VV & BOFE',
      'MC VV & BOFE',
      'MC VV & BOFFE',
      'MC VV & LAUNZERA',
      'MC VV & PREDO',
      'MC VV & YOMAMARU',
      'MC VV (ft. LAUNZERA)',
      'MC VV (ft. LUCKHAUS)',
      'MC VV prod MC VV',
      'MC VV, BOFE & JEAN XEROSO',
      'Mc Vv x Predo',
    ];
    final g = ArtistNames.from(names);
    for (final n in names) {
      expect(g.main(n), 'MC VV', reason: n);
    }
    expect(names.map(g.key).toSet().length, 1);
  });

  test('feat./ft./prod sempre separam, mesmo sem o artista sozinho na biblioteca', () {
    final g = ArtistNames.from(const ['Anitta feat. Cardi B', 'Daft Punk ft. Pharrell', 'The Prodigy', 'Kanye West (prod. Mike Dean)']);
    expect(g.main('Anitta feat. Cardi B'), 'Anitta');
    expect(g.main('Daft Punk ft. Pharrell'), 'Daft Punk');
    expect(g.main('The Prodigy'), 'The Prodigy');
    expect(g.main('Kanye West (prod. Mike Dean)'), 'Kanye West');
  });

  test('bandas com "&" ou vírgula no nome continuam inteiras', () {
    final g = ArtistNames.from(const [
      'Simon & Garfunkel',
      'Earth, Wind & Fire',
      'Mumford & Sons',
      'Mumford & Sons, Baaba Maal',
      'Zé Neto e Cristiano',
      'Paul Simon',
    ]);
    expect(g.main('Simon & Garfunkel'), 'Simon & Garfunkel');
    expect(g.main('Earth, Wind & Fire'), 'Earth, Wind & Fire');
    expect(g.main('Mumford & Sons, Baaba Maal'), 'Mumford & Sons');
    expect(g.main('Zé Neto e Cristiano'), 'Zé Neto e Cristiano');
  });

  test('parceria sem o artista sozinho: junta quando ele começa duas parcerias', () {
    final g = ArtistNames.from(const ['Matuê & Teto', 'Matuê, Wiu', 'Teto']);
    expect(g.main('Matuê & Teto'), 'Matuê');
    expect(g.main('Matuê, Wiu'), 'Matuê');
    expect(g.main('Teto'), 'Teto');
  });

  test('parceria em que o OUTRO nome existe sozinho: fica o primeiro', () {
    final g = ArtistNames.from(const ['Anitta & Ludmilla', 'Ludmilla', 'Henrique & Juliano', 'Simon & Garfunkel']);
    expect(g.main('Anitta & Ludmilla'), 'Anitta');
    expect(g.main('Ludmilla'), 'Ludmilla');
    expect(g.main('Henrique & Juliano'), 'Henrique & Juliano');
    expect(g.main('Simon & Garfunkel'), 'Simon & Garfunkel');
  });

  test('"Do mesmo artista" no mix pega as parcerias', () {
    final lib = [_t(1, 'MC VV'), _t(2, 'MC VV & BOFE'), _t(3, 'MC VV (ft. LAUNZERA)'), _t(4, 'Outro Cara'), _t(5, 'Outra Banda')];
    ArtistNames.current = ArtistNames.fromTracks(lib);
    final picks = PlayerService.pickMix(lib.first, lib, mode: MixMode.artist, count: 2);
    expect(picks.map((t) => t.id).toSet(), {2, 3});
  });

  test('"Do mesmo artista" com nome que tem & (G&TH) traz as faixas dele, não outros', () {
    final lib = [
      for (var i = 1; i <= 11; i++) _t(i, 'G&TH'),
      _t(20, 'Nirvana'),
      _t(21, 'The Living Tombstone'),
      _t(22, 'Nirvana'),
    ];
    ArtistNames.current = ArtistNames.fromTracks(lib);
    final picks = PlayerService.pickMix(lib[6], lib, mode: MixMode.artist, count: 10);
    expect(picks.length, 10);
    expect(picks.every((t) => t.artist == 'G&TH'), isTrue);
  });

  test('parceria aparece em cada artista: MC VV & BOFE -> MC VV e BOFE', () {
    const lib = [
      'MC VV & BOFE',
      'MC VV & PREDO',
      'MC VV (ft. LAUNZERA)',
      'MC VV prod MC VV',
      'MC VV, BOFE & JEAN XEROSO',
      'BOFE',
      'Simon & Garfunkel',
      'Anitta feat. Cardi B & Ludmilla',
      'Kanye West (prod. Mike Dean)',
    ];
    final g = ArtistNames.from(lib);
    expect(g.names('MC VV & BOFE'), ['MC VV', 'BOFE']);
    expect(g.names('MC VV & PREDO'), ['MC VV', 'PREDO']);
    expect(g.names('MC VV (ft. LAUNZERA)'), ['MC VV', 'LAUNZERA']);
    expect(g.names('MC VV prod MC VV'), ['MC VV']);
    expect(g.names('MC VV, BOFE & JEAN XEROSO'), ['MC VV', 'BOFE', 'JEAN XEROSO']);
    expect(g.names('Simon & Garfunkel'), ['Simon & Garfunkel']);
    expect(g.names('Anitta feat. Cardi B & Ludmilla'), ['Anitta', 'Cardi B', 'Ludmilla']);
    expect(g.names('Kanye West (prod. Mike Dean)'), ['Kanye West'], reason: 'produtor não conta como artista');
    expect(g.credits('MC VV, BOFE & JEAN XEROSO', 'BOFE'), isTrue);
    expect(g.credits('MC VV & PREDO', 'BOFE'), isFalse);
    expect(g.shares('BOFE', 'MC VV & BOFE'), isTrue);
    expect(g.shares('BOFE', 'MC VV & PREDO'), isFalse);
  });

  test('filtro de artista: BOFE acha as parcerias, e a música não se repete', () {
    final lib = [_t(1, 'MC VV & BOFE'), _t(2, 'MC VV & PREDO'), _t(3, 'BOFE'), _t(4, 'MC VV')];
    ArtistNames.current = ArtistNames.fromTracks(lib);
    final bofe = lib.where(const TrackFilter(artist: 'BOFE').matches).map((t) => t.id).toList();
    expect(bofe, [1, 3]);
    final vv = lib.where(const TrackFilter(artist: 'MC VV').matches).map((t) => t.id).toList();
    expect(vv, [1, 2, 4]);
  });
}
