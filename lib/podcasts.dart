import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'library_search.dart';
import 'models.dart';
import 'organizer.dart';

/// Podcasts são um tipo de mídia separado das músicas: ficam em `<pasta de músicas>`/Podcasts/Programa/
/// e nunca entram em "Músicas", "Tocar tudo", mix, recomendações ou playlists de clima.
/// O tipo vem só do lugar do arquivo (sem coluna nova no banco): mover para a pasta Podcasts = virar podcast.
const podcastsFolder = 'Podcasts';

/// Nome usado quando o programa (canal) é desconhecido.
const unknownProgram = 'Sem programa';

/// O arquivo está dentro de `<raiz>`/Podcasts/?
bool isPodcastPath(String? root, String path) {
  if (root == null || root.isEmpty || !p.isWithin(root, path)) return false;
  final parts = p.split(p.relative(path, from: root));
  return parts.length > 1 && parts.first.toLowerCase() == podcastsFolder.toLowerCase();
}

/// Programa do episódio pela pasta: Podcasts/`<Programa>`/arquivo. Null se o arquivo está solto em Podcasts/.
String? programFromPath(String root, String path) {
  final parts = p.split(p.relative(path, from: root));
  return parts.length >= 3 ? parts[1] : null;
}

/// Onde um episódio baixado (ou movido) fica: Podcasts/`<Programa>`/`<nome>`.ext
String podcastTargetPath(String root, String program, String fileName) =>
    p.join(root, podcastsFolder, safeFolderName(program.trim().isEmpty ? unknownProgram : program), fileName);

/// Tipos de mídia do seletor da Biblioteca. Audiolivros fica "em espera" (aparece cinza, ainda não existe).
enum MediaKind { music, podcasts, audiobooks }

extension MediaKindInfo on MediaKind {
  String get label => switch (this) { MediaKind.music => 'Música', MediaKind.podcasts => 'Podcasts', MediaKind.audiobooks => 'Audiolivros' };
  bool get available => this != MediaKind.audiobooks;
}

// ---------------------------------------------------------------------------
// Detecção

/// Pistas no título de que é um podcast/conversa (não música).
final _podcastWords = RegExp(
  r'podcast|\bep\.?\s*\d+|\bepis[oó]dio\b|\bepisode\b|(^|\s)#\s?\d{2,}|\bentrevista\b|\binterview\b|'
  r'\bbate[- ]?papo\b|\bconversa com\b|\btalk ?show\b',
  caseSensitive: false,
);

/// O texto tem cara de podcast?
bool hasPodcastWords(String text) => _podcastWords.hasMatch(text);

/// Duração mínima para algo ser tratado como possível podcast.
const podcastMinDuration = Duration(minutes: 20);

/// Sem pista no título, só a duração: a partir disto aparece na revisão (desmarcado).
const podcastLongDuration = Duration(minutes: 60);

/// Vídeo do YouTube parece podcast? (link de podcast do YouTube Music, ou longo com pistas no título/canal/playlist)
bool looksLikePodcastVideo(Map<String, dynamic> info, {String? playlistTitle, String? url}) {
  String s(String k) => (info[k] ?? '').toString();
  final link = '${url ?? ''} ${s('webpage_url')} ${s('url')}';
  if (link.contains('music.youtube.com/podcast') || link.contains('/podcast/')) return true;
  final secs = (info['duration'] as num?)?.toDouble() ?? 0;
  final text = '${s('title')} ${s('channel')} ${s('uploader')} ${playlistTitle ?? ''}';
  final cats = info['categories'];
  final catText = cats is List ? cats.join(' ') : '';
  if (catText.toLowerCase().contains('podcast')) return true;
  return secs >= podcastMinDuration.inSeconds && hasPodcastWords(text);
}

/// Uma música da biblioteca que parece podcast (para a sugestão de mover).
class PodcastCandidate {
  final Track track;

  /// Pista forte (palavras no título/arquivo): já vem marcada na revisão.
  final bool strong;

  /// Por que o app acha que é podcast (mostrado na revisão).
  final String reason;

  /// Programa sugerido (artista/canal das tags).
  final String program;

  const PodcastCandidate(this.track, {required this.strong, required this.reason, required this.program});
}

/// Músicas que parecem podcasts. [dismissed]: caminhos que você já disse que não são.
List<PodcastCandidate> findPodcastCandidates(Iterable<Track> music, {Set<String> dismissed = const {}}) {
  final out = <PodcastCandidate>[];
  for (final t in music) {
    if (dismissed.contains(t.path)) continue;
    final d = Duration(milliseconds: t.durationMs);
    if (d < podcastMinDuration) continue;
    final text = '${t.title} ${p.basenameWithoutExtension(t.path)} ${t.album}';
    final words = _podcastWords.firstMatch(text);
    final dur = formatDuration(d);
    final program = t.artist == unknownArtist || t.artist.trim().isEmpty ? unknownProgram : t.artist;
    if (words != null) {
      out.add(PodcastCandidate(t, strong: true, reason: '$dur · título tem "${words.group(0)!.trim()}"', program: program));
    } else if (d >= podcastLongDuration) {
      out.add(PodcastCandidate(t, strong: false, reason: '$dur · só a duração bateu (pode ser música)', program: program));
    }
  }
  out.sort((a, b) => a.strong == b.strong ? a.track.title.compareTo(b.track.title) : (a.strong ? -1 : 1));
  return out;
}

/// "2h31", "47 min".
String formatDuration(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final m = d.inMinutes % 60;
  return '${d.inHours}h${m.toString().padLeft(2, '0')}';
}

/// "1:02:10" / "12:05".
String formatClock(Duration d) {
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (d.inHours > 0) return '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s';
  return '${d.inMinutes}:$s';
}

// ---------------------------------------------------------------------------
// Programas

/// Um programa (normalmente o canal do YouTube) e seus episódios, do mais novo para o mais antigo.
class PodcastProgram {
  final String name;
  final List<Track> episodes;
  const PodcastProgram(this.name, this.episodes);
}

/// Agrupa os episódios por programa (artista do episódio = programa).
List<PodcastProgram> groupPrograms(List<Track> episodes) {
  final by = <String, List<Track>>{};
  for (final e in episodes) {
    by.putIfAbsent(e.artist, () => []).add(e);
  }
  final out = [
    for (final e in by.entries) PodcastProgram(e.key, e.value..sort((a, b) => b.addedAt.compareTo(a.addedAt))),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// Busca simples por título ou programa (sem acento, sem maiúscula). [extra]: texto a mais por episódio
/// (participantes e temas do resumo), para achar "Fulano" mesmo sem o nome no título.
List<Track> searchEpisodes(List<Track> episodes, String query, {String Function(Track)? extra}) {
  final q = normalizeText(query);
  if (q.isEmpty) return episodes;
  final words = q.split(' ');
  return [
    for (final e in episodes)
      if (words.every(normalizeText('${e.title} ${e.artist} ${p.basenameWithoutExtension(e.path)} ${extra?.call(e) ?? ''}').contains)) e,
  ];
}

// ---------------------------------------------------------------------------
// Onde parou / ouvido

/// Lembra onde cada episódio parou e quais já foram ouvidos até o fim (guardado nas preferências).
class PodcastProgress {
  final SharedPreferences prefs;
  PodcastProgress(this.prefs) {
    try {
      final raw = prefs.getString(_posKey);
      if (raw != null) _pos.addAll((jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', (v as num).toInt())));
    } catch (_) {
      // preferência corrompida: começa do zero (só perde onde parou)
    }
    _done.addAll(prefs.getStringList(_doneKey) ?? const []);
  }

  static const _posKey = 'podcastPositions';
  static const _doneKey = 'podcastListened';

  /// Menos que isto do começo não conta como "parou no meio".
  static const minResume = Duration(seconds: 30);

  /// Faltando menos que isto para o fim, conta como ouvido.
  static const endSlack = Duration(seconds: 45);

  final Map<String, int> _pos = {};
  final Set<String> _done = {};

  /// Onde continuar (null = do começo).
  Duration? resumeAt(String path) {
    final ms = _pos[path];
    return ms == null ? null : Duration(milliseconds: ms);
  }

  bool listened(String path) => _done.contains(path);

  /// Guarda a posição. Perto do fim = ouvido (e a próxima vez começa do zero).
  void save(String path, Duration position, Duration? total) {
    if (total != null && total > Duration.zero && total - position <= endSlack) {
      _pos.remove(path);
      _done.add(path);
      _flush();
      return;
    }
    if (position < minResume) {
      if (_pos.remove(path) != null) _flush();
      return;
    }
    _pos.remove(path); // o último salvo fica no fim (para "Continuar de onde parei")
    _pos[path] = position.inMilliseconds;
    _flush();
  }

  void setListened(String path, bool v) {
    if (v) {
      _done.add(path);
      _pos.remove(path);
    } else {
      _done.remove(path);
    }
    _flush();
  }

  /// O arquivo mudou de lugar: leva junto onde parou.
  void moved(String from, String to) {
    final ms = _pos.remove(from);
    if (ms != null) _pos[to] = ms;
    if (_done.remove(from)) _done.add(to);
    _flush();
  }

  /// Episódio parado no meio mais recente entre [episodes] (para "Continuar de onde parei").
  Track? lastInProgress(List<Track> episodes) {
    for (final path in _order.reversed) {
      for (final e in episodes) {
        if (e.path == path && _pos.containsKey(path)) return e;
      }
    }
    return null;
  }

  // ordem em que as posições foram salvas (o último salvo fica no fim)
  List<String> get _order => _pos.keys.toList();

  void _flush() {
    prefs.setString(_posKey, jsonEncode(_pos));
    prefs.setStringList(_doneKey, _done.toList());
  }
}
