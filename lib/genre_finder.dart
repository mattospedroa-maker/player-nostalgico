import 'genre.dart';
import 'lastfm.dart';
import 'models.dart';

/// Resultado da procura do gênero de um artista.
class GenreLookup {
  final String? genre;

  /// false = sem internet / serviço fora: não marcar como tentado, tenta na próxima leitura.
  final bool reached;
  const GenreLookup(this.genre, {this.reached = true});
}

/// Descobre o gênero real de um artista: MusicBrainz (gênero curado, ex.: "Industrial Metal"),
/// depois as tags do Last.fm já guardadas das músicas dele (sem internet), depois as tags do artista no Last.fm.
/// São as mesmas tags que o clima automático usa, então gênero e clima andam juntos.
class GenreFinder {
  /// Lança erro quando o MusicBrainz não responde.
  final Future<String?> Function(String artist) musicBrainz;
  final Future<TagResult> Function(String artist) lastFmArtist;
  final List<MusicTag>? Function(Track t) cachedTrackTags;

  GenreFinder({required this.musicBrainz, required this.lastFmArtist, required this.cachedTrackTags});

  Future<GenreLookup> find(String artist, List<Track> tracks) async {
    var reached = true;
    try {
      final g = await musicBrainz(artist);
      if (g != null && !isGenericGenre(g)) return GenreLookup(g);
    } catch (_) {
      reached = false;
    }
    final cached = <String, int>{};
    for (final t in tracks) {
      for (final tag in cachedTrackTags(t) ?? const <MusicTag>[]) {
        cached.update(tag.name.toLowerCase(), (c) => c + tag.count, ifAbsent: () => tag.count);
      }
    }
    final fromCache = genreFromTags([for (final e in cached.entries) MusicTag(e.key, e.value)]);
    if (fromCache != null) return GenreLookup(fromCache);
    final r = await lastFmArtist(artist);
    if (r.status == TagStatus.ok) {
      return GenreLookup(genreFromTags(r.tags), reached: true);
    }
    // sem chave do Last.fm ou não achou: vale o que o MusicBrainz disse
    if (r.status == TagStatus.network) return const GenreLookup(null, reached: false);
    return GenreLookup(null, reached: reached);
  }
}
