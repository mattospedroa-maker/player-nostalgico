import 'models.dart';
import 'mood.dart';

class Recommendation {
  final Track track;
  final double score;
  final String reason;
  const Recommendation(this.track, this.score, this.reason);
}

/// Recomendação 100% offline, por pontuação ponderada a partir do histórico, das favoritas
/// e da parecença entre músicas (artista, álbum, gênero, clima, época).
/// Funciona com o que tiver: música sem gênero/álbum só deixa de somar esses pontos.
class Recommender {
  final List<Track> tracks;
  final List<Play> plays;
  final DateTime now;

  Recommender(this.tracks, this.plays, {DateTime? now}) : now = now ?? DateTime.now();

  Map<int, Track> get _byId => {for (final t in tracks) if (t.id != null) t.id!: t};

  // ---------- parecença entre duas músicas ----------

  static String _mainGenreWord(String genre) {
    final known = _mainWords[genre];
    if (known != null) return known;
    if (_mainWords.length > 4000) _mainWords.clear();
    return _mainWords[genre] = genre.toLowerCase().split(_genreSplit).where((w) => w.length > 1).lastOrNull ?? '';
  }

  // poucos gêneros diferentes na biblioteca: guarda a palavra principal de cada um
  static final Map<String, String> _mainWords = {};
  static final _genreSplit = RegExp(r'[\s/,;-]+');

  static bool _known(String v, String unknown) => v.trim().isNotEmpty && v != unknown;

  /// Afinidade entre duas músicas (0 = nada em comum). Pesos: artista 3, gênero 2 (ou 1 se só a família
  /// bate, ex.: "Nu Metal" e "Industrial Metal"), clima 2 (escolhido pelo usuário) ou 1 (pelo gênero),
  /// álbum 1,5, época (até 3 anos) 0,5.
  static double affinity(Track a, Track b) {
    var s = 0.0;
    final sameArtist = _known(a.artist, unknownArtist) && a.artist == b.artist;
    if (sameArtist) s += 3;
    if (sameArtist && _known(a.album, unknownAlbum) && a.album == b.album) s += 1.5;
    final ga = a.genre.toLowerCase(), gb = b.genre.toLowerCase();
    if (ga.isNotEmpty && ga == gb) {
      s += 2;
    } else if (ga.isNotEmpty && gb.isNotEmpty) {
      final w = _mainGenreWord(ga);
      if (w.isNotEmpty && w == _mainGenreWord(gb)) s += 1;
    }
    final ma = a.effectiveMood, mb = b.effectiveMood;
    if (ma != null && ma == mb) s += (a.chosenMood != null && b.chosenMood != null) ? 2 : 1;
    final ya = a.year ?? 0, yb = b.year ?? 0;
    if (ya > 0 && yb > 0 && (ya - yb).abs() <= 3) s += .5;
    return s;
  }

  /// Limita quantas músicas do mesmo artista/álbum entram, para a lista não ficar repetitiva.
  /// As que passam do limite vão para o fim (só entram se faltar música).
  static List<Recommendation> diversify(List<Recommendation> ranked, {int perArtist = 3, int perAlbum = 2, int? limit}) {
    final out = <Recommendation>[], later = <Recommendation>[];
    final byArtist = <String, int>{}, byAlbum = <String, int>{};
    for (final r in ranked) {
      final t = r.track;
      final a = _known(t.artist, unknownArtist) ? t.artist : null;
      final al = a != null && _known(t.album, unknownAlbum) ? '$a\u0000${t.album}' : null;
      if ((a != null && (byArtist[a] ?? 0) >= perArtist) || (al != null && (byAlbum[al] ?? 0) >= perAlbum)) {
        later.add(r);
        continue;
      }
      if (a != null) byArtist[a] = (byArtist[a] ?? 0) + 1;
      if (al != null) byAlbum[al] = (byAlbum[al] ?? 0) + 1;
      out.add(r);
      if (limit != null && out.length >= limit) return out;
    }
    out.addAll(later);
    return limit == null ? out : out.take(limit).toList();
  }

  // ---------- listas ----------

  /// "Mix do momento": parecido com o que você ouviu nos últimos 30 dias e com as favoritas,
  /// incluindo músicas que você ainda não tocou, sem concentrar num artista só.
  List<Recommendation> mix({int limit = 25}) {
    final byId = _byId;
    final since = now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    final hourAgo = now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    final dayAgo = now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final artistW = <String, double>{};
    final genreW = <String, double>{};
    final moodW = <Mood, double>{};
    final hourW = <int, double>{};
    final skips = <int, int>{};
    final recent = <int>{};
    final today = <int, int>{};
    final played = <int>{};
    final skipArtist = <String, double>{};
    final skipGenre = <String, double>{};
    for (final pl in plays) {
      final t = byId[pl.trackId];
      if (t == null) continue;
      played.add(pl.trackId);
      if (pl.skipped && pl.secondsListened < 30) {
        skips[pl.trackId] = (skips[pl.trackId] ?? 0) + 1;
        if (pl.playedAt >= since) {
          // pulou: músicas do mesmo tipo também perdem pontos
          skipArtist[t.artist] = (skipArtist[t.artist] ?? 0) + 1;
          if (t.genre.isNotEmpty) skipGenre[t.genre] = (skipGenre[t.genre] ?? 0) + 1;
        }
      }
      if (pl.playedAt >= hourAgo) recent.add(pl.trackId);
      if (pl.playedAt >= dayAgo && !pl.skipped) today[pl.trackId] = (today[pl.trackId] ?? 0) + 1;
      if (pl.playedAt < since || pl.skipped) continue;
      artistW[t.artist] = (artistW[t.artist] ?? 0) + 1;
      if (t.genre.isNotEmpty) genreW[t.genre] = (genreW[t.genre] ?? 0) + 1;
      final m = t.effectiveMood;
      if (m != null) moodW[m] = (moodW[m] ?? 0) + 1;
      final h = DateTime.fromMillisecondsSinceEpoch(pl.playedAt).hour;
      hourW[pl.trackId] = (hourW[pl.trackId] ?? 0) + ((h - now.hour).abs() <= 2 ? 1 : 0);
    }
    for (final t in tracks.where((t) => t.favorite)) {
      // curtiu: mais do mesmo artista, gênero e clima
      artistW[t.artist] = (artistW[t.artist] ?? 0) + 2;
      if (t.genre.isNotEmpty) genreW[t.genre] = (genreW[t.genre] ?? 0) + 2;
      final m = t.effectiveMood;
      if (m != null) moodW[m] = (moodW[m] ?? 0) + 1;
    }
    artistW.remove(unknownArtist);
    double maxOf(Iterable<double> v) => v.fold<double>(1, (a, b) => a > b ? a : b);
    final maxA = maxOf(artistW.values), maxG = maxOf(genreW.values), maxM = maxOf(moodW.values);

    final out = <Recommendation>[];
    for (final t in tracks) {
      if (t.id == null || recent.contains(t.id)) continue;
      var s = 0.0;
      var reason = '';
      final a = (artistW[t.artist] ?? 0) / maxA;
      final g = t.genre.isEmpty ? 0.0 : (genreW[t.genre] ?? 0) / maxG;
      final mood = t.effectiveMood;
      final m = mood == null ? 0.0 : (moodW[mood] ?? 0) / maxM;
      if (a > 0) {
        s += 3 * a;
        reason = 'porque você ouve ${t.artist}';
      }
      if (g > 0) {
        s += 1.5 * g;
        if (reason.isEmpty) reason = 'gênero ${t.genre}';
      }
      if (m > 0) {
        s += 1 * m;
        if (reason.isEmpty) reason = 'clima ${mood!.label.toLowerCase()}';
      }
      final taste = s;
      if (t.favorite) {
        s += 1.5;
        if (reason.isEmpty) reason = 'uma das suas favoritas';
      }
      final hw = hourW[t.id] ?? 0;
      if (hw > 0) {
        s += .5 * hw.clamp(0, 3);
        if (reason.isEmpty) reason = 'você ouve nesse horário';
      }
      // ainda não tocou, mas combina com o seu gosto: vale descobrir
      if (taste > 0 && !played.contains(t.id)) {
        s += .8;
        reason = '$reason · nunca tocou';
      }
      s -= .6 * (today[t.id] ?? 0).clamp(0, 3); // já tocou hoje: dá vez para outras
      s -= 1.5 * (skips[t.id] ?? 0);
      s -= .4 * (skipArtist[t.artist] ?? 0).clamp(0, 5) + .25 * (skipGenre[t.genre] ?? 0).clamp(0, 5);
      if (s > 0) out.add(Recommendation(t, s, reason));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return diversify(out, limit: limit);
  }

  /// "Rádio": faixas parecidas com uma música (afinidade + o que você costuma ouvir em seguida).
  List<Recommendation> radio(Track seed, {int limit = 25}) {
    final next = <int, int>{};
    final played = <int>{};
    final skips = <int, int>{};
    for (var i = 0; i < plays.length; i++) {
      played.add(plays[i].trackId);
      if (plays[i].skipped) skips[plays[i].trackId] = (skips[plays[i].trackId] ?? 0) + 1;
      if (i + 1 < plays.length && plays[i].trackId == seed.id) next[plays[i + 1].trackId] = (next[plays[i + 1].trackId] ?? 0) + 1;
    }
    final out = <Recommendation>[];
    for (final t in tracks) {
      if (t.id == null || t.id == seed.id) continue;
      var s = affinity(seed, t);
      var reason = _reasonFor(seed, t);
      final n = next[t.id] ?? 0;
      if (n > 0) {
        s += 2.0 * n.clamp(0, 3);
        if (reason.isEmpty) reason = 'você costuma ouvir em seguida';
      }
      if (s <= 0) continue;
      if (t.favorite) s += .5;
      if (!played.contains(t.id)) s += .3; // dá chance para as que nunca tocaram
      s -= .5 * (skips[t.id] ?? 0).clamp(0, 4);
      if (s > 0) out.add(Recommendation(t, s, reason));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return diversify(out, perArtist: 4, perAlbum: 3, limit: limit);
  }

  /// Músicas parecidas com [seed], só pela parecença (sem histórico). Usada nas coleções automáticas.
  static List<Recommendation> similar(Track seed, List<Track> tracks, {int limit = 25}) {
    final out = <Recommendation>[];
    for (final t in tracks) {
      if (t.id == seed.id || t.path == seed.path) continue;
      final s = affinity(seed, t);
      if (s > 0) out.add(Recommendation(t, s + (t.favorite ? .3 : 0), _reasonFor(seed, t)));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return diversify(out, perArtist: 4, perAlbum: 3, limit: limit);
  }

  static String _reasonFor(Track seed, Track t) {
    if (_known(t.artist, unknownArtist) && t.artist == seed.artist) return 'mesmo artista';
    if (t.genre.isNotEmpty && t.genre.toLowerCase() == seed.genre.toLowerCase()) return 'mesmo gênero';
    final m = t.effectiveMood;
    if (m != null && m == seed.effectiveMood) return 'mesmo clima (${m.label.toLowerCase()})';
    if (t.genre.isNotEmpty && seed.genre.isNotEmpty) return 'gênero parecido';
    return 'mesma época';
  }

  /// "Redescobrir": músicas que você ouvia muito e não toca há mais de 60 dias.
  List<Recommendation> rediscover({int limit = 15}) {
    final count = <int, int>{};
    final last = <int, int>{};
    for (final pl in plays.where((p) => !p.skipped)) {
      count[pl.trackId] = (count[pl.trackId] ?? 0) + 1;
      if ((last[pl.trackId] ?? 0) < pl.playedAt) last[pl.trackId] = pl.playedAt;
    }
    final cutoff = now.subtract(const Duration(days: 60)).millisecondsSinceEpoch;
    final out = <Recommendation>[];
    for (final t in tracks) {
      final l = last[t.id];
      final c = count[t.id] ?? 0;
      if (l == null || l > cutoff || (c < 3 && !t.favorite)) continue;
      final days = (now.millisecondsSinceEpoch - l) ~/ 86400000;
      final label = days >= 365 ? '${days ~/ 365} ano(s)' : '${days ~/ 30} meses';
      out.add(Recommendation(t, c + (t.favorite ? 5.0 : 0.0), t.favorite ? 'favorita esquecida · $label' : 'não toca há $label'));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return diversify(out, limit: limit);
  }
}
