import 'models.dart';

class Recommendation {
  final Track track;
  final double score;
  final String reason;
  const Recommendation(this.track, this.score, this.reason);
}

/// Recomendação 100% offline, por pontuação simples a partir do histórico.
class Recommender {
  final List<Track> tracks;
  final List<Play> plays;
  final DateTime now;

  Recommender(this.tracks, this.plays, {DateTime? now}) : now = now ?? DateTime.now();

  Map<int, Track> get _byId => {for (final t in tracks) if (t.id != null) t.id!: t};

  /// "Mix do momento": parecido com o que você ouviu nos últimos 30 dias.
  List<Recommendation> mix({int limit = 25}) {
    final byId = _byId;
    final since = now.subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    final hourAgo = now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    final artistW = <String, double>{};
    final genreW = <String, double>{};
    final hourW = <int, double>{};
    final skips = <int, int>{};
    final recent = <int>{};
    for (final pl in plays) {
      final t = byId[pl.trackId];
      if (t == null) continue;
      if (pl.skipped && pl.secondsListened < 30) skips[pl.trackId] = (skips[pl.trackId] ?? 0) + 1;
      if (pl.playedAt >= hourAgo) recent.add(pl.trackId);
      if (pl.playedAt < since || pl.skipped) continue;
      artistW[t.artist] = (artistW[t.artist] ?? 0) + 1;
      if (t.genre.isNotEmpty) genreW[t.genre] = (genreW[t.genre] ?? 0) + 1;
      final h = DateTime.fromMillisecondsSinceEpoch(pl.playedAt).hour;
      hourW[pl.trackId] = (hourW[pl.trackId] ?? 0) + ((h - now.hour).abs() <= 2 ? 1 : 0);
    }
    for (final t in tracks.where((t) => t.favorite)) {
      artistW[t.artist] = (artistW[t.artist] ?? 0) + 2;
    }
    final maxA = artistW.values.fold<double>(1, (a, b) => a > b ? a : b);
    final maxG = genreW.values.fold<double>(1, (a, b) => a > b ? a : b);

    final out = <Recommendation>[];
    for (final t in tracks) {
      if (t.id == null || recent.contains(t.id)) continue;
      var s = 0.0;
      var reason = '';
      final a = (artistW[t.artist] ?? 0) / maxA;
      final g = t.genre.isEmpty ? 0.0 : (genreW[t.genre] ?? 0) / maxG;
      if (a > 0) {
        s += 3 * a;
        reason = 'porque você ouve ${t.artist}';
      }
      if (g > 0) {
        s += 1.5 * g;
        if (reason.isEmpty) reason = 'gênero ${t.genre}';
      }
      if (t.favorite) {
        s += 1.5;
        if (reason.isEmpty) reason = 'uma das suas favoritas';
      }
      final hw = hourW[t.id] ?? 0;
      if (hw > 0) {
        s += .5 * hw.clamp(0, 3);
        if (reason.isEmpty) reason = 'você ouve nesse horário';
      }
      s -= 1.5 * (skips[t.id] ?? 0);
      if (s > 0) out.add(Recommendation(t, s, reason));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return out.take(limit).toList();
  }

  /// "Rádio": faixas parecidas com uma música.
  List<Recommendation> radio(Track seed, {int limit = 25}) {
    final next = <int, int>{};
    for (var i = 0; i + 1 < plays.length; i++) {
      if (plays[i].trackId == seed.id) next[plays[i + 1].trackId] = (next[plays[i + 1].trackId] ?? 0) + 1;
    }
    final out = <Recommendation>[];
    for (final t in tracks) {
      if (t.id == null || t.id == seed.id) continue;
      var s = 0.0;
      var reason = '';
      if (t.artist == seed.artist) {
        s += 3;
        reason = 'mesmo artista';
      }
      if (t.genre.isNotEmpty && t.genre == seed.genre) {
        s += 2;
        if (reason.isEmpty) reason = 'mesmo gênero';
      }
      if (t.album == seed.album && t.artist == seed.artist) s += 1;
      final n = next[t.id] ?? 0;
      if (n > 0) {
        s += 2.0 * n.clamp(0, 3);
        if (reason.isEmpty) reason = 'você costuma ouvir em seguida';
      }
      if (t.favorite) s += .5;
      if (s > 0) out.add(Recommendation(t, s, reason));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return out.take(limit).toList();
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
    return out.take(limit).toList();
  }
}
