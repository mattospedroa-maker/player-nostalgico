import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/filename_parser.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/organizer.dart';

class FakeMeta implements MetadataReader {
  final Map<String, TagInfo> tags;
  FakeMeta(this.tags);
  @override
  Future<TagInfo?> read(String path) async => tags[p.basename(path)];
  @override
  Future<Uint8List?> cover(String path) async => null;
}

Map<String, dynamic> mbResponse({required String title, required String artist, required List<Map<String, dynamic>> releases, int score = 100}) => {
      'recordings': [
        {
          'title': title,
          'score': score,
          'artist-credit': [
            {'name': artist, 'artist': {'name': artist}}
          ],
          'releases': releases,
        }
      ]
    };

void main() {
  group('parseFileName', () {
    test('artista - título com lixo de download', () {
      final r = parseFileName('03 - supercell - World is Mine (Official Video) [320kbps]');
      expect(r.artist, 'supercell');
      expect(r.title, 'World is Mine');
    });
    test('nomes como os da pasta do usuário', () {
      var r = parseFileName('00 - 002 - 【Hatsune Miku】 World is Mine 【Legenda PT-BR】');
      expect(r.artist, 'Hatsune Miku');
      expect(r.title, 'World is Mine');
      r = parseFileName('00-20 ▓ Vocaloid ▓ Rolling Girl');
      expect(r.artist, isNull);
      expect(r.title, 'Rolling Girl');
      r = parseFileName('017 - Rammstein - Sonne');
      expect(r.artist, 'Rammstein');
      expect(r.title, 'Sonne');
      expect(cleanArtistName('▓ Vocaloid ▓'), isNull);
      expect(cleanArtistName('【Hatsune Miku】'), 'Hatsune Miku');
    });
    test('só título', () {
      final r = parseFileName('Hare_Hare_Yukai');
      expect(r.artist, isNull);
      expect(r.title, 'Hare Hare Yukai');
    });
  });

  test('safeFolderName remove caracteres proibidos', () {
    expect(safeFolderName('AC/DC'), 'AC_DC');
    expect(safeFolderName('What?: "Live" <2009>.'), 'What__ _Live_ _2009_');
    expect(safeFolderName('   '), '_');
  });

  group('MusicBrainz', () {
    test('prefere álbum oficial a single e coletânea', () {
      final info = MusicBrainzClient.parseRecordingSearch(
        mbResponse(title: 'Ritual', artist: 'Ghost', releases: [
          {'title': 'Ritual (single)', 'status': 'Official', 'date': '2010', 'release-group': {'primary-type': 'Single'}},
          {'title': 'Metal Hits 2012', 'status': 'Official', 'date': '2012', 'release-group': {'primary-type': 'Album', 'secondary-types': ['Compilation']}},
          {'title': 'Opus Eponymous', 'status': 'Official', 'date': '2010-10-18', 'release-group': {'primary-type': 'Album'}},
        ]),
        title: 'Ritual',
      );
      expect(info, isNotNull);
      expect(info!.artist, 'Ghost');
      expect(info.album, 'Opus Eponymous');
    });

    test('ignora resultados com pontuação baixa', () {
      final info = MusicBrainzClient.parseRecordingSearch(
        mbResponse(title: 'x', artist: 'y', score: 40, releases: [
          {'title': 'z', 'release-group': {'primary-type': 'Album'}}
        ]),
        title: 'x',
      );
      expect(info, isNull);
    });

    test('envia User-Agent e consulta título + artista', () async {
      late Uri seen;
      late Map<String, String> headers;
      final client = MockClient((req) async {
        seen = req.url;
        headers = req.headers;
        return http.Response(
            jsonEncode(mbResponse(title: 'Melt', artist: 'ryo', releases: [
              {'title': 'supercell', 'status': 'Official', 'release-group': {'primary-type': 'Album'}}
            ])),
            200);
      });
      final mb = MusicBrainzClient(client: client, minInterval: Duration.zero);
      final info = await mb.lookup('Melt', artist: 'ryo');
      expect(seen.host, 'musicbrainz.org');
      expect(seen.queryParameters['query'], 'recording:"Melt" AND artist:"ryo"');
      expect(headers['User-Agent'], contains('PlayerNostalgico'));
      expect(info!.album, 'supercell');
    });
  });

  group('Organizer', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('org_test'));
    tearDown(() => root.deleteSync(recursive: true));

    File touch(String rel) => File(p.join(root.path, rel))
      ..createSync(recursive: true)
      ..writeAsStringSync('audio');

    test('planeja, move para Artista/Álbum e desfaz', () async {
      touch('World is Mine.mp3');
      touch('baixadas/Ghost - Ritual.mp3');
      touch('Ghost/Opus Eponymous/Elizabeth.mp3'); // já organizada pelas tags
      touch('musica estranha.mp3');
      touch('GIFs/nao_mexer.mp3'); // pasta de GIFs é ignorada

      final client = MockClient((req) async {
        final q = req.url.queryParameters['query']!;
        if (q.contains('World is Mine')) {
          return http.Response(
              jsonEncode(mbResponse(title: 'World is Mine', artist: 'supercell', releases: [
                {'title': 'supercell', 'status': 'Official', 'release-group': {'primary-type': 'Album'}}
              ])),
              200);
        }
        if (q.contains('Ritual')) {
          return http.Response(
              jsonEncode(mbResponse(title: 'Ritual', artist: 'Ghost', releases: [
                {'title': 'Opus Eponymous', 'status': 'Official', 'release-group': {'primary-type': 'Album'}}
              ])),
              200);
        }
        return http.Response(jsonEncode({'recordings': []}), 200);
      });
      final org = Organizer(
        sourceRoot: root.path,
        mb: MusicBrainzClient(client: client, minInterval: Duration.zero),
        metadata: FakeMeta({'Elizabeth.mp3': const TagInfo(title: 'Elizabeth', artist: 'Ghost', album: 'Opus Eponymous')}),
      );

      final plan = await org.buildPlan();
      expect(plan.length, 4);
      final byName = {for (final i in plan) p.basename(i.sourcePath): i};
      expect(byName['World is Mine.mp3']!.status, PlanStatus.move);
      expect(byName['World is Mine.mp3']!.targetPath, p.join(root.path, 'supercell', 'supercell', 'World is Mine.mp3'));
      expect(byName['Ghost - Ritual.mp3']!.targetPath, p.join(root.path, 'Ghost', 'Opus Eponymous', 'Ritual.mp3'));
      expect(byName['Elizabeth.mp3']!.status, PlanStatus.alreadyOrganized);
      expect(byName['musica estranha.mp3']!.status, PlanStatus.notFound);

      final undoLog = p.join(root.path, '..', 'undo_${DateTime.now().microsecondsSinceEpoch}.json');
      final moved = await org.execute(plan, undoLogPath: undoLog);
      expect(moved.length, 2);
      expect(File(p.join(root.path, 'supercell', 'supercell', 'World is Mine.mp3')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'Ghost', 'Opus Eponymous', 'Ritual.mp3')).existsSync(), isTrue);
      expect(Directory(p.join(root.path, 'baixadas')).existsSync(), isFalse, reason: 'pasta vazia é removida');
      expect(File(p.join(root.path, 'musica estranha.mp3')).existsSync(), isTrue, reason: 'não identificada fica no lugar');

      final undone = await Organizer.undo(undoLog, root.path);
      expect(undone.length, 2);
      expect(File(p.join(root.path, 'World is Mine.mp3')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'baixadas', 'Ghost - Ritual.mp3')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'Ghost', 'Opus Eponymous', 'Elizabeth.mp3')).existsSync(), isTrue);
    });

    test('não sobrescreve arquivo com o mesmo nome no destino', () async {
      touch('Ghost/Opus Eponymous/Ritual.mp3');
      touch('Ritual.mp3');
      final org = Organizer(
        sourceRoot: root.path,
        mb: MusicBrainzClient(client: MockClient((_) async => http.Response('{}', 200)), minInterval: Duration.zero),
        metadata: FakeMeta({'Ritual.mp3': const TagInfo(title: 'Ritual', artist: 'Ghost', album: 'Opus Eponymous')}),
      );
      final plan = await org.buildPlan();
      final mv = plan.firstWhere((i) => i.status == PlanStatus.move);
      expect(p.basename(mv.targetPath!), 'Ritual (2).mp3');
    });
  });
}
