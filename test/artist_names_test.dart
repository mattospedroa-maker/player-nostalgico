import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/artist_names.dart';
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

  test('"Do mesmo artista" no mix pega as parcerias', () {
    final lib = [_t(1, 'MC VV'), _t(2, 'MC VV & BOFE'), _t(3, 'MC VV (ft. LAUNZERA)'), _t(4, 'Outro Cara'), _t(5, 'Outra Banda')];
    ArtistNames.current = ArtistNames.fromTracks(lib);
    final picks = PlayerService.pickMix(lib.first, lib, mode: MixMode.artist, count: 2);
    expect(picks.map((t) => t.id).toSet(), {2, 3});
  });
}
