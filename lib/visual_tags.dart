import 'lastfm.dart';
import 'mood.dart';

/// Uma entrada do dicionário: tag musical -> pesquisas visuais.
/// [queries] vão para a busca na web; [anime] são categorias do nekos.best (GIFs automáticos, só anime).
/// [weight] diz o quanto a tag define o visual (1 = muito; 0.5 = pouco, ex.: "german").
class VisualTag {
  final String key;
  final String label;
  final List<String> aliases;
  final List<String> queries;
  final List<String> anime;
  final double weight;
  const VisualTag(this.key, this.label, {this.aliases = const [], required this.queries, this.anime = const [], this.weight = 1.0});
}

/// Dicionário de correspondências. Para expandir, é só acrescentar uma entrada.
/// Não usa IA: a conversão é por texto, com pesos.
const visualTags = <VisualTag>[
  // ---------- atmosfera ----------
  VisualTag('dark', 'Sombrio',
      aliases: ['darkwave', 'dark ambient', 'gothic', 'goth', 'darkness', 'sombrio'],
      queries: ['dark anime', 'dark cinematic', 'dark atmosphere', 'night scenery'],
      anime: ['stare', 'lurk', 'sleep'],
      weight: 1.0),
  VisualTag('melancholic', 'Melancólico',
      aliases: ['melancholy', 'melancholia', 'melancolia', 'melancolico', 'lonely', 'loneliness', 'bittersweet'],
      queries: ['melancholic anime', 'lonely anime', 'rain scenery', 'sad cinematic'],
      anime: ['cry', 'sleep', 'stare', 'pat'],
      weight: 1.0),
  VisualTag('sad', 'Triste',
      aliases: ['sadness', 'triste', 'depressing', 'depressive', 'heartbreak', 'emo', 'tearjerker'],
      queries: ['sad anime', 'anime crying rain', 'lonely anime night', 'sad cinematic'],
      anime: ['cry', 'hug', 'pat', 'pout'],
      weight: 1.0),
  VisualTag('contemplative', 'Contemplativo',
      aliases: ['atmospheric', 'introspective', 'reflective', 'dreamy', 'ethereal', 'haunting', 'epic ballad', 'slow'],
      queries: ['contemplative anime scenery', 'anime sky clouds', 'anime night city lights', 'slow cinematic'],
      anime: ['stare', 'sleep', 'think', 'smile'],
      weight: 0.9),
  VisualTag('calm', 'Calmo',
      aliases: ['chill', 'chillout', 'relaxing', 'relax', 'mellow', 'soft', 'peaceful', 'calmo', 'lofi', 'lo fi', 'ambient', 'acoustic'],
      queries: ['lofi anime', 'cozy anime room', 'anime rain window', 'calm scenery'],
      anime: ['sleep', 'yawn', 'cuddle', 'smile'],
      weight: 0.9),
  VisualTag('beautiful', 'Bonito',
      aliases: ['beautiful', 'lovely', 'amazing', 'awesome', 'masterpiece'],
      queries: ['beautiful anime scenery', 'anime sunset'],
      anime: ['smile', 'wave'],
      weight: 0.4),
  VisualTag('nostalgic', 'Nostálgico',
      aliases: ['nostalgia', 'nostalgic', 'memories', 'childhood', 'oldies', 'classic', 'retro'],
      queries: ['90s anime aesthetic', 'retro anime', 'vhs aesthetic', 'nostalgic anime'],
      anime: ['smile', 'wave', 'happy'],
      weight: 0.9),
  VisualTag('romantic', 'Romântico',
      aliases: ['love', 'love songs', 'romance', 'romantico', 'sensual', 'sexy'],
      queries: ['romantic anime', 'anime couple', 'anime love scene', 'sunset couple'],
      anime: ['kiss', 'hug', 'cuddle', 'handhold', 'blush'],
      weight: 1.0),
  VisualTag('happy', 'Alegre',
      aliases: ['feel good', 'feelgood', 'uplifting', 'cheerful', 'fun', 'summer', 'positive', 'catchy'],
      queries: ['happy anime', 'anime summer', 'cheerful anime', 'anime smile'],
      anime: ['happy', 'smile', 'laugh', 'wave'],
      weight: 0.9),
  VisualTag('euphoric', 'Eufórico',
      aliases: ['euphoria', 'energetic', 'energy', 'hype', 'upbeat'],
      queries: ['anime hype', 'anime concert lights', 'euphoric anime', 'anime fireworks'],
      anime: ['dance', 'happy', 'highfive', 'clap'],
      weight: 0.9),
  VisualTag('epic', 'Épico',
      aliases: ['epic', 'soundtrack', 'cinematic', 'orchestral', 'symphonic', 'powerful', 'anthem', 'ost'],
      queries: ['epic anime', 'anime battle aura', 'epic cinematic', 'anime transformation'],
      anime: ['run', 'thumbsup', 'nod', 'punch'],
      weight: 0.9),
  VisualTag('aggressive', 'Agressivo',
      aliases: ['angry', 'aggressive', 'brutal', 'intense', 'rage', 'heavy', 'hardcore'],
      queries: ['anime fight', 'anime rage', 'anime battle', 'aggressive anime'],
      anime: ['punch', 'kick', 'angry', 'slap', 'shoot'],
      weight: 1.0),

  // ---------- gêneros e estilos ----------
  VisualTag('industrial', 'Industrial',
      aliases: ['industrial metal', 'industrial rock', 'neue deutsche harte', 'neue deutsche härte', 'ndh', 'ebm'],
      queries: ['industrial aesthetic', 'abandoned factory', 'industrial anime', 'steel mill sparks'],
      anime: ['stare', 'punch', 'run'],
      weight: 0.9),
  VisualTag('heavy metal', 'Metal',
      aliases: ['metal', 'heavy metal', 'nu metal', 'alternative metal', 'thrash metal', 'death metal', 'power metal', 'metalcore'],
      queries: ['metal aesthetic', 'dark rock aesthetic', 'anime guitar fire', 'anime headbang'],
      anime: ['punch', 'kick', 'angry'],
      weight: 0.8),
  VisualTag('rock', 'Rock',
      aliases: ['rock', 'hard rock', 'alternative rock', 'alternative', 'grunge', 'punk', 'punk rock', 'indie rock'],
      queries: ['anime rock band', 'anime guitar', 'rock concert aesthetic'],
      anime: ['thumbsup', 'punch', 'highfive'],
      weight: 0.7),
  VisualTag('dance', 'Dança',
      aliases: ['dance', 'eurodance', 'italo dance', 'italo disco', 'disco', 'dance pop', 'club'],
      queries: ['dance animation', 'nightclub', 'party aesthetic', 'anime dance'],
      anime: ['dance', 'happy', 'clap'],
      weight: 1.0),
  VisualTag('party', 'Festa',
      aliases: ['party', 'festa', 'rave', 'clubbing'],
      queries: ['anime party', 'nightclub lights', 'rave aesthetic', 'party aesthetic'],
      anime: ['dance', 'highfive', 'laugh', 'clap'],
      weight: 1.0),
  VisualTag('electronic', 'Eletrônica',
      aliases: ['electronic', 'electronica', 'electro', 'trance', 'techno', 'house', 'edm', 'synthpop', 'synthwave', 'hi nrg', 'progressive house'],
      queries: ['neon anime city', 'synthwave aesthetic', 'anime dj', 'laser lights'],
      anime: ['dance', 'happy', 'wave'],
      weight: 0.8),
  VisualTag('90s', 'Anos 90',
      aliases: ['90s', '1990s', '00s', '2000s', '80s', '1980s'],
      queries: ['90s anime aesthetic', 'retro anime', 'vhs aesthetic'],
      anime: ['wave', 'smile'],
      weight: 0.7),
  VisualTag('hip hop', 'Rap',
      aliases: ['hip hop', 'hip-hop', 'rap', 'trap', 'gangsta rap', 'boom bap'],
      queries: ['anime street', 'anime swag', 'urban anime night', 'anime city rooftop'],
      anime: ['smug', 'thumbsup', 'punch', 'nod'],
      weight: 0.8),
  VisualTag('pop', 'Pop',
      aliases: ['pop', 'j-pop', 'jpop', 'k-pop', 'kpop', 'vocaloid', 'idol'],
      queries: ['anime idol', 'kawaii anime', 'anime concert'],
      anime: ['happy', 'wave', 'dance', 'smile'],
      weight: 0.6),
  VisualTag('jazz', 'Jazz',
      aliases: ['jazz', 'blues', 'soul', 'bossa nova', 'mpb', 'rnb', 'r&b'],
      queries: ['anime jazz bar', 'anime cafe night', 'city pop aesthetic'],
      anime: ['smile', 'nod', 'cuddle'],
      weight: 0.7),
  VisualTag('classical', 'Clássica',
      aliases: ['classical', 'piano', 'instrumental', 'orchestra', 'new age'],
      queries: ['anime piano', 'anime scenery night sky', 'anime library'],
      anime: ['sleep', 'think', 'smile'],
      weight: 0.7),

  // ---------- pouco visuais (só ajudam um pouco) ----------
  VisualTag('german', 'Alemão',
      aliases: ['german', 'deutsch', 'germany'],
      queries: ['industrial city night', 'gothic architecture'],
      weight: 0.3),
  VisualTag('italian', 'Italiano',
      aliases: ['italian', 'italy', 'italiano'],
      queries: ['italian summer aesthetic', 'beach night party'],
      weight: 0.3),
];

/// Clima escolhido no selo -> entrada do dicionário (o clima manual pesa mais que as tags).
const _moodEntry = {
  Mood.calmo: 'calm',
  Mood.triste: 'sad',
  Mood.romantico: 'romantic',
  Mood.festa: 'party',
  Mood.epico: 'epic',
  Mood.acao: 'aggressive',
};

/// Uma pesquisa visual pronta, com o grupo (categoria visual) e a prioridade.
class VisualQuery {
  final String text;
  final String group;
  final double score;
  const VisualQuery(this.text, this.group, this.score);
  @override
  String toString() => '$text [$group ${score.toStringAsFixed(2)}]';
}

/// Resultado da conversão: pesquisas para a web e categorias de anime para o automático.
class VisualPlan {
  /// Todas as pesquisas, da mais para a menos importante (sem repetidas).
  final List<VisualQuery> all;

  /// Categorias do nekos.best, da mais para a menos importante.
  final List<String> anime;

  /// Tags que bateram com o dicionário (para mostrar ao usuário).
  final List<String> matchedTags;

  /// true = veio do Last.fm; false = alternativa básica (nome, artista, gênero).
  final bool fromTags;

  const VisualPlan({required this.all, required this.anime, required this.matchedTags, required this.fromTags});

  /// As primeiras [limit] pesquisas (para não fazer consultas demais).
  List<VisualQuery> top([int limit = VisualTagMapper.maxQueries]) => all.take(limit).toList();

  /// Pesquisas agrupadas por categoria visual, na ordem de importância.
  Map<String, List<VisualQuery>> get byGroup {
    final out = <String, List<VisualQuery>>{};
    for (final q in all) {
      out.putIfAbsent(q.group, () => []).add(q);
    }
    return out;
  }
}

/// Converte tags musicais em pesquisas visuais usando [visualTags].
class VisualTagMapper {
  static const maxQueries = 8;
  static const maxAnime = 6;

  /// Tag que só contém a palavra (ex.: "industrial metal" contém "metal") vale menos que a igual.
  static const partialFactor = 0.6;

  final List<VisualTag> dictionary;
  late final Map<String, VisualTag> _exact = {
    for (final e in dictionary) ...{for (final a in [e.key, ...e.aliases]) normalize(a): e},
  };

  VisualTagMapper([this.dictionary = visualTags]);

  /// Minúsculas, sem acento comum, sem hífen/sublinhado e sem espaços sobrando.
  static String normalize(String s) {
    var t = s.toLowerCase().trim();
    const from = 'áàâãäéèêëíìîïóòôõöúùûüç';
    const to = 'aaaaaeeeeiiiiooooouuuuc';
    for (var i = 0; i < from.length; i++) {
      t = t.replaceAll(from[i], to[i]);
    }
    return t.replaceAll(RegExp(r'[-_/]+'), ' ').replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Quanto cada entrada do dicionário vale para essas tags.
  Map<VisualTag, double> scoreEntries(List<MusicTag> tags, {Mood? mood, List<String>? matched}) {
    final scores = <VisualTag, double>{};
    void add(VisualTag e, double v) => scores[e] = (scores[e] ?? 0) + v;
    final maxCount = tags.fold<int>(1, (m, t) => t.count > m ? t.count : m);
    for (final tag in tags) {
      final n = normalize(tag.name);
      final relevance = tag.count / maxCount; // a tag mais usada vale 1
      final exact = _exact[n];
      if (exact != null) {
        add(exact, relevance * exact.weight);
        matched?.add(tag.name);
        continue;
      }
      // tags compostas: "industrial metal" -> industrial + metal (cada uma pela metade, mais ou menos)
      final words = ' $n ';
      var hit = false;
      for (final entry in _exact.entries) {
        if (entry.key.length >= 3 && words.contains(' ${entry.key} ')) {
          add(entry.value, relevance * entry.value.weight * partialFactor);
          hit = true;
        }
      }
      if (hit) matched?.add(tag.name);
    }
    final m = mood == null ? null : dictionary.where((e) => e.key == _moodEntry[mood]).firstOrNull;
    if (m != null) {
      // clima escolhido à mão: fica à frente de qualquer tag
      final top = scores.values.fold<double>(1, (a, b) => a > b ? a : b);
      add(m, top * 1.5);
    }
    return scores;
  }

  /// Tags -> plano. Sem tags (ou nenhuma conhecida), usa a alternativa básica.
  VisualPlan convert(List<MusicTag> tags, {Mood? mood, String title = '', String artist = '', String genre = ''}) {
    final matched = <String>[];
    final scores = scoreEntries(tags, mood: mood, matched: matched);
    if (scores.isEmpty) return fallback(title: title, artist: artist, genre: genre, mood: mood);

    final qScore = <String, double>{};
    final qGroup = <String, String>{};
    final qGroupScore = <String, double>{};
    final aScore = <String, double>{};
    for (final MapEntry(key: e, value: s) in scores.entries) {
      for (var i = 0; i < e.queries.length; i++) {
        final q = e.queries[i];
        final k = normalize(q);
        // a primeira pesquisa da entrada vale um pouco mais que as outras
        final v = s * (1 - i * 0.08);
        qScore[k] = (qScore[k] ?? 0) + v; // várias tags podem somar na mesma pesquisa
        if (v > (qGroupScore[k] ?? -1)) {
          qGroup[k] = e.label;
          qGroupScore[k] = v;
        }
        qGroup.putIfAbsent(k, () => e.label);
      }
      for (var i = 0; i < e.anime.length; i++) {
        aScore[e.anime[i]] = (aScore[e.anime[i]] ?? 0) + s * (1 - i * 0.1);
      }
    }
    final all = [for (final k in qScore.keys) VisualQuery(k, qGroup[k]!, qScore[k]!)]..sort((a, b) => b.score.compareTo(a.score));
    final anime = (aScore.keys.toList()..sort((a, b) => aScore[b]!.compareTo(aScore[a]!))).take(maxAnime).toList();
    return VisualPlan(all: all, anime: anime, matchedTags: matched, fromTags: tags.isNotEmpty);
  }

  /// Alternativa quando o Last.fm não ajuda: nome da música, artista e o que o app já sabe (gênero, clima).
  VisualPlan fallback({String title = '', String artist = '', String genre = '', Mood? mood}) {
    final fromInfo = <MusicTag>[
      if (genre.trim().isNotEmpty && normalize(genre) != 'desconhecido') MusicTag(genre, 100),
    ];
    final scored = fromInfo.isEmpty && mood == null ? null : convert(fromInfo, mood: mood);
    final basic = <VisualQuery>[
      if (title.trim().isNotEmpty && artist.trim().isNotEmpty) VisualQuery('$title $artist', 'Música', 0.5),
      if (title.trim().isNotEmpty) VisualQuery('$title anime', 'Música', 0.4),
      if (artist.trim().isNotEmpty) VisualQuery('$artist aesthetic', 'Artista', 0.3),
    ];
    final seen = <String>{};
    final all = [...?scored?.all, ...basic].where((q) => seen.add(normalize(q.text))).toList();
    return VisualPlan(all: all, anime: scored?.anime ?? const [], matchedTags: const [], fromTags: false);
  }
}
