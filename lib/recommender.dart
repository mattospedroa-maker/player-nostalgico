import 'artist_names.dart';
import 'lastfm.dart' show MusicTag;
import 'models.dart';
import 'mood.dart';

class Recommendation {
  final Track track;
  final double score;
  final String reason;
  const Recommendation(this.track, this.score, this.reason);
}

/// Sugestão para o fim de uma playlist: além da pontuação, diz o que combinou (as etiquetas da tela).
class PlaylistSuggestion extends Recommendation {
  /// Gênero da música quando ele bate com a playlist (igual ou da mesma família), senão null.
  final String? genre;

  /// Clima da música quando ele bate com a playlist, senão null.
  final Mood? mood;
  const PlaylistSuggestion(Track track, double score, this.genre, this.mood)
      : super(track, score, '');
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
    final sameArtist = _known(a.artist, unknownArtist) && ArtistNames.current.shares(a.artist, b.artist);
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
      final a = _known(t.artist, unknownArtist) ? ArtistNames.current.key(t.artist) : null;
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
          skipArtist[ArtistNames.current.key(t.artist)] = (skipArtist[ArtistNames.current.key(t.artist)] ?? 0) + 1;
          if (t.genre.isNotEmpty) skipGenre[t.genre] = (skipGenre[t.genre] ?? 0) + 1;
        }
      }
      if (pl.playedAt >= hourAgo) recent.add(pl.trackId);
      if (pl.playedAt >= dayAgo && !pl.skipped) today[pl.trackId] = (today[pl.trackId] ?? 0) + 1;
      if (pl.playedAt < since || pl.skipped) continue;
      artistW[ArtistNames.current.key(t.artist)] = (artistW[ArtistNames.current.key(t.artist)] ?? 0) + 1;
      if (t.genre.isNotEmpty) genreW[t.genre] = (genreW[t.genre] ?? 0) + 1;
      final m = t.effectiveMood;
      if (m != null) moodW[m] = (moodW[m] ?? 0) + 1;
      final h = DateTime.fromMillisecondsSinceEpoch(pl.playedAt).hour;
      hourW[pl.trackId] = (hourW[pl.trackId] ?? 0) + ((h - now.hour).abs() <= 2 ? 1 : 0);
    }
    for (final t in tracks.where((t) => t.favorite)) {
      // curtiu: mais do mesmo artista, gênero e clima
      artistW[ArtistNames.current.key(t.artist)] = (artistW[ArtistNames.current.key(t.artist)] ?? 0) + 2;
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
      final a = (artistW[ArtistNames.current.key(t.artist)] ?? 0) / maxA;
      final g = t.genre.isEmpty ? 0.0 : (genreW[t.genre] ?? 0) / maxG;
      final mood = t.effectiveMood;
      final m = mood == null ? 0.0 : (moodW[mood] ?? 0) / maxM;
      if (a > 0) {
        s += 3 * a;
        reason = 'porque você ouve ${ArtistNames.current.main(t.artist)}';
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
      s -= .4 * (skipArtist[ArtistNames.current.key(t.artist)] ?? 0).clamp(0, 5) + .25 * (skipGenre[t.genre] ?? 0).clamp(0, 5);
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
    if (_known(t.artist, unknownArtist) && ArtistNames.current.shares(t.artist, seed.artist)) return 'mesmo artista';
    if (t.genre.isNotEmpty && t.genre.toLowerCase() == seed.genre.toLowerCase()) return 'mesmo gênero';
    final m = t.effectiveMood;
    if (m != null && m == seed.effectiveMood) return 'mesmo clima (${m.label.toLowerCase()})';
    if (t.genre.isNotEmpty && seed.genre.isNotEmpty) return 'gênero parecido';
    return 'mesma época';
  }

  // ---------- sugestões para uma playlist ----------

  /// Climas que brigam entre si: numa playlist triste, música de festa ou de soco perde pontos.
  static const _clash = {
    Mood.triste: {Mood.festa, Mood.acao},
    Mood.calmo: {Mood.festa, Mood.acao},
    Mood.romantico: {Mood.acao},
    Mood.festa: {Mood.triste, Mood.calmo},
    Mood.acao: {Mood.triste, Mood.calmo, Mood.romantico},
    Mood.epico: <Mood>{},
  };

  static String _plain(String s) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüç', to = 'aaaaaeeeeiiiiooooouuuuc';
    final b = StringBuffer();
    for (final c in s.toLowerCase().trim().split('')) {
      final i = from.indexOf(c);
      b.write(i < 0 ? c : to[i]);
    }
    return b.toString();
  }

  /// Tags que não dizem nada do som (gosto pessoal, ocasião), ignoradas na comparação.
  static final _noiseTag = RegExp(r'^(seen live|favou?rites?|favou?rite songs?|my favou?rite|love|loved|awesome|beautiful|amazing|best|'
      r'good|great|cool|epic|masterpiece|albums i own|under \d+ listeners|spotify|youtube|music|songs?|all|check out|wishlist)$');

  /// Tags largas demais (quase toda música tem): contam menos que as de estilo (shoegaze, post punk...).
  static const _broadTags = {
    'rock', 'pop', 'indie', 'alternative', 'electronic', 'metal', 'hip hop', 'rap', 'dance', 'instrumental', 'soundtrack',
    'female vocalists', 'male vocalists', 'singer songwriter', '60s', '70s', '80s', '90s', '00s', '2000s', '2010s', '2020s',
    'american', 'british', 'usa', 'uk',
  };

  static String _normTag(String t) => t.toLowerCase().replaceAll(RegExp(r'[-_]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Até 10 tags mais fortes do Last.fm guardadas para a música (sem as de gosto pessoal e sem o nome do artista).
  /// Sem tags guardadas, usa o gênero como única "tag".
  static Set<String> _soundTags(Track t, List<MusicTag>? Function(Track) tagsOf) {
    final tags = tagsOf(t);
    final artist = _normTag(t.artist);
    final out = <String>{};
    if (tags != null && tags.isNotEmpty) {
      final sorted = [...tags]..sort((a, b) => b.count.compareTo(a.count));
      for (final tag in sorted) {
        final n = _normTag(tag.name);
        if (n.length < 2 || n == artist || _noiseTag.hasMatch(n)) continue;
        out.add(n);
        if (out.length >= 10) break;
      }
    }
    if (out.isEmpty && t.genre.trim().isNotEmpty) out.add(_normTag(t.genre));
    return out;
  }

  static String _tagLabel(String tag) => tag.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

  /// Playlist com o nome de um clima ("Triste", "Calmo"...): o clima vira a regra principal.
  static Mood? moodOfPlaylistName(String name) {
    final n = _plain(name);
    for (final m in Mood.values) {
      if (n == _plain(m.label)) return m;
    }
    return null;
  }

  /// Músicas da biblioteca que combinam com a playlist (por gênero e clima), da mais para a menos parecida.
  ///
  /// Faz o "retrato" da playlist (quanto ela tem de cada gênero, família de gênero e clima) e dá pontos
  /// a cada música que ainda não está nela. Gênero igual vale mais que a mesma família; tags do Last.fm em
  /// comum (shoegaze, dream pop, post punk...) somam pelo tanto de músicas da playlist que as têm; clima igual soma
  /// (escolhido à mão vale o dobro); clima que briga tira. Artista que ainda não está na playlist ganha um
  /// pouco a mais; no máximo 2 por artista. Música pulada muitas vezes cai.
  /// Conta só em memória, sem internet: uma passada pela biblioteca.
  static List<PlaylistSuggestion> forPlaylist(List<Track> playlist, List<Track> library,
      {String playlistName = '', List<Play> plays = const [], int limit = 60, List<MusicTag>? Function(Track)? tagsOf}) {
    final tagsFor = tagsOf ?? MoodClues.tagsOf;
    if (playlist.isEmpty) return const [];
    final inside = {for (final t in playlist) t.path};
    final insideIds = {for (final t in playlist) if (t.id != null) t.id!};
    final genreW = <String, double>{}, familyW = <String, double>{}, moodW = <Mood, double>{};
    // tags do Last.fm (shoegaze, dream pop, post punk, ethereal...): acham parentes que o gênero sozinho não acha
    final tagW = <String, double>{};
    final artists = <String>{};
    var moodTotal = 0.0;
    for (final t in playlist) {
      final g = t.genre.trim().toLowerCase();
      if (g.isNotEmpty) {
        genreW[g] = (genreW[g] ?? 0) + 1;
        final f = _mainGenreWord(g);
        if (f.isNotEmpty) familyW[f] = (familyW[f] ?? 0) + 1;
      }
      final m = t.effectiveMood;
      if (m != null) {
        final w = t.chosenMood != null ? 2.0 : 1.0; // escolhido à mão: vale o dobro
        moodW[m] = (moodW[m] ?? 0) + w;
        moodTotal += w;
      }
      if (_known(t.artist, unknownArtist)) artists.add(ArtistNames.current.key(t.artist));
      for (final tag in _soundTags(t, tagsFor)) {
        tagW[tag] = (tagW[tag] ?? 0) + (_broadTags.contains(tag) ? .35 : 1);
      }
    }
    final n = playlist.length.toDouble();
    tagW.updateAll((_, v) => v / n);
    genreW.updateAll((_, v) => v / n);
    familyW.updateAll((_, v) => v / n);
    // clima: a fração entre as músicas que têm clima, descontada se a maioria da playlist é neutra
    final moodCover = playlist.where((t) => t.effectiveMood != null).length / n;
    if (moodTotal > 0) moodW.updateAll((_, v) => v / moodTotal * (.4 + .6 * moodCover));
    final rule = moodOfPlaylistName(playlistName);

    final skips = <int, int>{};
    for (final p in plays) {
      if (p.skipped && p.secondsListened < 30) skips[p.trackId] = (skips[p.trackId] ?? 0) + 1;
    }

    final out = <PlaylistSuggestion>[];
    for (final t in library) {
      if (inside.contains(t.path) || (t.id != null && insideIds.contains(t.id))) continue;
      var s = 0.0;
      String? genre;
      Mood? mood;
      final g = t.genre.trim().toLowerCase();
      if (g.isNotEmpty) {
        final exact = 3 * (genreW[g] ?? 0);
        final f = _mainGenreWord(g);
        final family = f.isEmpty ? 0.0 : 1.5 * (familyW[f] ?? 0);
        final best = exact > family ? exact : family;
        if (best > 0) {
          s += best;
          genre = t.genre.trim();
        }
      }
      // tags em comum, pesadas por quantas músicas da playlist têm cada uma
      var tagScore = 0.0;
      String? bestTag;
      var bestTagW = 0.0;
      for (final tag in _soundTags(t, tagsFor)) {
        final w = tagW[tag];
        if (w == null) continue;
        tagScore += w;
        if (w > bestTagW && !_broadTags.contains(tag)) (bestTag, bestTagW) = (tag, w);
      }
      if (tagScore > 0) {
        s += 2 * (tagScore > 2.5 ? 2.5 : tagScore);
        genre ??= bestTag == null ? null : _tagLabel(bestTag);
      }
      final m = t.effectiveMood;
      if (m != null) {
        final match = moodW[m] ?? 0;
        if (match > 0) {
          s += 2.5 * match * (t.chosenMood != null ? 1.5 : 1);
          mood = m;
        }
        var clash = 0.0;
        for (final e in moodW.entries) {
          if (_clash[e.key]!.contains(m)) clash += e.value;
        }
        s -= 2.5 * clash;
        if (rule != null) {
          if (m == rule) {
            s += 4;
            mood = m;
          } else {
            s -= 2;
          }
        }
      }
      if (genre == null && mood == null) continue; // nada em comum: não é sugestão
      final key = _known(t.artist, unknownArtist) ? ArtistNames.current.key(t.artist) : null;
      if (key != null && !artists.contains(key)) s += .3; // artista que ainda não está na playlist: vale descobrir
      if (t.favorite) s += .3;
      s -= .7 * (skips[t.id] ?? 0).clamp(0, 3);
      if (s >= 1) out.add(PlaylistSuggestion(t, s, genre, mood));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return diversify(out, perArtist: 2, perAlbum: 2, limit: limit).cast<PlaylistSuggestion>();
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
