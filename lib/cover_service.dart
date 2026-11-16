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

  /// Nome do arquivo da capa: por álbum; sem álbum, pela própria música.
  static String fileKey(Track t) => hasAlbum(t) ? keyFor(t.artist, t.album) : 'f_${sha1.convert(utf8.encode(t.path)).toString().substring(0, 16)}';

  /// Capa guardada para esta música (do álbum ou tirada do próprio arquivo), ou null.
  File? fileFor(Track t) {
    final f = File(p.join(dir, '${fileKey(t)}.jpg'));
    return f.existsSync() ? f : null;
  }

  /// Busca as capas que faltam (uma vez por álbum). [tried] guarda os álbuns já resolvidos.
  /// Ordem: Cover Art Archive (capa oficial do álbum) > capa gravada no arquivo/pasta (ex.: miniatura do YouTube).
  Future<int> fetchMissing(List<Track> tracks, Set<String> tried, {MusicBrainzClient? mb, void Function()? onEach}) async {
    final items = <String, Track>{};
    for (final t in tracks) {
      items.putIfAbsent(fileKey(t), () => t);
    }
    final client0 = mb ?? MusicBrainzClient();
    var online = true;
    var n = 0;
    for (final e in items.entries) {
      if (tried.contains(e.key) || fileFor(e.value) != null) continue;
      final t = e.value;
      if (online && hasAlbum(t)) {
        try {
          final id = await client0.releaseGroupId(t.artist, t.album);
          if (id != null && await _download(id, e.key)) {
            tried.add(e.key);
            n++;
            onEach?.call();
            continue;
          }
        } catch (_) {
          online = false; // sem internet / MusicBrainz ocupado: usa só as capas dos arquivos e tenta de novo depois
        }
      }
      // capa dentro do arquivo ou na pasta (cover.jpg)
      final embedded = await metadata.cover(t.path);
      if (embedded != null && embedded.length > 1024) {
        await Directory(dir).create(recursive: true);
        await File(p.join(dir, '${e.key}.jpg')).writeAsBytes(embedded, flush: true);
        tried.add(e.key);
        n++;
        onEach?.call();
        continue;
      }
      if (online || !hasAlbum(t)) tried.add(e.key);
    }
    return n;
  }

  Future<bool> _download(String releaseGroupId, String key) async {
    try {
      final res = await client
          .get(Uri.https('coverartarchive.org', '/release-group/$releaseGroupId/front-500'), headers: {'User-Agent': MusicBrainzClient.userAgent})
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 || res.bodyBytes.length < 1024) return false;
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, '$key.jpg')).writeAsBytes(res.bodyBytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
