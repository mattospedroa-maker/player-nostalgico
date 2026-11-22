import 'package:path/path.dart' as p;

import 'filename_parser.dart';
import 'models.dart';
import 'organizer.dart';

/// Música que ficou sem artista ou sem álbum (o MusicBrainz não respondeu no download, sem internet...):
/// o app tenta de novo sozinho, com intervalos cada vez maiores, só quando ela toca ou ao abrir o app.
class InfoRetry {
  /// Espera entre as tentativas: 1 hora, 1 dia, 3 dias e depois 1 vez por semana.
  static const waits = [Duration(hours: 1), Duration(days: 1), Duration(days: 3), Duration(days: 7)];

  /// Já pode tentar de novo? [tries] = quantas vezes já tentou; [last] = quando.
  static bool due(int tries, DateTime? last, DateTime now) {
    if (tries <= 0 || last == null) return true;
    final wait = waits[(tries - 1).clamp(0, waits.length - 1)];
    return !now.isBefore(last.add(wait));
  }

  /// Falta artista ou álbum?
  static bool missing(Track t) => t.artist.trim().isEmpty || t.artist == unknownArtist || t.album.trim().isEmpty || t.album == unknownAlbum;

  /// Pistas de artista, da mais confiável à menos: o artista que a música já tem, a pasta
  /// Fonte/Artista/Álbum e o "Artista - Título" do nome do arquivo.
  static List<String> hints(Track t, {String? root}) {
    final out = <String>[];
    void add(String? s) {
      final v = s?.trim() ?? '';
      if (v.isEmpty || v == unknownArtist || out.any((o) => o.toLowerCase() == v.toLowerCase())) return;
      out.add(v);
    }

    add(t.artist);
    add(folderArtistHint(t.path, root: root));
    add(parseFileName(p.basenameWithoutExtension(t.path)).artist);
    return out;
  }

  /// O que gravar com a resposta do MusicBrainz ([found], ou null se não achou) e as [hints].
  /// Sem resposta boa, mas com a pasta dizendo o artista: usa a pasta (o álbum fica para a próxima).
  /// Null = nada a mudar.
  static ({String artist, String album, String title})? decide(Track t, SongInfo? found, List<String> hints) {
    // resposta só é aceita se bate com uma pista (até 60% = o MusicBrainz só achou outro artista)
    if (found != null && hints.isNotEmpty && found.score > 60 && !MusicBrainzClient.looksLikeCover(found)) {
      return (artist: found.artist, album: found.album, title: found.title.isEmpty ? t.title : found.title);
    }
    final noArtist = t.artist.trim().isEmpty || t.artist == unknownArtist;
    if (noArtist && hints.isNotEmpty) return (artist: hints.first, album: t.album, title: t.title);
    return null;
  }
}
