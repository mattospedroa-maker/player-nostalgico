import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/youtube_names.dart';

void main() {
  test('Artista - Título com enfeites', () {
    final n = guessYoutubeNames({'title': 'Rammstein - Du Hast (Official 4K Video) 【HD】', 'channel': 'Rammstein Official'});
    expect(n.artist, 'Rammstein');
    expect(n.title, 'Du Hast');
    expect(n.album, unknownAlbum);
  });

  test('números e lixo no fim', () {
    expect(guessYoutubeNames({'title': '01 - Linkin Park - Numb [Official Music Video]'}).title, 'Numb');
    final d = guessYoutubeNames({'title': 'Slipknot - Duality [OFFICIAL VIDEO] 4K'});
    expect(d.artist, 'Slipknot');
    expect(d.title, 'Duality');
  });

  test('símbolos decorativos', () {
    final n = guessYoutubeNames({'title': '▓ System Of A Down ▓ Chop Suey! (HD)'});
    expect(n.artist, 'System Of A Down');
    expect(n.title, 'Chop Suey!');
  });

  test('campos do YouTube Music têm prioridade', () {
    final n = guessYoutubeNames({
      'title': 'Numb (Official Video) - Linkin Park',
      'track': 'Numb',
      'artist': 'Linkin Park, Jay-Z',
      'album': 'Meteora',
      'channel': 'Linkin Park - Topic',
    });
    expect(n.artist, 'Linkin Park');
    expect(n.title, 'Numb');
    expect(n.album, 'Meteora');
  });

  test('sem artista no título: usa o canal', () {
    expect(guessYoutubeNames({'title': 'Du Hast', 'channel': 'RammsteinVEVO'}).artist, 'Rammstein');
    expect(guessYoutubeNames({'title': 'Numb', 'channel': 'LinkinParkVEVO'}).artist, 'Linkin Park');
    expect(guessYoutubeNames({'title': 'Duality', 'channel': 'Slipknot - Topic'}).artist, 'Slipknot');
    expect(guessYoutubeNames({'title': 'Numb', 'channel': 'Warner Records'}).artist, unknownArtist);
  });

  test('(feat.) continua no título', () {
    expect(guessYoutubeNames({'title': 'Eminem - Till I Collapse (feat. Nate Dogg) [Lyrics]'}).title, 'Till I Collapse (feat. Nate Dogg)');
  });

  test('canal com Official/Music/TV grudado ou separado', () {
    expect(artistFromChannel('MadrugadaOfficial'), 'Madrugada');
    expect(artistFromChannel('madrugadaofficial'), 'madrugada');
    expect(artistFromChannel('Madrugada Official Channel'), 'Madrugada');
    expect(artistFromChannel('Anitta Oficial'), 'Anitta');
    expect(artistFromChannel('Ghost - Official'), 'Ghost');
    expect(artistFromChannel('GhostMusic'), 'Ghost');
    expect(artistFromChannel('PitbullTV'), 'Pitbull');
    expect(artistFromChannel('Electromusic'), 'Electromusic');
    expect(artistFromChannel('Unofficial'), 'Unofficial');
    expect(guessYoutubeNames({'title': 'Electric', 'channel': 'MadrugadaOfficial'}).artist, 'Madrugada');
  });

  test('jeitos de escrever o artista para o MusicBrainz', () {
    expect(artistNameVariants('MadrugadaOfficial'), ['MadrugadaOfficial', 'Madrugada']);
    expect(artistNameVariants('LinkinParkVEVO'), ['LinkinParkVEVO', 'LinkinPark', 'Linkin Park']);
    expect(artistNameVariants('Madrugada'), ['Madrugada']);
    expect(artistNameVariants('Roxy Music').first, 'Roxy Music');
  });
}
