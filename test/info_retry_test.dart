import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/info_retry.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/organizer.dart';

Track _t(String path, {String artist = unknownArtist, String album = unknownAlbum, String title = 'Looking Out For You'}) =>
    Track(id: 1, path: path, title: title, artist: artist, album: album, addedAt: 0, modifiedAt: 0);

void main() {
  const root = '/m/Fonte';
  final joy = _t('$root/Joy Again/Álbum desconhecido/Looking Out For You.m4a');

  test('tentativas espaçadas: 1 h, 1 dia, 3 dias, depois semanal', () {
    final now = DateTime(2026, 11, 22, 12);
    expect(InfoRetry.due(0, null, now), isTrue);
    expect(InfoRetry.due(1, now.subtract(const Duration(minutes: 30)), now), isFalse);
    expect(InfoRetry.due(1, now.subtract(const Duration(hours: 2)), now), isTrue);
    expect(InfoRetry.due(2, now.subtract(const Duration(hours: 5)), now), isFalse);
    expect(InfoRetry.due(9, now.subtract(const Duration(days: 6)), now), isFalse);
    expect(InfoRetry.due(9, now.subtract(const Duration(days: 8)), now), isTrue);
  });

  test('falta artista ou álbum', () {
    expect(InfoRetry.missing(joy), isTrue);
    expect(InfoRetry.missing(_t('x.m4a', artist: 'Joy Again', album: 'Looking Out For You')), isFalse);
  });

  test('a pasta Joy Again vira pista', () {
    expect(InfoRetry.hints(joy, root: root), ['Joy Again']);
  });

  test('aceita só a resposta que bate com a pista', () {
    const certo = SongInfo(title: 'Looking Out for You', artist: 'Joy Again', album: 'Looking Out for You', score: 100, source: 'musicbrainz');
    expect(InfoRetry.decide(joy, certo, ['Joy Again'])?.album, 'Looking Out for You');
    // outro artista (o MusicBrainz devolve no máximo 60): fica com a pasta, sem o álbum errado
    const outro = SongInfo(title: 'Looking Out For You', artist: 'Rvshvd', album: "IT'S RASHAD", score: 60, source: 'musicbrainz');
    final d = InfoRetry.decide(joy, outro, ['Joy Again']);
    expect(d?.artist, 'Joy Again');
    expect(d?.album, unknownAlbum);
  });

  test('sem pista nenhuma não adivinha', () {
    const r = SongInfo(title: 'x', artist: 'y', album: 'z', score: 100, source: 'musicbrainz');
    expect(InfoRetry.decide(_t('/m/Fonte/solta.m4a'), r, const []), isNull);
  });
}
