import 'lastfm.dart' show MusicTag;
import 'models.dart';
import 'visual_tags.dart' show VisualTagMapper;

/// Clima que o usuário escolhe para a música (selo no GIF). Muda os GIFs de anime e o mix "da mesma vibe".
enum Mood {
  calmo('Calmo', '🌙', ['sleep', 'yawn', 'cuddle', 'pat', 'smile']),
  triste('Triste', '💧', ['cry', 'hug', 'pat', 'pout', 'sleep']),
  romantico('Romântico', '💗', ['kiss', 'hug', 'cuddle', 'handhold', 'blush']),
  festa('Festa', '🎉', ['dance', 'happy', 'highfive', 'clap', 'laugh']),
  epico('Épico', '🏔️', ['run', 'thumbsup', 'highfive', 'nod', 'wave']),
  acao('Ação', '👊', ['punch', 'kick', 'shoot', 'slap', 'angry', 'yeet']);

  final String label;
  final String emoji;
  final List<String> categories;
  const Mood(this.label, this.emoji, this.categories);

  static Mood? byName(String? name) => name == null || name.isEmpty ? null : _byName[name];
  static final Map<String, Mood> _byName = Mood.values.asNameMap();

  /// Clima que só o gênero sugere (sem as outras pistas). Gêneros vagos (rock, pop, rap, indie...) dão null.
  static Mood? fromGenre(String genre) => MoodClues.guess(genre: genre).mood;
}

/// Resultado do clima automático: o vencedor (ou null = neutro), os pontos e de onde vieram.
class MoodGuess {
  final Mood? mood;
  final Map<Mood, double> scores;
  final List<String> reasons;
  const MoodGuess(this.mood, this.scores, this.reasons);
}

/// Clima automático por pistas, somadas por música (sem análise de áudio).
///
/// Da mais forte para a mais fraca:
/// 1. tags de clima da música no Last.fm ("sad", "chill", "love"...). Tags que são só gênero ("rock") não contam aqui;
/// 2. palavras do título e do álbum ("acoustic", "slowed", "remix", "OST");
/// 3. climas que o usuário já escolheu à mão em outras músicas do mesmo álbum/artista;
/// 4. o gênero, só quando ele diz algo claro (lo-fi, metalcore, sertanejo, trilha sonora).
///
/// Se nenhum clima tiver pontos suficientes e folga sobre o segundo, fica neutro (null) em vez de chutar.
class MoodClues {
  /// Pontos mínimos para decidir.
  static const minScore = 0.6;

  /// Folga mínima do 1º sobre o 2º (senão é empate e fica neutro).
  static const minLead = 0.25;

  /// Quanto as tags do Last.fm pesam (uma tag de clima forte vence o gênero).
  static const tagFactor = 1.5;

  /// Tags do Last.fm já guardadas para a música (preenchido pelo AppState; sem isto, só as outras pistas).
  static List<MusicTag>? Function(Track t) tagsOf = (_) => null;

  static Map<String, Map<Mood, int>> _byArtist = {};
  static Map<String, Map<Mood, int>> _byAlbum = {};
  static Expando<MoodGuess> _cache = Expando();

  /// Relê as escolhas manuais da biblioteca (chamado a cada releitura).
  static void learnFrom(List<Track> tracks) {
    final artist = <String, Map<Mood, int>>{};
    final album = <String, Map<Mood, int>>{};
    for (final t in tracks) {
      final m = Mood.byName(t.mood);
      if (m == null) continue;
      final a = _artistKey(t);
      if (a != null) (artist[a] ??= {}).update(m, (n) => n + 1, ifAbsent: () => 1);
      final al = _albumKey(t);
      if (al != null) (album[al] ??= {}).update(m, (n) => n + 1, ifAbsent: () => 1);
    }
    _byArtist = artist;
    _byAlbum = album;
    invalidate();
  }

  /// Esquece os resultados guardados (tags novas chegaram ou as escolhas mudaram).
  static void invalidate() => _cache = Expando();

  /// Clima automático da música, guardado por objeto (as telas pedem isto para cada linha).
  /// [tags]: tags já em mãos (quem busca os GIFs); sem elas, usa [tagsOf].
  static MoodGuess forTrack(Track t, {List<MusicTag>? tags}) {
    if (tags != null) return _guessFor(t, tags);
    return _cache[t] ??= _guessFor(t, tagsOf(t) ?? const []);
  }

  static MoodGuess _guessFor(Track t, List<MusicTag> tags) => guess(
        genre: t.genre,
        title: t.title,
        album: t.album,
        tags: tags,
        artistChoices: _byArtist[_artistKey(t)],
        albumChoices: _byAlbum[_albumKey(t)],
      );

  static String? _artistKey(Track t) {
    final a = t.artist.trim().toLowerCase();
    return a.isEmpty || a == unknownArtist.toLowerCase() ? null : a;
  }

  static String? _albumKey(Track t) {
    final al = t.album.trim().toLowerCase();
    final a = _artistKey(t);
    return al.isEmpty || al == unknownAlbum.toLowerCase() || a == null ? null : '$a|$al';
  }

  /// Soma as pistas. Função pura (testável); [forTrack] é quem busca as pistas da música.
  static MoodGuess guess({
    String genre = '',
    String title = '',
    String album = '',
    List<MusicTag> tags = const [],
    Map<Mood, int>? artistChoices,
    Map<Mood, int>? albumChoices,
  }) {
    final scores = <Mood, double>{};
    final reasons = <String>[];
    void add(Mood m, double v) => scores[m] = (scores[m] ?? 0) + v;
    // o gênero é do artista: quando a própria música tem tags de clima, ele vale metade
    var songSpecific = false;

    // 1. tags de clima do Last.fm
    if (tags.isNotEmpty) {
      final maxCount = tags.fold<int>(1, (m, t) => t.count > m ? t.count : m);
      final used = <String>[];
      for (final tag in tags) {
        if (tag.count <= 0 && maxCount > 1) continue;
        final hits = _tagHits(VisualTagMapper.normalize(tag.name));
        if (hits.isEmpty) continue;
        // tags de clima costumam ter contagem menor que as de gênero: mesmo as fracas valem um mínimo
        final rel = 0.4 + 0.6 * (tag.count / maxCount);
        hits.forEach((m, w) => add(m, rel * w * tagFactor));
        used.add(tag.name);
      }
      if (used.isNotEmpty) reasons.add('tags: ${used.take(4).join(', ')}');
      songSpecific = used.isNotEmpty;
    }

    // 2. título e álbum
    final t = VisualTagMapper.normalize(title);
    for (final (re, hits) in _titleRes) {
      if (re.hasMatch(t)) {
        hits.forEach(add);
        reasons.add('título');
        break;
      }
    }
    final al = VisualTagMapper.normalize(album);
    for (final (re, hits) in _albumRes) {
      if (re.hasMatch(al)) {
        hits.forEach(add);
        reasons.add('álbum');
        break;
      }
    }

    // 3. o que o usuário já escolheu no mesmo álbum / artista
    void fromChoices(Map<Mood, int>? c, double weight, String why) {
      if (c == null) return;
      final total = c.values.fold<int>(0, (a, b) => a + b);
      if (total < 2) return;
      c.forEach((m, n) {
        if (n >= 2) add(m, weight * n / total);
      });
      reasons.add(why);
    }

    fromChoices(albumChoices, 1.2, 'suas escolhas no álbum');
    fromChoices(artistChoices, 0.9, 'suas escolhas no artista');

    // 4. gênero (só os que dizem algo claro)
    final g = genre.toLowerCase().trim();
    if (g.isNotEmpty && g != 'desconhecido') {
      for (final (re, hits) in _genreRes) {
        if (re.hasMatch(g)) {
          hits.forEach((m, w) => add(m, songSpecific ? w * 0.5 : w));
          reasons.add('gênero');
          break;
        }
      }
    }

    final ranked = scores.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    if (ranked.isEmpty) return MoodGuess(null, scores, reasons);
    final best = ranked.first;
    final second = ranked.length > 1 ? ranked[1].value : 0.0;
    final ok = best.value >= minScore && best.value - second >= minLead;
    return MoodGuess(ok ? best.key : null, scores, reasons);
  }

  /// Andamento fora disso é erro de tag: conta como ausente.
  static int? validBpm(int? bpm) => bpm == null || bpm < 40 || bpm > 220 ? null : bpm;

  /// Multiplicador de andamento por clima (sem análise de áudio: só o BPM da tag/Last.fm e a energia, se vierem).
  /// Lento (BPM < 80 ou energia < 0.35): triste, calmo e romântico sobem; festa e ação descem.
  /// Rápido (BPM > 125 ou energia > 0.7): festa, ação e épico sobem; calmo desce. Senão, nada muda.
  static Map<Mood, double> tempoFactors({int? bpm, double? energy}) {
    final b = validBpm(bpm);
    final e = energy == null || energy < 0 || energy > 1 ? null : energy;
    if ((b != null && b < 80) || (e != null && e < 0.35)) {
      return {_t: 1.4, _c: 1.4, _r: 1.4, _f: 0.45, _a: 0.45};
    }
    if ((b != null && b > 125) || (e != null && e > 0.7)) {
      return {_f: 1.3, _a: 1.3, _e: 1.3, _c: 0.5};
    }
    return const {};
  }

  /// Pontos do clima com o andamento aplicado (cópia; o original não muda).
  static Map<Mood, double> withTempo(Map<Mood, double> scores, {int? bpm, double? energy}) {
    final f = tempoFactors(bpm: bpm, energy: energy);
    return {for (final MapEntry(key: m, value: v) in scores.entries) m: v * (f[m] ?? 1)};
  }

  /// Tag (normalizada) -> climas. Igual vale inteiro; tag composta que contém a palavra ("sad songs") vale 70%.
  static Map<Mood, double> _tagHits(String n) {
    final exact = _tagWords[n];
    if (exact != null) return exact;
    final words = ' $n ';
    final out = <Mood, double>{};
    for (final MapEntry(key: k, value: hits) in _tagWords.entries) {
      if (k.length >= 3 && words.contains(' $k ')) {
        hits.forEach((m, w) => out[m] = (out[m] ?? 0) + w * 0.7);
      }
    }
    return out;
  }

  static const _t = Mood.triste, _c = Mood.calmo, _r = Mood.romantico, _f = Mood.festa, _e = Mood.epico, _a = Mood.acao;

  /// Palavras de clima nas tags do Last.fm. Gêneros puros ficam de fora de propósito.
  static const Map<String, Map<Mood, double>> _tagWords = {
    // triste
    'sad': {_t: 1}, 'sadness': {_t: 1}, 'sad songs': {_t: 1}, 'melancholic': {_t: 1}, 'melancholy': {_t: 1},
    'melancholia': {_t: 1}, 'depressing': {_t: 1}, 'depressive': {_t: 1}, 'depression': {_t: 1},
    'heartbreak': {_t: 1}, 'heartbroken': {_t: 1}, 'breakup': {_t: 0.8}, 'lonely': {_t: 1}, 'loneliness': {_t: 1},
    'tearjerker': {_t: 1}, 'crying': {_t: 1}, 'emotional': {_t: 0.6, _r: 0.2}, 'bittersweet': {_t: 0.7},
    'triste': {_t: 1}, 'sofrencia': {_t: 1}, 'saudade': {_t: 0.8}, 'grief': {_t: 1}, 'pain': {_t: 0.6},
    'suicide': {_t: 1}, 'emo': {_t: 0.6},
    // calmo
    'chill': {_c: 1}, 'chillout': {_c: 1}, 'chill out': {_c: 1}, 'relaxing': {_c: 1}, 'relax': {_c: 1},
    'mellow': {_c: 1}, 'calm': {_c: 1}, 'peaceful': {_c: 1}, 'soothing': {_c: 1}, 'soft': {_c: 0.7},
    'lofi': {_c: 1}, 'lo fi': {_c: 1}, 'ambient': {_c: 0.7}, 'acoustic': {_c: 0.6}, 'dreamy': {_c: 0.6},
    'sleep': {_c: 1}, 'easy listening': {_c: 0.8}, 'atmospheric': {_c: 0.5}, 'slow': {_c: 0.5, _t: 0.2},
    'ethereal': {_c: 0.6}, 'night': {_c: 0.3}, 'rainy day': {_c: 0.5, _t: 0.4}, 'introspective': {_c: 0.5, _t: 0.3},
    // romântico
    'love': {_r: 1}, 'love songs': {_r: 1}, 'love song': {_r: 1}, 'romantic': {_r: 1}, 'romance': {_r: 1},
    'sensual': {_r: 1}, 'sexy': {_r: 0.7}, 'amor': {_r: 1}, 'romantico': {_r: 1}, 'ballad': {_r: 0.5, _t: 0.4},
    'power ballad': {_r: 0.5, _t: 0.4}, 'wedding': {_r: 1}, 'crush': {_r: 0.8},
    // festa
    'party': {_f: 1}, 'dance': {_f: 0.8}, 'danceable': {_f: 1}, 'fun': {_f: 0.8}, 'happy': {_f: 0.9},
    'feel good': {_f: 1}, 'feelgood': {_f: 1}, 'upbeat': {_f: 0.7, _e: 0.2}, 'summer': {_f: 0.6},
    'groovy': {_f: 0.8}, 'club': {_f: 0.8}, 'cheerful': {_f: 0.9}, 'catchy': {_f: 0.3}, 'festa': {_f: 1},
    'uplifting': {_f: 0.4, _e: 0.5},
    // épico
    'epic': {_e: 1}, 'soundtrack': {_e: 0.7}, 'cinematic': {_e: 1}, 'orchestral': {_e: 0.8}, 'anthem': {_e: 0.8},
    'powerful': {_e: 0.7, _a: 0.2}, 'motivational': {_e: 1}, 'motivation': {_e: 1}, 'inspiring': {_e: 0.8},
    'inspirational': {_e: 0.8}, 'triumphant': {_e: 1}, 'heroic': {_e: 1}, 'majestic': {_e: 1}, 'ost': {_e: 0.6},
    'anime opening': {_e: 0.7}, 'opening': {_e: 0.4},
    // ação
    'aggressive': {_a: 1}, 'angry': {_a: 1}, 'rage': {_a: 1}, 'anger': {_a: 1}, 'brutal': {_a: 1},
    'intense': {_a: 0.7, _e: 0.2}, 'heavy': {_a: 0.5}, 'fight': {_a: 1}, 'workout': {_a: 0.6, _e: 0.2},
    'adrenaline': {_a: 1}, 'badass': {_a: 0.8}, 'hype': {_a: 0.4, _f: 0.3}, 'energetic': {_a: 0.4, _f: 0.3, _e: 0.2},
    'energy': {_a: 0.3, _f: 0.3}, 'fast': {_a: 0.4}, 'war': {_a: 0.7}, 'gym': {_a: 0.6},
  };

  static final _titleRes = <(RegExp, Map<Mood, double>)>[
    (RegExp(r'acoustic|acustic|unplugged|stripped|piano version|versao piano|lullaby|de ninar'), {_c: 1.0}),
    (RegExp(r'slowed|reverb'), {_t: 0.6, _c: 0.5}),
    (RegExp(r'nightcore|sped up|club mix|extended mix|remix'), {_f: 0.8}),
    (RegExp(r'\b(tv size|opening|abertura)\b'), {_e: 0.5}),
    (RegExp(r'\b(love|amor|kiss|beijo|heart|coracao|paixao)\b'), {_r: 0.5}),
    (RegExp(r'\b(sad|cry|tears|lagrimas|saudade|goodbye|adeus)\b'), {_t: 0.5}),
    (RegExp(r'\binstrumental\b'), {_c: 0.4}),
  ];

  static final _albumRes = <(RegExp, Map<Mood, double>)>[
    (RegExp(r'unplugged|acoustic|acustico|ao vivo acustico'), {_c: 0.8}),
    (RegExp(r'soundtrack|\bost\b|trilha sonora|original score|game music'), {_e: 0.6}),
    (RegExp(r'lo ?fi|chill|sleep|relax'), {_c: 0.8}),
  ];

  /// Gênero -> clima. A primeira regra que bater vale. Gêneros vagos (rock, pop, rap, indie...) não estão aqui.
  static final _genreRes = <(RegExp, Map<Mood, double>)>[
    (RegExp(r'lo.?fi|chill|ambient|new.?age|sleep|meditat|lullaby|ninar'), {_c: 1.0}),
    (RegExp(r'\bemo\b|sad|depress|sofr[eê]ncia|slowcore|dsbm'), {_t: 0.9}),
    (RegExp(r'romant|love|bachata|kizomba|zouk|bolero|r&b|rnb|slow.?jam'), {_r: 0.8}),
    (RegExp(r'soundtrack|trilha|\bost\b|\bscore\b|video.?game|game.?music|epic|[eé]pic|symphonic|power.?metal|orchestral|cinematic'), {_e: 0.9}),
    (RegExp(r'anime|anisong|j-?rock'), {_e: 0.5}),
    (RegExp(r'death|black.?metal|thrash|grind|hardcore|metalcore|deathcore|djent|nu.?metal|industrial|brutal|drill|phonk|hardstyle'), {_a: 0.9}),
    (RegExp(r'metal'), {_a: 0.7}),
    (RegExp(r'punk|grunge|hard.?rock'), {_a: 0.5}),
    (RegExp(r'funk|disco|dance|edm|house|techno|trance|eurobeat|electro|forr[oó]|pagode|samba|ax[eé]|arrocha|piseiro|brega|cumbia|reggaeton|dancehall|hyperpop|k-?pop|j-?pop|idol'), {_f: 0.7}),
    (RegExp(r'sertanejo|latin|country'), {_f: 0.5}),
    (RegExp(r'bossa|mpb|jazz|smooth|easy.?listening|acoustic|ac[uú]stic|singer.?songwriter|folk|classical|\bcl[aá]ssica\b|piano|instrumental|post.?rock|shoegaze|dream.?pop'), {_c: 0.6}),
  ];
}

extension TrackMood on Track {
  /// Clima escolhido pelo usuário (ou null = automático).
  Mood? get chosenMood => Mood.byName(mood);

  /// Clima automático por pistas (null = neutro).
  Mood? get autoMood => MoodClues.forTrack(this).mood;

  /// Clima que vale: o escolhido, senão o automático.
  Mood? get effectiveMood => chosenMood ?? autoMood;
}
