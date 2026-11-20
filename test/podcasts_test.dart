import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/download_service.dart';
import 'package:player_nostalgico/library_scanner.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/organizer.dart';
import 'package:player_nostalgico/podcasts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Meta implements MetadataReader {
  @override
  Future<TagInfo?> read(String path) async => p.basename(path).startsWith('ep')
      ? const TagInfo(title: 'Ep. 12 - Convidado Fulano #412', artist: 'Canal Errado', album: 'x', duration: Duration(hours: 2))
      : null;
  @override
  Future<Uint8List?> cover(String path) async => null;
}

Track _t(String path, {String title = 't', String artist = 'A', int minutes = 3, int id = 1}) =>
    Track(id: id, path: path, title: title, artist: artist, album: 'al', durationMs: minutes * 60000, addedAt: id, modifiedAt: 0);

void main() {
  sqfliteFfiInit();

  test('podcast = arquivo dentro de <raiz>/Podcasts/, programa = pasta', () {
    const root = '/m';
    expect(isPodcastPath(root, '/m/Podcasts/Flow/ep.mp3'), isTrue);
    expect(isPodcastPath(root, '/m/podcasts/ep.mp3'), isTrue);
    expect(isPodcastPath(root, '/m/Rock/Podcasts/x.mp3'), isFalse);
    expect(isPodcastPath(root, '/m/Podcasts'), isFalse);
    expect(isPodcastPath(null, '/m/Podcasts/a.mp3'), isFalse);
    expect(programFromPath(root, '/m/Podcasts/Flow/ep.mp3'), 'Flow');
    expect(programFromPath(root, '/m/Podcasts/ep.mp3'), isNull);
    expect(podcastTargetPath(root, 'Flow: Podcast?', 'a.mp3'), p.join(root, 'Podcasts', safeFolderName('Flow: Podcast?'), 'a.mp3'));
    expect(p.basename(p.dirname(podcastTargetPath(root, '  ', 'a.mp3'))), unknownProgram);
  });

  test('leitura da pasta: episódio fica com o programa da pasta e o título inteiro; organizador ignora Podcasts', () async {
    final root = Directory.systemTemp.createTempSync('pod_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
    addTearDown(db.db.close);
    for (final rel in ['Podcasts/Flow Podcast/ep1.mp3', 'Artista/Album/musica.mp3']) {
      File(p.join(root.path, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    await LibraryScanner(db, _Meta()).scan(root.path);
    final ep = (await db.allTracks()).firstWhere((t) => isPodcastPath(root.path, t.path));
    expect(ep.artist, 'Flow Podcast');
    expect(ep.album, 'Flow Podcast');
    expect(ep.title, 'Ep. 12 - Convidado Fulano #412');

    final org = Organizer(sourceRoot: root.path, mb: MusicBrainzClient(), metadata: _Meta(), useOnline: false);
    expect(org.filesToCheck().map((f) => p.basename(f.path)), ['musica.mp3']);
  });

  test('sugestão: longo com pista no título vem marcado; só longo vem desmarcado; curto ou dispensado não aparece', () {
    final c = findPodcastCandidates([
      _t('/m/a.mp3', title: 'Flow Podcast #412 - Convidado', minutes: 151, id: 1),
      _t('/m/b.mp3', title: 'Entrevista completa com Fulano', minutes: 72, id: 2),
      _t('/m/c.mp3', title: 'Echoes (live)', minutes: 23, id: 3),
      _t('/m/d.mp3', title: 'Mix de 2 horas', minutes: 120, id: 4),
      _t('/m/e.mp3', title: 'Podcast curto', minutes: 5, id: 5),
      _t('/m/f.mp3', title: 'Podcast dispensado', minutes: 90, id: 6),
    ], dismissed: {'/m/f.mp3'});
    expect(c.map((x) => x.track.id), [2, 1, 4]);
    expect(c.where((x) => x.strong).map((x) => x.track.id).toSet(), {1, 2});
    expect(c.firstWhere((x) => x.track.id == 4).reason, contains('só a duração'));
  });

  test('YouTube: adivinha podcast pelo link, pela categoria ou por duração + título', () {
    expect(looksLikePodcastVideo({'title': 'Flow #412 com Fulano', 'duration': 9000}), isTrue);
    expect(looksLikePodcastVideo({'title': 'Música nova (clipe oficial)', 'duration': 200}), isFalse);
    expect(looksLikePodcastVideo({'title': 'Episódio 3', 'duration': 300}), isFalse); // curto demais
    expect(looksLikePodcastVideo({'title': 'x', 'duration': 100}, url: 'https://music.youtube.com/podcast/abc'), isTrue);
    expect(looksLikePodcastVideo({'title': 'x', 'categories': ['Podcasts']}), isTrue);

    final e = YtEntry.fromInfo({'id': 'v1', 'title': 'Joe Rogan Experience #2100 - Convidada', 'channel': 'PowerfulJRE', 'duration': 10000});
    expect(e.podcast, isTrue);
    expect(e.names.artist, 'PowerfulJRE');
    expect(e.names.title, 'Joe Rogan Experience #2100 - Convidada');
    expect(e.musicNames.artist, isNot('PowerfulJRE')); // trocar para Música volta ao nome adivinhado de música
    final m = YtEntry.fromInfo({'id': 'v2', 'title': 'Linkin Park - Numb', 'channel': 'Linkin Park', 'duration': 190});
    expect(m.podcast, isFalse);
  });

  test('onde parou: guarda, continua, marca ouvido perto do fim e acompanha arquivo movido', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final prog = PodcastProgress(prefs);
    const total = Duration(hours: 2);
    prog.save('/a.mp3', const Duration(seconds: 10), total);
    expect(prog.resumeAt('/a.mp3'), isNull); // comecinho não conta
    prog.save('/a.mp3', const Duration(minutes: 62), total);
    expect(prog.resumeAt('/a.mp3'), const Duration(minutes: 62));
    prog.save('/b.mp3', const Duration(minutes: 5), total);
    final eps = [_t('/a.mp3', id: 1), _t('/b.mp3', id: 2)];
    expect(prog.lastInProgress(eps)?.path, '/b.mp3');

    // relendo das preferências (app reaberto)
    final again = PodcastProgress(prefs);
    expect(again.resumeAt('/a.mp3'), const Duration(minutes: 62));

    again.save('/a.mp3', total - const Duration(seconds: 20), total);
    expect(again.listened('/a.mp3'), isTrue);
    expect(again.resumeAt('/a.mp3'), isNull);

    again.moved('/b.mp3', '/c.mp3');
    expect(again.resumeAt('/c.mp3'), const Duration(minutes: 5));
    expect(again.resumeAt('/b.mp3'), isNull);
  });

  test('programas agrupados e busca por título ou programa sem acento', () {
    final eps = [
      _t('/1', title: 'Episódio sobre Ação', artist: 'Flow', id: 1),
      _t('/2', title: 'Outro', artist: 'Flow', id: 2),
      _t('/3', title: 'Ciência', artist: 'PowerfulJRE', id: 3),
    ];
    final g = groupPrograms(eps);
    expect(g.map((x) => x.name), ['Flow', 'PowerfulJRE']);
    expect(g.first.episodes.map((t) => t.id), [2, 1]); // mais novo primeiro
    expect(searchEpisodes(eps, 'acao').map((t) => t.id), [1]);
    expect(searchEpisodes(eps, 'jre').map((t) => t.id), [3]);
  });
}
