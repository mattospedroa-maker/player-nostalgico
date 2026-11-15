import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'metadata.dart';
import 'models.dart';
import 'organizer.dart';

/// Capas de álbum: usa a da música/pasta se tiver; senão busca no Cover Art Archive (MusicBrainz) e guarda.
class CoverService {
  final String dir;
  final MetadataReader metadata;
  final http.Client client;
  CoverService(String dataDir, this.metadata, {http.Client? client})
      : dir = p.join(dataDir, 'capas'),
        client = client ?? http.Client();

  static String keyFor(String artist, String album) =>
      sha1.convert(utf8.encode('${artist.toLowerCase().trim()}|${album.toLowerCase().trim()}')).toString().substring(0, 16);

  static bool hasAlbum(Track t) => t.album != unknownAlbum && t.album.trim().isNotEmpty && t.artist != unknownArtist && t.artist.trim().isNotEmpty;

  /// Capa baixada para o álbum desta música (ou null).
  File? fileFor(Track t) {
    if (!hasAlbum(t)) return null;
    final f = File(p.join(dir, '${keyFor(t.artist, t.album)}.jpg'));
    return f.existsSync() ? f : null;
  }

  /// Busca as capas que faltam (uma vez por álbum). [tried] guarda os álbuns já tentados.
  Future<int> fetchMissing(List<Track> tracks, Set<String> tried, {MusicBrainzClient? mb, void Function()? onEach}) async {
    final albums = <String, Track>{};
    for (final t in tracks) {
      if (hasAlbum(t)) albums.putIfAbsent(keyFor(t.artist, t.album), () => t);
    }
    final client0 = mb ?? MusicBrainzClient();
    var n = 0;
    for (final e in albums.entries) {
      if (tried.contains(e.key) || fileFor(e.value) != null) continue;
      // já tem capa dentro do arquivo ou na pasta: não precisa baixar
      if (await metadata.cover(e.value.path) != null) {
        tried.add(e.key);
        continue;
      }
      String? id;
      try {
        id = await client0.releaseGroupId(e.value.artist, e.value.album);
      } catch (_) {
        break; // sem internet: tenta na próxima leitura
      }
      tried.add(e.key);
      if (id == null) continue;
      try {
        final res = await client
            .get(Uri.https('coverartarchive.org', '/release-group/$id/front-500'), headers: {'User-Agent': MusicBrainzClient.userAgent})
            .timeout(const Duration(seconds: 30));
        if (res.statusCode != 200 || res.bodyBytes.length < 1024) continue;
        await Directory(dir).create(recursive: true);
        await File(p.join(dir, '${e.key}.jpg')).writeAsBytes(res.bodyBytes, flush: true);
        n++;
        onEach?.call();
      } catch (_) {}
    }
    return n;
  }
}
