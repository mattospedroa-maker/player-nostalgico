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

  /// true = cena de videoclipe (procurada no texto do clipe na Wikipédia, não nas tags).
  final bool scene;
  const VisualTag(this.key, this.label,
      {this.aliases = const [], required this.queries, this.anime = const [], this.weight = 1.0, this.scene = false});
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

  // ---------- cenas de videoclipe (lidas na seção "Music video" da Wikipédia) ----------
  VisualTag('desert', 'Deserto', scene: true, aliases: ['deserts', 'dunes', 'sand'], queries: ['desert scenery', 'desert wind sand', 'desert sunset']),
  VisualTag('rain', 'Chuva', scene: true, aliases: ['raining', 'rainy', 'storm', 'thunderstorm'], queries: ['rain scenery', 'rain window night', 'storm lightning'], anime: ['cry', 'stare']),
  VisualTag('snow', 'Neve', scene: true, aliases: ['snowy', 'winter', 'ice', 'frozen', 'blizzard'], queries: ['snow falling scenery', 'winter night snow', 'frozen landscape']),
  VisualTag('ocean', 'Mar', scene: true, aliases: ['sea', 'beach', 'waves', 'shore', 'underwater', 'island'], queries: ['ocean waves', 'beach sunset', 'underwater scenery']),
  VisualTag('space', 'Espaço', scene: true, aliases: ['outer space', 'astronaut', 'astronauts', 'planet', 'stars', 'galaxy', 'spaceship', 'moon'], queries: ['space galaxy', 'astronaut floating', 'starry sky']),
  VisualTag('war', 'Guerra', scene: true, aliases: ['soldier', 'soldiers', 'battle', 'battlefield', 'army', 'bombing', 'military', 'trenches'], queries: ['war battlefield', 'soldiers marching', 'battle explosion'], anime: ['shoot', 'punch', 'run']),
  VisualTag('apocalypse', 'Apocalipse', scene: true, aliases: ['apocalyptic', 'post apocalyptic', 'ruins', 'ruined', 'wasteland', 'destroyed', 'destruction', 'end of the world'], queries: ['apocalyptic scenery', 'ruined city', 'wasteland']),
  VisualTag('city', 'Cidade', scene: true, aliases: ['city', 'streets', 'street', 'downtown', 'skyscrapers', 'rooftop', 'urban'], queries: ['city night lights', 'city street rain night', 'rooftop city view']),
  VisualTag('forest', 'Floresta', scene: true, aliases: ['forest', 'woods', 'jungle', 'trees'], queries: ['forest scenery', 'misty forest', 'forest sunlight']),
  VisualTag('fire', 'Fogo', scene: true, aliases: ['fire', 'flames', 'burning', 'burns', 'pyrotechnics', 'explosion', 'explosions'], queries: ['fire flames', 'burning aesthetic', 'pyrotechnics concert'], anime: ['angry', 'punch']),
  VisualTag('car', 'Estrada', scene: true, aliases: ['car', 'cars', 'driving', 'road', 'highway', 'motorcycle', 'race'], queries: ['night drive aesthetic', 'highway at night', 'car racing']),
  VisualTag('time', 'Tempo', scene: true, aliases: ['clock', 'clocks', 'hourglass', 'slow motion', 'frozen in time', 'aging', 'old age', 'elderly'], queries: ['clock time passing', 'hourglass sand', 'time lapse sky'], anime: ['stare', 'think']),
  VisualTag('school', 'Escola', scene: true, aliases: ['school', 'classroom', 'students', 'high school', 'college'], queries: ['school classroom', 'school hallway', 'students'], anime: ['laugh', 'wave', 'happy']),
  VisualTag('church', 'Igreja', scene: true, aliases: ['church', 'cathedral', 'priest', 'nun', 'altar', 'religious'], queries: ['cathedral interior', 'church candles', 'gothic cathedral']),
  VisualTag('grave', 'Funeral', scene: true, aliases: ['funeral', 'cemetery', 'graveyard', 'coffin', 'death', 'dead', 'dying'], queries: ['cemetery fog', 'funeral rain', 'graveyard night'], anime: ['cry', 'hug']),
  VisualTag('horror', 'Terror', scene: true, aliases: ['zombie', 'zombies', 'vampire', 'vampires', 'ghost', 'ghosts', 'monster', 'monsters', 'demon', 'horror'], queries: ['horror aesthetic', 'zombie', 'creepy ghost'], anime: ['lurk', 'stare']),
  VisualTag('robot', 'Robôs', scene: true, aliases: ['robot', 'robots', 'android', 'cyborg', 'mech', 'machine', 'machines', 'futuristic'], queries: ['robot', 'cyberpunk city', 'mecha']),
  VisualTag('club', 'Balada', scene: true, aliases: ['nightclub', 'club', 'disco', 'dancers', 'dancing', 'dance floor', 'party'], queries: ['nightclub dancing', 'disco ball', 'dance floor lights'], anime: ['dance', 'clap']),
  VisualTag('stage', 'Show', scene: true, aliases: ['concert', 'stage', 'performing', 'performance', 'performs', 'live footage', 'audience', 'crowd'], queries: ['concert crowd lights', 'band on stage', 'stage lights'], anime: ['thumbsup', 'highfive']),
  VisualTag('mountain', 'Montanhas', scene: true, aliases: ['mountain', 'mountains', 'cliff', 'cliffs', 'valley'], queries: ['mountain scenery', 'cliff edge view', 'mountain clouds']),
  VisualTag('wedding', 'Casamento', scene: true, aliases: ['wedding', 'bride', 'groom', 'marriage'], queries: ['wedding romantic', 'bride veil wind'], anime: ['kiss', 'handhold']),
  VisualTag('prison', 'Prisão', scene: true, aliases: ['prison', 'jail', 'prisoner', 'prisoners', 'cell', 'chains', 'escape'], queries: ['prison escape', 'prison cell dark']),
  VisualTag('sunset', 'Pôr do sol', scene: true, aliases: ['sunset', 'sunrise', 'dawn', 'dusk', 'golden hour'], queries: ['sunset sky', 'golden hour aesthetic']),

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

  /// Cenas do videoclipe que entraram nas pesquisas (rótulos, ex.: "Deserto").
  final List<String> clipScenes;

  const VisualPlan({required this.all, required this.anime, required this.matchedTags, required this.fromTags, this.clipScenes = const []});

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
    for (final e in dictionary.where((e) => !e.scene)) ...{for (final a in [e.key, ...e.aliases]) normalize(a): e},
  };
  late final Map<String, VisualTag> _scenes = {for (final e in dictionary.where((e) => e.scene)) e.key: e};

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
  /// [scenes]: cenas do videoclipe (chave -> vezes citada no texto); valem como uma tag forte.
  Map<VisualTag, double> scoreEntries(List<MusicTag> tags, {Mood? mood, List<String>? matched, Map<String, int> scenes = const {}}) {
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
    final maxScene = scenes.values.fold<int>(1, (m, n) => n > m ? n : m);
    for (final MapEntry(key: k, value: n) in scenes.entries) {
      final e = _scenes[k];
      // o clipe é bem específico da música: pesa um pouco mais que uma tag
      if (e != null) add(e, 1.1 * (0.5 + 0.5 * n / maxScene) * e.weight);
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
  VisualPlan convert(List<MusicTag> tags,
      {Mood? mood, String title = '', String artist = '', String genre = '', Map<String, int> scenes = const {}}) {
    final matched = <String>[];
    final hasTagMatch = scoreEntries(tags, matched: []).isNotEmpty;
    final scores = scoreEntries(tags, mood: mood, matched: matched, scenes: scenes);
    // sem tags conhecidas: alternativa básica (que ainda usa o clipe e o clima)
    if (!hasTagMatch && tags.isNotEmpty || scores.isEmpty) {
      return fallback(title: title, artist: artist, genre: genre, mood: mood, scenes: scenes);
    }

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
    return VisualPlan(all: all, anime: anime, matchedTags: matched, fromTags: tags.isNotEmpty, clipScenes: _labels(scenes));
  }

  List<String> _labels(Map<String, int> scenes) {
    final keys = scenes.keys.where(_scenes.containsKey).toList()..sort((a, b) => scenes[b]!.compareTo(scenes[a]!));
    return [for (final k in keys) _scenes[k]!.label];
  }

  /// Alternativa quando o Last.fm não ajuda: nome da música, artista e o que o app já sabe (gênero, clima).
  VisualPlan fallback({String title = '', String artist = '', String genre = '', Mood? mood, Map<String, int> scenes = const {}}) {
    final fromInfo = <MusicTag>[
      if (genre.trim().isNotEmpty && normalize(genre) != 'desconhecido') MusicTag(genre, 100),
    ];
    final scored = fromInfo.isEmpty && mood == null && scenes.isEmpty ? null : _convertInfo(fromInfo, mood, scenes);
    final basic = <VisualQuery>[
      if (title.trim().isNotEmpty && artist.trim().isNotEmpty) VisualQuery('$title $artist', 'Música', 0.5),
      if (title.trim().isNotEmpty) VisualQuery('$title anime', 'Música', 0.4),
      if (artist.trim().isNotEmpty) VisualQuery('$artist aesthetic', 'Artista', 0.3),
    ];
    final seen = <String>{};
    final all = [...?scored?.all, ...basic].where((q) => seen.add(normalize(q.text))).toList();
    return VisualPlan(all: all, anime: scored?.anime ?? const [], matchedTags: const [], fromTags: false, clipScenes: _labels(scenes));
  }

  /// Gênero do app + clipe + clima, sem cair de novo na alternativa (evita voltar para cá).
  VisualPlan? _convertInfo(List<MusicTag> info, Mood? mood, Map<String, int> scenes) {
    final scores = scoreEntries(info, mood: mood, scenes: scenes);
    if (scores.isEmpty) return null;
    return convert(info.where((t) => scoreEntries([t]).isNotEmpty).toList(), mood: mood, scenes: scenes);
  }
}
