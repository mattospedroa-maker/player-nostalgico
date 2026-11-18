class Track {
  final int? id;
  final String path;
  final String title;
  final String artist;
  final String album;
  final String genre;
  final int? year;
  final int durationMs;
  final bool favorite;
  final int addedAt;
  final int modifiedAt;

  /// Clima escolhido no selo do GIF ('' = automático). Fica fora do toMap: a releitura não apaga.
  final String mood;

  /// Andamento (batidas por minuto) da tag TBPM ou do Last.fm. Null = desconhecido.
  /// Também fica fora do toMap: a releitura só grava quando o arquivo traz um valor.
  final int? bpm;

  const Track({
    this.id,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.genre = '',
    this.year,
    this.durationMs = 0,
    this.favorite = false,
    required this.addedAt,
    required this.modifiedAt,
    this.mood = '',
    this.bpm,
  });

  Track copyWith({int? id, String? path, bool? favorite, String? artist, String? album}) => Track(
        id: id ?? this.id,
        path: path ?? this.path,
        title: title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        genre: genre,
        year: year,
        durationMs: durationMs,
        favorite: favorite ?? this.favorite,
        addedAt: addedAt,
        modifiedAt: modifiedAt,
        mood: mood,
        bpm: bpm,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
        'year': year,
        'duration_ms': durationMs,
        'favorite': favorite ? 1 : 0,
        'added_at': addedAt,
        'modified_at': modifiedAt,
      };

  static Track fromMap(Map<String, Object?> m) => Track(
        id: m['id'] as int?,
        path: m['path'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String,
        album: m['album'] as String,
        genre: (m['genre'] as String?) ?? '',
        year: m['year'] as int?,
        durationMs: (m['duration_ms'] as int?) ?? 0,
        favorite: (m['favorite'] as int? ?? 0) == 1,
        addedAt: m['added_at'] as int,
        modifiedAt: m['modified_at'] as int,
        mood: (m['mood'] as String?) ?? '',
        bpm: m['bpm'] as int?,
      );
}

class Playlist {
  final int id;
  final String name;
  final int trackCount;
  const Playlist({required this.id, required this.name, this.trackCount = 0});
}

class Play {
  final int trackId;
  final int playedAt;
  final int secondsListened;
  final bool skipped;
  const Play({required this.trackId, required this.playedAt, required this.secondsListened, required this.skipped});
}

const unknownArtist = 'Artista desconhecido';
const unknownAlbum = 'Álbum desconhecido';
