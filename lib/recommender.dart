import 'artist_names.dart';
import 'lastfm.dart' show MusicTag;
import 'models.dart';
import 'mood.dart';
import 'style_learning.dart';
import 'styles.dart';

class Recommendation {
  final Track track;
  final double score;
  final String reason;
  const Recommendation(this.track, this.score, this.reason);
}

/// Sugestão para o fim de uma playlist: além da pontuação, diz o que combinou (as etiquetas da tela).
class PlaylistSuggestion extends Recommendation {
  /// Estilo da música que mais combina com a playlist (igual ou vizinho), senão null.
  final String? genre;

  /// Clima da música quando ele bate com a playlist, senão null.
  final Mood? mood;
  const PlaylistSuggestion(Track track, double score, this.genre, this.mood, [String reason = ''])
      : super(track, score, reason);
}

/// Soma os pontos e guarda o termo que mais pesou: ele vira o motivo mostrado na tela.
class _Why {
  double score = 0;
  double _best = 0;
  String reason = '';

  /// Cada termo que somou, na ordem em que entrou (para a janela "Por que esta música?").
  final List<(String, double)> parts = [];
  void add(double v, String why) {
    score += v;
    if (v > 0) parts.add((why, v));
    if (v > _best) {
      _best = v;
      reason = why;
    }
  }
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

  /// Afinidade entre duas músicas (0 = nada em comum). Pesos: artista 3, estilos até 2,5 (iguais, vizinhos ou que
  /// você junta nas playlists; sem estilos, o gênero: 2, ou 1 se só a família bate), clima 2 (escolhido) ou 1,
  /// réguas perto até 1, álbum 1,5, época (até 3 anos) 0,5, juntas nas suas playlists até 2,4.
  static double affinity(Track a, Track b) => _affinity(a, b).score;

  /// Afinidade e o motivo de maior peso ("mesmo artista", "estilo Shoegaze", "tags em comum: dreamy"...).
  static (double, String) affinityWhy(Track a, Track b) {
    final w = _affinity(a, b);
    return (w.score, w.reason);
  }

  /// Tudo o que somou entre [a] e [b], do termo que mais pesou para o que menos pesou.
  static ({double score, String reason, List<(String, double)> parts}) explain(Track a, Track b) {
    final w = _affinity(a, b);
    return (score: w.score, reason: w.reason, parts: List.of(w.parts)..sort((x, y) => y.$2.compareTo(x.$2)));
  }

  static _Why _affinity(Track a, Track b) {
    final w = _Why();
    final sameArtist = _known(a.artist, unknownArtist) && ArtistNames.current.shares(a.artist, b.artist);
    if (sameArtist) w.add(3, 'mesmo artista');
    if (sameArtist && _known(a.album, unknownAlbum) && a.album == b.album) w.add(1.5, 'mesmo álbum');
    // estilos (com vizinhos e o que você junta nas playlists); sem estilos, o gênero como antes
    final sa = Styles.of(a), sb = Styles.of(b);
    if (sa.isNotEmpty && sb.isNotEmpty) {
      var best = 0.0;
      var label = sb.first;
      for (final y in sb) {
        for (final x in sa) {
          final v = Styles.similarity(x, y);
          if (v > best) (best, label) = (v, y);
        }
      }
      w.add(2.5 * Styles.listSimilarity(sa, sb), best >= 1 ? 'mesmo estilo ($label)' : 'estilo parecido ($label)');
    } else {
      final ga = a.genre.toLowerCase(), gb = b.genre.toLowerCase();
      if (ga.isNotEmpty && ga == gb) {
        w.add(2, 'mesmo gênero');
      } else if (ga.isNotEmpty && gb.isNotEmpty) {
        final g = _mainGenreWord(ga);
        if (g.isNotEmpty && g == _mainGenreWord(gb)) w.add(1, 'gênero parecido');
      }
    }
    // tags do Last.fm que não são estilo ("dreamy", "melancholic"): acham parentes mesmo sem gênero
    final ta = Styles.flavorTags(a);
    if (ta.isNotEmpty) {
      final shared = [for (final t in Styles.flavorTags(b)) if (ta.contains(t)) t];
      if (shared.isNotEmpty) w.add((.4 * shared.length).clamp(0, 1.2).toDouble(), 'tags em comum: ${shared.take(2).join(', ')}');
    }
    final ma = a.effectiveMood, mb = b.effectiveMood;
    if (ma != null && ma == mb) w.add((a.chosenMood != null && b.chosenMood != null) ? 2 : 1, 'mesmo clima (${ma.label.toLowerCase()})');
    // réguas perto (energia e humor)
    if (Styles.hasVibe(a) && Styles.hasVibe(b)) {
      final d = Styles.vibeOf(a).distanceTo(Styles.vibeOf(b));
      if (d < 40) w.add(1 - d / 40, 'energia e humor parecidos');
    }
    final ya = a.year ?? 0, yb = b.year ?? 0;
    if (ya > 0 && yb > 0 && (ya - yb).abs() <= 3) w.add(.5, 'mesma época');
    if (a.id != null && b.id != null) {
      final n = StyleLearning.current.together(a.id!, b.id!);
      if (n > 0) w.add(.8 * n.clamp(0, 3), 'juntas nas suas playlists');
    }
    return w;
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
    // músicas DIFERENTES puladas de cada artista/gênero (pular 5 vezes a mesma não condena o artista)
    final skipArtist = <String, Set<int>>{};
    final skipGenre = <String, Set<int>>{};
    for (final pl in plays) {
      final t = byId[pl.trackId];
      if (t == null) continue;
      played.add(pl.trackId);
      if (pl.skipped && pl.secondsListened < 30) {
        skips[pl.trackId] = (skips[pl.trackId] ?? 0) + 1;
        if (pl.playedAt >= since) {
          (skipArtist[ArtistNames.current.key(t.artist)] ??= {}).add(pl.trackId);
          if (t.genre.isNotEmpty) (skipGenre[t.genre] ??= {}).add(pl.trackId);
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
      final w = _Why();
      final a = (artistW[ArtistNames.current.key(t.artist)] ?? 0) / maxA;
      final g = t.genre.isEmpty ? 0.0 : (genreW[t.genre] ?? 0) / maxG;
      final mood = t.effectiveMood;
      final m = mood == null ? 0.0 : (moodW[mood] ?? 0) / maxM;
      if (a > 0) w.add(3 * a, 'porque você ouve ${ArtistNames.current.main(t.artist)}');
      if (g > 0) w.add(1.5 * g, 'gênero ${t.genre}');
      if (m > 0) w.add(1 * m, 'clima ${mood!.label.toLowerCase()}');
      final taste = w.score;
      if (t.favorite) w.add(1.5, 'uma das suas favoritas');
      final hw = hourW[t.id] ?? 0;
      if (hw > 0) w.add(.5 * hw.clamp(0, 3), 'você ouve nesse horário');
      var s = w.score;
      var reason = w.reason;
      // ainda não tocou, mas combina com o seu gosto: vale descobrir
      if (taste > 0 && !played.contains(t.id)) {
        s += .8;
        reason = '$reason · nunca tocou';
      }
      s -= .6 * (today[t.id] ?? 0).clamp(0, 3); // já tocou hoje: dá vez para outras
      s -= 1.5 * (skips[t.id] ?? 0); // o pulo pesa na própria faixa
      // artista/gênero só perdem pontos quando você pulou 3 músicas diferentes deles no mês
      final sa = skipArtist[ArtistNames.current.key(t.artist)]?.length ?? 0;
      final sg = skipGenre[t.genre]?.length ?? 0;
      if (sa >= 3) s -= .4 * sa.clamp(0, 5);
      if (sg >= 3) s -= .25 * sg.clamp(0, 5);
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
      var (s, reason) = affinityWhy(seed, t);
      final n = next[t.id] ?? 0;
      if (n > 0) {
        final v = 2.0 * n.clamp(0, 3);
        if (reason.isEmpty || v >= 2) reason = 'você costuma ouvir em seguida';
        s += v;
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
      final (s, reason) = affinityWhy(seed, t);
      if (s > 0) out.add(Recommendation(t, s + (t.favorite ? .3 : 0), reason));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return diversify(out, perArtist: 4, perAlbum: 3, limit: limit);
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

  static const _broadTags = Styles.broadTags;

  static Set<String> _soundTags(Track t, List<MusicTag>? Function(Track)? tagsOf) => Styles.soundTags(t, tagsOf: tagsOf);

  /// Playlist com o nome de um clima ("Triste", "Calmo"...): o clima vira a regra principal.
  static Mood? moodOfPlaylistName(String name) {
    final n = _plain(name);
    for (final m in Mood.values) {
      if (n == _plain(m.label)) return m;
    }
    return null;
  }

  /// Clima que domina a playlist de verdade: 60% ou mais das músicas com ele, e você escolheu no selo
  /// pelo menos uma delas (um quinto, em playlists grandes). Clima só automático não conta: ele às vezes
  /// vem só do gênero e deixaria qualquer música "calma" passar na frente.
  static Mood? dominantMood(List<Track> playlist) {
    if (playlist.length < 3) return null;
    final count = <Mood, int>{}, chosen = <Mood, int>{};
    for (final t in playlist) {
      final m = t.effectiveMood;
      if (m == null) continue;
      count[m] = (count[m] ?? 0) + 1;
      if (t.chosenMood == m) chosen[m] = (chosen[m] ?? 0) + 1;
    }
    for (final e in count.entries) {
      final c = chosen[e.key] ?? 0;
      if (e.value >= .6 * playlist.length && c >= 1 && c >= .2 * e.value) return e.key;
    }
    return null;
  }

  /// Músicas da biblioteca que combinam com a playlist, da mais para a menos parecida.
  ///
  /// Faz o "retrato" da playlist e dá pontos a cada música que ainda não está nela:
  /// - estilos (até 4): iguais, vizinhos no mapa de estilos ou que você junta nas playlists;
  /// - tags do Last.fm em comum que não são estilo (dreamy, melancholic...), pelo tanto de músicas que as têm;
  /// - réguas (até 2,5): perto do centro da playlist em energia e humor;
  /// - clima igual soma (escolhido à mão vale o dobro); clima que briga tira; playlist com nome de clima manda;
  /// - juntas nas suas outras playlists (até 3,6) e artistas que você costuma juntar (até 1,2).
  /// Artista que ainda não está na playlist ganha um pouco; no máximo 2 por artista; pulada muitas vezes cai.
  /// Conta só em memória, sem internet.
  static List<PlaylistSuggestion> forPlaylist(List<Track> playlist, List<Track> library,
      {String playlistName = '', List<Play> plays = const [], int limit = 60, List<MusicTag>? Function(Track)? tagsOf}) {
    if (playlist.isEmpty) return const [];
    final tagsFor = tagsOf;
    final learn = StyleLearning.current;
    final inside = {for (final t in playlist) t.path};
    final insideIds = {for (final t in playlist) if (t.id != null) t.id!};
    final styleW = <String, double>{}, moodW = <Mood, double>{};
    // tags do Last.fm que não viraram estilo (dreamy, melancholic, 4ad...): acham parentes que o estilo não acha
    final tagW = <String, double>{};
    final artists = <String>{};
    var moodTotal = 0.0;
    double ve = 0, vh = 0;
    final vibes = <Vibe>[];
    const posW = [1.0, .8, .6, .5, .4];
    for (final t in playlist) {
      final st = Styles.of(t);
      for (var i = 0; i < st.length; i++) {
        styleW[st[i]] = (styleW[st[i]] ?? 0) + posW[i];
      }
      final m = t.effectiveMood;
      if (m != null) {
        final w = t.chosenMood != null ? 2.0 : 1.0; // escolhido à mão: vale o dobro
        moodW[m] = (moodW[m] ?? 0) + w;
        moodTotal += w;
      }
      if (Styles.hasVibe(t)) {
        final v = Styles.vibeOf(t);
        vibes.add(v);
        ve += v.energy;
        vh += v.humor;
      }
      if (_known(t.artist, unknownArtist)) artists.add(ArtistNames.current.key(t.artist));
      for (final tag in _soundTags(t, tagsFor)) {
        if (Styles.styleOf(tag) != null) continue; // já contou como estilo
        tagW[tag] = (tagW[tag] ?? 0) + (_broadTags.contains(tag) ? .35 : 1);
      }
    }
    final n = playlist.length.toDouble();
    styleW.updateAll((_, v) => v / n);
    tagW.updateAll((_, v) => v / n);
    final moodCover = playlist.where((t) => t.effectiveMood != null).length / n;
    if (moodTotal > 0) moodW.updateAll((_, v) => v / moodTotal * (.4 + .6 * moodCover));
    final center = vibes.isEmpty ? null : Vibe((ve / vibes.length).round(), (vh / vibes.length).round());
    // playlist espalhada nas réguas aceita músicas mais longe do centro
    final spread = center == null ? 0.0 : vibes.fold<double>(0, (a, v) => a + v.distanceTo(center)) / vibes.length;
    final rule = moodOfPlaylistName(playlistName);
    final dominant = rule == null ? dominantMood(playlist) : null;

    final skips = <int, int>{};
    for (final p in plays) {
      if (p.skipped && p.secondsListened < 30) skips[p.trackId] = (skips[p.trackId] ?? 0) + 1;
    }

    final out = <PlaylistSuggestion>[];
    for (final t in library) {
      if (inside.contains(t.path) || (t.id != null && insideIds.contains(t.id))) continue;
      final w = _Why();
      var minus = 0.0;
      String? label;
      Mood? mood;
      var related = false;
      // estilos
      final st = Styles.of(t);
      if (st.isNotEmpty && styleW.isNotEmpty) {
        var sum = 0.0, wsum = 0.0, bestC = 0.0;
        for (var i = 0; i < st.length; i++) {
          var best = 0.0;
          for (final e in styleW.entries) {
            final c = e.value * Styles.similarity(st[i], e.key);
            if (c > best) best = c;
          }
          sum += best * posW[i];
          wsum += posW[i];
          if (best > bestC) (bestC, label) = (best, st[i]);
        }
        // o estilo que mais bate manda; a média dos outros completa (música com muitos estilos não é punida)
        final styleScore = .6 * bestC + .4 * (sum / wsum);
        if (styleScore > .08) related = true;
        w.add(5 * styleScore, 'estilo $label');
      }
      // tags que não são estilo
      var tagScore = 0.0;
      String? bestTag;
      var bestTagW = 0.0;
      for (final tag in _soundTags(t, tagsFor)) {
        final tw = tagW[tag] ?? 0;
        tagScore += tw;
        if (tw > bestTagW) (bestTag, bestTagW) = (tag, tw);
      }
      if (tagScore > 0) {
        w.add(tagScore > 2.5 ? 2.5 : tagScore, 'tag em comum: ${bestTag ?? ''}');
        related = true;
      }
      // réguas
      if (center != null && Styles.hasVibe(t)) {
        final d = Styles.vibeOf(t).distanceTo(center);
        final reach = 30 + spread;
        if (d < reach) w.add(2.5 * (1 - d / reach), 'energia e humor parecidos');
      }
      // clima
      final m = t.effectiveMood;
      if (m != null) {
        final match = moodW[m] ?? 0;
        if (match > 0) {
          w.add(2.5 * match * (t.chosenMood != null ? 1.5 : 1), 'clima ${m.label.toLowerCase()}');
          mood = m;
          related = true;
        }
        var clash = 0.0;
        for (final e in moodW.entries) {
          if (_clash[e.key]!.contains(m)) clash += e.value;
        }
        minus += 2.5 * clash;
        if (rule != null) {
          if (m != rule) continue; // playlist "Triste" não sugere música de outro clima
          w.add(4, 'clima ${m.label.toLowerCase()}');
          mood = m;
          related = true;
        }
        // clima dominante de verdade (60%+ e escolhido por você em parte): pesa tanto quanto um artista
        if (dominant != null) {
          if (m == dominant) {
            w.add(3, 'clima ${m.label.toLowerCase()}');
          } else {
            minus += 1.5;
          }
        }
      }
      // o que você junta nas outras playlists
      if (t.id != null) {
        var co = 0;
        for (final id in insideIds) {
          co += learn.together(t.id!, id);
        }
        if (co > 0) {
          w.add(1.2 * co.clamp(0, 3), 'junto nas suas playlists');
          related = true;
        }
      }
      final key = _known(t.artist, unknownArtist) ? ArtistNames.current.key(t.artist) : null;
      if (key != null) {
        var aco = 0;
        for (final a in artists) {
          if (a != key) aco += learn.artistsTogether(key, a);
        }
        if (aco > 0) {
          w.add(.6 * aco.clamp(0, 2), 'artista que você junta com estes');
          related = true;
        }
        if (!artists.contains(key)) w.add(.3, 'artista novo na playlist'); // vale descobrir
      }
      if (!related) continue; // só réguas perto não basta: precisa de estilo, tag, clima ou playlist em comum
      if (t.favorite) w.add(.3, 'uma das suas favoritas');
      var s = w.score - minus;
      s -= 1.2 * (skips[t.id] ?? 0).clamp(0, 3); // pulada: a faixa perde (o artista e o estilo, não)
      if (s >= 1.5) out.add(PlaylistSuggestion(t, s, label, mood, w.reason));
    }
    out.sort((x, y) => y.score.compareTo(x.score));
    return diversify(out, perArtist: 2, perAlbum: 2, limit: limit).cast<PlaylistSuggestion>();
  }

  /// "Redescobrir": músicas que você ouvia muito e não toca há mais de 60 dias.
  List<Recommendation> rediscover({int limit = 15}) {
    final count = <int, int>{};
    final last = <int, int>{};
    final byMonth = <int, List<int>>{}; // execuções por mês do ano (1..12)
    for (final pl in plays.where((p) => !p.skipped)) {
      count[pl.trackId] = (count[pl.trackId] ?? 0) + 1;
      if ((last[pl.trackId] ?? 0) < pl.playedAt) last[pl.trackId] = pl.playedAt;
      (byMonth[pl.trackId] ??= List.filled(13, 0))[DateTime.fromMillisecondsSinceEpoch(pl.playedAt).month]++;
    }
    final cutoff = now.subtract(const Duration(days: 60)).millisecondsSinceEpoch;
    final inSeason = <Recommendation>[], offSeason = <Recommendation>[];
    for (final t in tracks) {
      final l = last[t.id];
      final c = count[t.id] ?? 0;
      if (l == null || l > cutoff || (c < 3 && !t.favorite)) continue;
      final days = (now.millisecondsSinceEpoch - l) ~/ 86400000;
      final label = days >= 365 ? '${days ~/ 365} ano(s)' : '${days ~/ 30} meses';
      final r = Recommendation(t, c + (t.favorite ? 5.0 : 0.0), t.favorite ? 'favorita esquecida · $label' : 'não toca há $label');
      // época do ano: a música que você mais ouvia em outra estação vai para o fim (não some)
      final peak = _peakMonth(byMonth[t.id]);
      (peak == null || _monthsApart(peak, now.month) <= 2 ? inSeason : offSeason).add(r);
    }
    inSeason.sort((x, y) => y.score.compareTo(x.score));
    offSeason.sort((x, y) => y.score.compareTo(x.score));
    final first = diversify(inSeason, limit: limit);
    if (first.length >= limit) return first;
    return [...first, ...diversify(offSeason, limit: limit - first.length)];
  }

  /// Mês com mais execuções, se ele for claro (pelo menos 3 execuções e metade delas nele e nos vizinhos).
  static int? _peakMonth(List<int>? months) {
    if (months == null) return null;
    final total = months.fold<int>(0, (a, b) => a + b);
    if (total < 3) return null;
    var best = 1;
    for (var m = 2; m <= 12; m++) {
      if (months[m] > months[best]) best = m;
    }
    final around = months[best] + months[best == 1 ? 12 : best - 1] + months[best == 12 ? 1 : best + 1];
    return around * 2 >= total ? best : null;
  }

  static int _monthsApart(int a, int b) {
    final d = (a - b).abs();
    return d > 6 ? 12 - d : d;
  }
}
