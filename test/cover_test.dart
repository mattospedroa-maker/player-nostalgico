import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player_nostalgico/cover_service.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/organizer.dart';

class Meta implements MetadataReader {
  final Uint8List? art;
  Meta(this.art);
  @override
  Future<TagInfo?> read(String path) async => null;
  @override
  Future<Uint8List?> cover(String path) async => art;
}

Track t(String title, String artist, String album) =>
    Track(path: '/m/$artist/$album/$title.mp3', title: title, artist: artist, album: album, addedAt: 0, modifiedAt: 0);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('capas'));
  tearDown(() => dir.deleteSync(recursive: true));

  final jpg = Uint8List.fromList(List.filled(4000, 7));

  MockClient server({int mbStatus = 200}) => MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          if (mbStatus != 200) return http.Response('', mbStatus);
          return http.Response(jsonEncode({'release-groups': [{'id': 'rg1', 'score': 100}]}), 200);
        }
        if (req.url.host == 'coverartarchive.org') return http.Response.bytes(jpg, 200);
        return http.Response('', 404);
      });

  test('capa oficial do álbum tem prioridade sobre a miniatura do YouTube', () async {
    final c = server();
    final svc = CoverService(dir.path, Meta(Uint8List.fromList(List.filled(2000, 1))), client: c);
    final tried = <String>{};
    final track = t('Numb', 'Linkin Park', 'Meteora');
    final n = await svc.fetchMissing([track], tried, mb: MusicBrainzClient(client: c, minInterval: Duration.zero));
    expect(n, 1);
    expect(svc.fileFor(track)!.readAsBytesSync().first, 7);
  });

  test('MusicBrainz fora do ar: usa a capa do arquivo e tenta o álbum de novo depois', () async {
    final c = server(mbStatus: 503);
    final svc = CoverService(dir.path, Meta(null), client: c);
    final tried = <String>{};
    final track = t('Numb', 'Linkin Park', 'Meteora');
    await svc.fetchMissing([track], tried, mb: MusicBrainzClient(client: c, minInterval: Duration.zero));
    expect(svc.fileFor(track), isNull);
    expect(tried, isEmpty); // não marca como tentado
  });

  test('sem álbum: usa a capa gravada na música', () async {
    final c = server();
    final svc = CoverService(dir.path, Meta(Uint8List.fromList(List.filled(2000, 3))), client: c);
    final track = t('Where Did You Sleep Last Night', 'Nirvana', unknownAlbum);
    final n = await svc.fetchMissing([track], <String>{}, mb: MusicBrainzClient(client: c, minInterval: Duration.zero));
    expect(n, 1);
    expect(svc.fileFor(track)!.readAsBytesSync().first, 3);
  });
}
