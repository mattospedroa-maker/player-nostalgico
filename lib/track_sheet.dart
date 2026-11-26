import 'dart:convert';
import 'dart:io';

import 'lyrics.dart' show LyricScene;
import 'models.dart';
import 'mood.dart';
import 'styles.dart';
import 'visual_tags.dart' show VisualTagMapper;

/// Uma "cena" da lista fixa do app: um momento em que a música combina (estrada, chuva, treino, faroeste...).
/// As playlists do momento são montadas em cima delas.
class SceneDef {
  final String key;
  final String label;
  final String emoji;

  /// Palavras (inglês e português) que denunciam a cena nas tags, no título, no álbum e na ficha da IA.
  final List<String> words;

  /// Estilos da lista fixa ([styleCatalog]) que costumam combinar.
  final List<String> styles;

  /// Cenas da letra ([LyricScene.key]) que contam a favor.
  final List<String> lyrics;

  /// Climas do selo que contam a favor.
  final List<Mood> moods;

  /// Caixa nas réguas (energia e humor, 0..100). null = qualquer lugar.
  final (int, int, int, int)? box;

  const SceneDef(this.key, this.label, this.emoji,
      {this.words = const [], this.styles = const [], this.lyrics = const [], this.moods = const [], this.box});

  bool inBox(Vibe v) {
    final b = box;
    return b != null && v.energy >= b.$1 && v.energy <= b.$2 && v.humor >= b.$3 && v.humor <= b.$4;
  }

  /// Quanto a música está fora da caixa (0 = dentro).
  int outside(Vibe v) {
    final b = box;
    if (b == null) return 0;
    int d(int x, int lo, int hi) => x < lo ? lo - x : (x > hi ? x - hi : 0);
    return d(v.energy, b.$1, b.$2) + d(v.humor, b.$3, b.$4);
  }
}

/// Lista fixa de cenas. A chave nunca muda (fica gravada na ficha e nas edições).
const List<SceneDef> sceneCatalog = [
  SceneDef('guerra', 'guerra', '⚔️',
      words: ['war', 'battle', 'warrior', 'warriors', 'army', 'viking', 'march', 'guerra', 'batalha', 'battlefield', 'fight', 'conquest'],
      styles: ['Symphonic Metal', 'Metal', 'Thrash Metal', 'Death Metal', 'Industrial', 'Hard Rock', 'Soundtrack'],
      lyrics: ['war'], moods: [Mood.epico, Mood.acao], box: (65, 100, 0, 60)),
  SceneDef('treino', 'treino', '🏋️',
      words: ['workout', 'gym', 'training', 'running', 'pump', 'motivation', 'motivational', 'treino', 'academia', 'energetic'],
      styles: ['EDM', 'Trap', 'Nu Metal', 'Metalcore', 'Hard Rock', 'Hip Hop', 'Dance', 'Funk Brasileiro'],
      moods: [Mood.acao, Mood.festa], box: (70, 100, 25, 100)),
  SceneDef('estrada', 'estrada', '🛣️',
      words: ['road', 'highway', 'driving', 'drive', 'road trip', 'roadtrip', 'estrada', 'route 66', 'travel', 'viagem', 'cruising'],
      styles: ['Classic Rock', 'Synthwave', 'Country', 'Indie Rock', 'Pop Rock', 'Hard Rock'],
      lyrics: ['car'], box: (45, 85, 40, 90)),
  SceneDef('madrugada', 'dirigindo de madrugada', '🌙',
      words: ['night drive', 'nightdrive', 'midnight', 'late night', 'madrugada', 'nocturnal', 'night'],
      styles: ['Synthwave', 'Darkwave', 'Chillwave', 'Coldwave', 'Cloud Rap', 'Post-Punk', 'Synthpop'],
      lyrics: ['night', 'city'], box: (30, 70, 10, 55)),
  SceneDef('chuva', 'dia de chuva', '🌧️',
      words: ['rain', 'rainy', 'rainy day', 'storm', 'chuva', 'grey', 'gloomy', 'melancholic', 'melancholy'],
      styles: ['Slowcore', 'Dream Pop', 'Shoegaze', 'Lo-Fi', 'Indie Folk', 'Sad Pop', 'Post-Rock'],
      lyrics: ['rain'], moods: [Mood.triste, Mood.calmo], box: (0, 45, 0, 50)),
  SceneDef('parque', 'caminhada no parque', '🌳',
      words: ['walk', 'walking', 'park', 'sunny', 'spring', 'sunshine', 'feel good', 'happy', 'caminhada', 'parque', 'primavera'],
      styles: ['Indie Pop', 'Indie Folk', 'Bossa Nova', 'Folk', 'Bedroom Pop', 'MPB', 'Britpop'],
      moods: [Mood.calmo, Mood.romantico], box: (30, 65, 55, 100)),
  SceneDef('praia', 'praia e verão', '🏖️',
      words: ['summer', 'beach', 'surf', 'tropical', 'sun', 'verão', 'verao', 'praia', 'island', 'ocean', 'sea'],
      styles: ['Reggae', 'Bossa Nova', 'Reggaeton', 'Samba', 'Chillwave', 'Pop', 'Forró'],
      lyrics: ['ocean'], moods: [Mood.festa], box: (40, 85, 60, 100)),
  SceneDef('festa', 'festa', '🎉',
      words: ['party', 'dance', 'club', 'festa', 'balada', 'dancefloor', 'disco', 'banger'],
      styles: ['Dance', 'EDM', 'House', 'Funk Brasileiro', 'Reggaeton', 'K-Pop', 'Pop', 'Funk', 'Techno'],
      moods: [Mood.festa], box: (65, 100, 55, 100)),
  SceneDef('foco', 'foco e estudo', '📚',
      words: ['study', 'studying', 'focus', 'concentration', 'instrumental', 'estudo', 'estudar', 'work', 'coding', 'piano'],
      styles: ['Lo-Fi', 'Chillhop', 'Ambient', 'Post-Rock', 'Classical', 'IDM', 'Jazz', 'Math Rock'],
      box: (10, 55, 30, 75)),
  SceneDef('dormir', 'para dormir', '😴',
      words: ['sleep', 'sleeping', 'lullaby', 'dormir', 'relaxing', 'calm', 'soft', 'quiet'],
      styles: ['Ambient', 'Lo-Fi', 'Slowcore', 'Classical', 'Dream Pop'],
      moods: [Mood.calmo], box: (0, 30, 25, 80)),
  SceneDef('saudade', 'saudade', '💭',
      words: ['nostalgia', 'nostalgic', 'memories', 'memory', 'saudade', 'lembrança', 'missing you', 'bittersweet', 'heartbreak'],
      styles: ['Sad Pop', 'Slowcore', 'Emo', 'Indie Folk', 'Ballad', 'MPB', 'Singer-Songwriter'],
      moods: [Mood.triste], box: (0, 50, 0, 50)),
  SceneDef('fossa', 'coração partido', '💔',
      words: ['breakup', 'break up', 'heartbreak', 'heartbroken', 'sad', 'crying', 'tears', 'sofrência', 'sofrencia', 'lonely', 'alone'],
      styles: ['Sad Pop', 'Emo', 'Sertanejo', 'Ballad', 'R&B', 'Slowcore'],
      moods: [Mood.triste], box: (0, 55, 0, 40)),
  SceneDef('romance', 'romance', '💗',
      words: ['love', 'romantic', 'romance', 'love song', 'amor', 'paixão', 'sensual', 'kiss', 'wedding'],
      styles: ['R&B', 'Soul', 'Bossa Nova', 'Ballad', 'Indie Pop', 'MPB', 'Dream Pop'],
      moods: [Mood.romantico], box: (15, 60, 50, 100)),
  SceneDef('raiva', 'pra descontar a raiva', '😤',
      words: ['angry', 'anger', 'rage', 'aggressive', 'raiva', 'hate', 'fuck', 'riot', 'scream'],
      styles: ['Hardcore', 'Metalcore', 'Nu Metal', 'Punk Rock', 'Thrash Metal', 'Post-Hardcore', 'Industrial', 'Noise Rock'],
      moods: [Mood.acao], box: (70, 100, 0, 35)),
  SceneDef('faroeste', 'faroeste', '🤠',
      words: ['western', 'spaghetti western', 'cowboy', 'cowboys', 'desert', 'outlaw', 'sheriff', 'gunfighter', 'duel', 'whistle',
          'whistling', 'faroeste', 'deserto', 'bang bang', 'wild west', 'red dead'],
      styles: ['Country', 'Soundtrack', 'Folk', 'Blues'], box: (20, 75, 15, 70)),
  SceneDef('cinema', 'trilha de filme', '🎬',
      words: ['soundtrack', 'ost', 'score', 'film score', 'movie', 'trilha sonora', 'cinematic', 'theme', 'original motion picture'],
      styles: ['Soundtrack', 'Classical', 'Post-Rock', 'Symphonic Metal', 'Ambient']),
  SceneDef('anime', 'abertura de anime', '🌸',
      words: ['anime', 'opening', 'ending', 'anisong', 'japanese', 'j-pop', 'jpop', 'vocaloid'],
      styles: ['Anime', 'J-Pop', 'J-Rock', 'Vocaloid']),
  SceneDef('game', 'trilha de videogame', '🎮',
      words: ['video game', 'videogame', 'game', 'gaming', 'chiptune', '8-bit', '8 bit', 'vgm', 'boss', 'level'],
      styles: ['Soundtrack', 'Electronic', 'IDM', 'Synthwave']),
  SceneDef('espaco', 'viagem pelo espaço', '🚀',
      words: ['space', 'cosmic', 'galaxy', 'stars', 'astronaut', 'universe', 'espaço', 'espaco', 'planet', 'moon', 'spacey', 'sci-fi'],
      styles: ['Space Rock', 'Ambient', 'Post-Rock', 'Psychedelic', 'Synthwave', 'Progressive Rock', 'Shoegaze'],
      box: (10, 70, 20, 70)),
  SceneDef('sonho', 'flutuando', '☁️',
      words: ['dreamy', 'ethereal', 'atmospheric', 'floating', 'dream', 'hazy', 'sonho', 'lush'],
      styles: ['Dream Pop', 'Shoegaze', 'Ethereal Wave', 'Chillwave', 'Ambient', 'Blackgaze'],
      box: (10, 60, 25, 70)),
  SceneDef('cidade', 'luzes da cidade', '🌃',
      words: ['city', 'urban', 'neon', 'downtown', 'city pop', 'cidade', 'metropolis', 'tokyo', 'street'],
      styles: ['Synthpop', 'Cloud Rap', 'Hip Hop', 'Synthwave', 'New Wave', 'R&B', 'House'],
      lyrics: ['city'], box: (35, 80, 25, 75)),
  SceneDef('inverno', 'frio e inverno', '❄️',
      words: ['winter', 'snow', 'cold', 'christmas', 'inverno', 'neve', 'frio', 'december'],
      styles: ['Post-Rock', 'Indie Folk', 'Slowcore', 'Black Metal', 'Ambient', 'Coldwave'],
      lyrics: ['snow'], box: (0, 55, 0, 60)),
  SceneDef('cafe', 'café da manhã', '☕',
      words: ['morning', 'coffee', 'breakfast', 'café', 'cafe', 'manhã', 'sunday', 'cozy', 'acoustic'],
      styles: ['Jazz', 'Bossa Nova', 'Indie Folk', 'Chillhop', 'Lo-Fi', 'Soul', 'MPB', 'Singer-Songwriter'],
      moods: [Mood.calmo], box: (15, 55, 45, 100)),
  SceneDef('sombrio', 'noite sombria', '🦇',
      words: ['dark', 'gothic', 'goth', 'haunting', 'creepy', 'horror', 'occult', 'sombrio', 'witch', 'vampire', 'halloween'],
      styles: ['Gothic Rock', 'Darkwave', 'Post-Punk', 'Black Metal', 'Doom', 'Coldwave', 'Industrial'],
      box: (20, 80, 0, 30)),
  SceneDef('aventura', 'aventura épica', '🏔️',
      words: ['epic', 'adventure', 'heroic', 'triumphant', 'orchestral', 'aventura', 'journey', 'quest', 'fantasy'],
      styles: ['Symphonic Metal', 'Soundtrack', 'Post-Rock', 'Progressive Rock', 'Classical'],
      moods: [Mood.epico], box: (55, 100, 40, 90)),
  SceneDef('pirata', 'mar e piratas', '🏴‍☠️',
      words: ['pirate', 'pirates', 'sea shanty', 'shanty', 'sailor', 'ship', 'navio', 'pirata', 'folk metal', 'celtic'],
      styles: ['Folk', 'Symphonic Metal', 'Soundtrack'], lyrics: ['ocean']),
  SceneDef('retro80', 'volta aos anos 80', '📼',
      words: ['80s', '1980s', 'eighties', 'retro', 'synth', 'new wave', 'anos 80'],
      styles: ['New Wave', 'Synthpop', 'Synthwave', 'Post-Punk', 'Classic Rock', 'Rock Russo']),
  SceneDef('retro2000', 'adolescência nos anos 2000', '💿',
      words: ['00s', '2000s', 'emo', 'pop punk', 'y2k', 'anos 2000', 'nu metal', 'post grunge'],
      styles: ['Pop Punk', 'Emo', 'Nu Metal', 'Post-Grunge', 'Post-Hardcore', 'Alternative Rock', 'Britpop']),
  SceneDef('brasil', 'roda de amigos', '🇧🇷',
      words: ['brazil', 'brazilian', 'brasil', 'samba', 'pagode', 'mpb', 'forró', 'roda'],
      styles: ['Samba', 'MPB', 'Bossa Nova', 'Forró', 'Sertanejo', 'Funk Brasileiro']),
  SceneDef('psicodelia', 'viagem psicodélica', '🌀',
      words: ['psychedelic', 'psych', 'trippy', 'acid', 'lsd', 'kaleidoscope', 'psicodélico'],
      styles: ['Psychedelic', 'Space Rock', 'Progressive Rock', 'Shoegaze', 'Experimental', 'Noise Pop']),
  SceneDef('jantar', 'jantar à luz de velas', '🕯️',
      words: ['jazz', 'smooth', 'lounge', 'candle', 'dinner', 'elegant', 'crooner', 'velvet'],
      styles: ['Jazz', 'Soul', 'Bossa Nova', 'Blues', 'R&B'], box: (10, 50, 40, 90)),
  SceneDef('limpeza', 'faxina animada', '🧹',
      words: ['singalong', 'sing along', 'catchy', 'upbeat', 'fun'],
      styles: ['Pop', 'Pop Rock', 'Dance', 'Funk', 'Indie Pop', 'Pop Punk', 'K-Pop'], box: (60, 100, 60, 100)),
  SceneDef('reflexao', 'pensando na vida', '🪟',
      words: ['introspective', 'thoughtful', 'existential', 'philosophical', 'melancholic', 'contemplative', 'lonely'],
      styles: ['Slowcore', 'Post-Rock', 'Singer-Songwriter', 'Indie Folk', 'Ambient', 'Cloud Rap'], box: (0, 50, 10, 55)),
  SceneDef('fim', 'fim do mundo', '☄️',
      words: ['apocalypse', 'apocalyptic', 'end of the world', 'doom', 'fim do mundo', 'armageddon', 'post apocalyptic'],
      styles: ['Doom', 'Post-Rock', 'Blackgaze', 'Industrial', 'Black Metal', 'Drone']),
];

/// O que a IA sabe da música (pedido uma vez só, em lotes, e guardado em `track_facts.json`).
class AiFacts {
  /// Cenas da lista fixa que a IA escolheu (chaves de [sceneCatalog]).
  final List<String> scenes;

  /// Do que a letra fala (em português, curtinho).
  final List<String> topics;

  /// Som marcante (assobio, violino, sintetizador...).
  final List<String> sound;

  /// "Parece trilha de..." (filme de faroeste, jogo de corrida...).
  final List<String> like;
  final String country;
  final String language;

  const AiFacts({
    this.scenes = const [],
    this.topics = const [],
    this.sound = const [],
    this.like = const [],
    this.country = '',
    this.language = '',
  });

  static const empty = AiFacts();

  bool get isEmpty => scenes.isEmpty && topics.isEmpty && sound.isEmpty && like.isEmpty && country.isEmpty && language.isEmpty;

  static List<String> _list(Object? v, {int max = 5, int maxLen = 40}) {
    final out = <String>[];
    if (v is! List) return out;
    for (final x in v) {
      var s = '$x'.trim().toLowerCase();
      if (s.isEmpty) continue;
      if (s.length > maxLen) s = s.substring(0, maxLen);
      if (!out.contains(s)) out.add(s);
      if (out.length >= max) break;
    }
    return out;
  }

  static String _str(Object? v) {
    final s = (v is String ? v : '').trim();
    return s.length > 30 ? s.substring(0, 30) : s;
  }

  /// Lê o que a IA devolveu (ou o que ficou gravado). Cenas fora da lista fixa são ignoradas.
  static AiFacts fromJson(Map<String, dynamic> m) => AiFacts(
        scenes: [for (final s in _list(m['scenes'], max: 6)) if (TrackSheet.sceneByKey.containsKey(s)) s],
        topics: _list(m['topics']),
        sound: _list(m['sound'], max: 4),
        like: _list(m['like'], max: 3, maxLen: 50),
        country: _str(m['country']),
        language: _str(m['language']),
      );

  Map<String, dynamic> toJson() => {
        if (scenes.isNotEmpty) 'scenes': scenes,
        if (topics.isNotEmpty) 'topics': topics,
        if (sound.isNotEmpty) 'sound': sound,
        if (like.isNotEmpty) 'like': like,
        if (country.isNotEmpty) 'country': country,
        if (language.isNotEmpty) 'language': language,
      };
}

/// Ficha de cada música guardada num arquivo só (`track_facts.json` na pasta de dados do app):
/// o que a IA disse e as cenas postas/tiradas à mão. Chave = artista|título (sobrevive a mudar de pasta).
/// Cerca de 200 bytes por música.
class TrackFactsStore {
  final File file;
  Map<String, AiFacts> _ai = {};
  Map<String, String> _edits = {};
  bool _loaded = false;

  TrackFactsStore(String dataDir) : file = File('$dataDir${Platform.pathSeparator}track_facts.json');

  static String key(Track t) => '${t.artist.trim().toLowerCase()}|${t.title.trim().toLowerCase()}';

  void load() {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!file.existsSync()) return;
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final ai = (raw['ai'] as Map?)?.cast<String, dynamic>() ?? const {};
      _ai = ai.map((k, v) => MapEntry(k, AiFacts.fromJson((v as Map).cast<String, dynamic>())));
      _edits = ((raw['edits'] as Map?)?.cast<String, dynamic>() ?? const {}).map((k, v) => MapEntry(k, '$v'));
    } catch (_) {
      _ai = {};
      _edits = {};
    }
  }

  /// null = a IA ainda não leu; vazio = leu e não sabia nada.
  AiFacts? ai(Track t) {
    load();
    return _ai[key(t)];
  }

  bool hasAi(Track t) => ai(t) != null;

  void putAi(Track t, AiFacts f) {
    load();
    _ai[key(t)] = f;
  }

  /// Cenas postas/tiradas à mão na aba "Momentos" ("+a|-b", igual aos estilos).
  StyleEdits edits(Track t) {
    load();
    return StyleEdits.parse(_edits[key(t)] ?? '');
  }

  void putEdits(Track t, StyleEdits e) {
    load();
    final enc = e.encode();
    if (enc.isEmpty) {
      _edits.remove(key(t));
    } else {
      _edits[key(t)] = enc;
    }
  }

  int get aiCount {
    load();
    return _ai.length;
  }

  Future<void> save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'ai': _ai.map((k, v) => MapEntry(k, v.toJson())),
      'edits': _edits,
    }));
    await tmp.rename(file.path);
  }
}

/// Quando você costuma ouvir cada música (vem do histórico, em uma consulta agrupada).
class ListeningHabits {
  /// Por música: plays até o fim em [madrugada, manhã, tarde, noite] e no fim de semana.
  final Map<int, List<int>> byTrack;
  const ListeningHabits(this.byTrack);
  static const empty = ListeningHabits({});

  static const parts = ['madrugada', 'manhã', 'tarde', 'noite'];

  /// Período do dia (0..3) para uma hora.
  static int partOf(int hour) => hour < 6 ? 0 : (hour < 12 ? 1 : (hour < 18 ? 2 : 3));

  /// Etiquetas: o período em que ela toca pelo menos metade das vezes e "fim de semana" quando
  /// passa de 60% (precisa de 3 plays ou mais para dizer alguma coisa).
  List<String> labelsFor(int? id) {
    final c = id == null ? null : byTrack[id];
    if (c == null) return const [];
    final total = c[0] + c[1] + c[2] + c[3];
    if (total < 3) return const [];
    final out = <String>[];
    for (var i = 0; i < 4; i++) {
      if (c[i] * 2 >= total) out.add(parts[i]);
    }
    if (c[4] * 10 >= total * 6) out.add('fim de semana');
    return out;
  }

  /// Período do dia em que a música mais toca, ou null.
  int? mainPart(int? id) {
    final c = id == null ? null : byTrack[id];
    if (c == null) return null;
    final total = c[0] + c[1] + c[2] + c[3];
    if (total < 3) return null;
    var best = 0;
    for (var i = 1; i < 4; i++) {
      if (c[i] > c[best]) best = i;
    }
    return c[best] * 2 >= total ? best : null;
  }
}

/// A ficha de uma música, montada na hora: cenas, letra, som, "parece trilha de", hábitos, época.
class Sheet {
  /// Cenas da música (as melhores primeiro) com os pontos de cada uma.
  final List<(SceneDef, double)> scenes;
  final List<String> topics;
  final List<String> sound;
  final List<String> like;
  final List<String> habits;
  final List<String> origin;

  /// A IA já leu esta música?
  final bool aiRead;
  const Sheet(this.scenes, this.topics, this.sound, this.like, this.habits, this.origin, {this.aiRead = false});

  List<String> get sceneKeys => [for (final (s, _) in scenes) s.key];
}

/// Monta a ficha de cada música juntando o que o app já tem (estilos, réguas, tags, BPM, cenas da letra,
/// título e álbum), o que a IA disse e o seu jeito de ouvir. Tudo em memória, guardado por objeto.
class TrackSheet {
  static const maxScenes = 6;

  /// Pontos mínimos para uma cena entrar na ficha.
  static const minScore = 1.4;

  static final Map<String, SceneDef> sceneByKey = {for (final s in sceneCatalog) s.key: s};

  /// Fontes (preenchidas pelo AppState; nos testes ficam vazias).
  static AiFacts? Function(Track t) aiOf = (_) => null;
  static StyleEdits Function(Track t) editsOf = (_) => StyleEdits.none;
  static List<LyricScene>? Function(Track t) lyricsOf = (_) => null;
  static ListeningHabits habits = ListeningHabits.empty;

  static Expando<Sheet> _cache = Expando();
  static void invalidate() => _cache = Expando();

  static final Map<String, RegExp> _wordRes = {};
  static RegExp _reFor(SceneDef s) => _wordRes[s.key] ??=
      RegExp('(^|[^a-z0-9])(${s.words.map((w) => RegExp.escape(VisualTagMapper.normalize(w))).join('|')})(\$|[^a-z0-9])');

  static Sheet of(Track t) => _cache[t] ??= build(t,
      ai: aiOf(t),
      edits: editsOf(t),
      lyricKeys: [for (final l in lyricsOf(t) ?? const <LyricScene>[]) l.key],
      habitLabels: habits.labelsFor(t.id));

  /// Cenas da música (só as chaves), na ordem.
  static List<String> scenesOf(Track t) => of(t).sceneKeys;

  /// Pontos de cada cena para a música (0 = nada). Função pura, testável.
  static Map<String, double> scoreScenes(
    Track t, {
    AiFacts? ai,
    List<String> lyricKeys = const [],
    List<String>? styles,
    Set<String>? tags,
    Vibe? vibe,
  }) {
    final st = styles ?? Styles.of(t);
    final tg = tags ?? Styles.soundTags(t);
    final v = vibe ?? Styles.vibeOf(t);
    final hasVibe = vibe != null || Styles.hasVibe(t);
    final mood = t.effectiveMood;
    final tagText = tg.map(VisualTagMapper.normalize).join(' · ');
    final nameText = VisualTagMapper.normalize('${t.title} · ${t.album == unknownAlbum ? '' : t.album}');
    final aiText = ai == null ? '' : VisualTagMapper.normalize([...ai.topics, ...ai.sound, ...ai.like].join(' · '));
    final out = <String, double>{};
    for (final s in sceneCatalog) {
      var score = 0.0;
      if (ai != null && ai.scenes.contains(s.key)) score += 2.0;
      if (s.lyrics.any(lyricKeys.contains)) score += 1.0;
      if (s.words.isNotEmpty) {
        final re = _reFor(s);
        final tagHits = re.allMatches(tagText).length;
        if (tagHits > 0) score += tagHits >= 2 ? 1.5 : 1.0;
        if (re.hasMatch(nameText)) score += .8;
        if (aiText.isNotEmpty && re.hasMatch(aiText)) score += .8;
      }
      for (var i = 0; i < st.length; i++) {
        if (s.styles.contains(st[i])) {
          score += i == 0 ? 1.0 : .6;
          break;
        }
      }
      if (mood != null && s.moods.contains(mood)) score += .4;
      if (hasVibe && s.box != null) {
        if (s.inBox(v)) {
          score += .6;
        } else if (s.outside(v) > 40) {
          score -= .8;
        }
      }
      if (score > 0) out[s.key] = score;
    }
    return out;
  }

  /// Ficha completa. Função pura (as fontes vêm por parâmetro).
  static Sheet build(Track t,
      {AiFacts? ai, StyleEdits edits = StyleEdits.none, List<String> lyricKeys = const [], List<String> habitLabels = const []}) {
    final scores = scoreScenes(t, ai: ai, lyricKeys: lyricKeys);
    final ranked = [
      for (final e in scores.entries)
        if (e.value >= minScore && !edits.removed.contains(e.key)) (sceneByKey[e.key]!, e.value)
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final scenes = <(SceneDef, double)>[
      for (final k in edits.added)
        if (sceneByKey[k] != null) (sceneByKey[k]!, 10.0),
    ];
    for (final r in ranked) {
      if (scenes.length >= maxScenes) break;
      if (!scenes.any((x) => x.$1.key == r.$1.key)) scenes.add(r);
    }
    // letra: o que a IA disse; sem IA, as cenas que o app já tirou da letra para os GIFs
    final topics = ai?.topics.isNotEmpty == true ? ai!.topics : [for (final k in lyricKeys) _lyricLabel[k] ?? k];
    final origin = <String>[
      if (t.year != null && t.year! > 1900) '${t.year}',
      if (ai != null && ai.country.isNotEmpty) ai.country,
      if (ai != null && ai.language.isNotEmpty) ai.language,
    ];
    return Sheet(scenes, topics, ai?.sound ?? const [], ai?.like ?? const [], habitLabels, origin, aiRead: ai != null);
  }

  static const _lyricLabel = {
    'rain': 'chuva',
    'car': 'estrada',
    'city': 'cidade',
    'ocean': 'mar',
    'night': 'noite',
    'war': 'guerra',
    'snow': 'neve',
  };

  // ---------- IA ----------

  /// Músicas por pedido à IA.
  static const batchSize = 40;

  /// Pedido para a IA preencher a ficha de um lote de músicas.
  static String prompt(List<Track> batch) {
    final b = StringBuffer()
      ..writeln('Você ajuda um player de música off-line a montar playlists temáticas ("para ir para a guerra", "caminhada no parque").')
      ..writeln('Para cada música abaixo, diga o que você sabe dela. Se não conhecer a música, deixe as listas vazias (não invente).')
      ..writeln()
      ..writeln('Responda só com JSON: {"tracks":[{"i":1,"scenes":[...],"topics":[...],"sound":[...],"like":[...],"country":"","language":""}]}')
      ..writeln('- "scenes": até 4 chaves desta lista (só estas): ${sceneCatalog.map((s) => '${s.key} (${s.label})').join(', ')}')
      ..writeln('- "topics": até 4 temas da letra, em português, 1 a 3 palavras cada (ex.: "duelo", "cidade pequena"). Instrumental: [].')
      ..writeln('- "sound": até 3 sons marcantes, em português (ex.: "assobio", "violino", "voz grave", "sintetizador").')
      ..writeln('- "like": até 2 "parece trilha de", em português (ex.: "filme de faroeste", "jogo de corrida"). Pode ficar vazio.')
      ..writeln('- "country": país do artista em português; "language": idioma da letra em português ("instrumental" se não tiver letra).')
      ..writeln()
      ..writeln('Músicas:');
    for (var i = 0; i < batch.length; i++) {
      final t = batch[i];
      final album = t.album == unknownAlbum ? '' : t.album;
      b.writeln('${i + 1}. ${t.artist} — ${t.title}${album.isNotEmpty ? ' (álbum: $album${t.year != null ? ', ${t.year}' : ''})' : ''}');
    }
    return b.toString();
  }

  /// Lê a resposta da IA: número da música (1..n) -> ficha. Itens estranhos são ignorados.
  static Map<int, AiFacts> parseAnswer(Map<String, dynamic> json, int count) {
    final out = <int, AiFacts>{};
    final list = json['tracks'];
    if (list is! List) return out;
    for (final item in list) {
      if (item is! Map) continue;
      final m = item.cast<String, dynamic>();
      final i = m['i'] is int ? m['i'] as int : int.tryParse('${m['i']}');
      if (i == null || i < 1 || i > count) continue;
      out[i - 1] = AiFacts.fromJson(m);
    }
    return out;
  }
}
