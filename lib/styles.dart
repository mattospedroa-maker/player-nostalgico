import 'lastfm.dart' show MusicTag;
import 'models.dart';

/// Um estilo da lista fixa do app: nome bonito, como ele aparece nas tags, família, vizinhos
/// e onde ele costuma ficar nas réguas de energia (calma 0 → agitada 100) e humor (sombrio 0 → alegre 100).
class StyleDef {
  final String name;
  final RegExp match;
  final String family;
  final List<String> neighbors;
  final int energy;
  final int humor;
  StyleDef(this.name, String pattern, this.family, this.neighbors, this.energy, this.humor)
      : match = RegExp('^(?:$pattern)\$');
}

/// Lista fixa de estilos (nomes unificados) e o mapa de estilos vizinhos.
/// "post punk", "Post-Punk" e "postpunk" viram uma coisa só: "Post-Punk".
final List<StyleDef> styleCatalog = [
  // --- etéreo / sonhador ---
  StyleDef('Shoegaze', r'shoe ?gaze|shoegazer|nu gaze', 'etereo', ['Dream Pop', 'Noise Pop', 'Slowcore', 'Post-Punk', 'Blackgaze', 'Ethereal Wave'], 45, 30),
  StyleDef('Dream Pop', r'dream ?pop|dreampop|dreamy pop', 'etereo', ['Shoegaze', 'Ethereal Wave', 'Indie Pop', 'Chillwave', 'Slowcore', 'Bedroom Pop'], 35, 45),
  StyleDef('Ethereal Wave', r'ethereal ?wave|ethereal|4ad', 'etereo', ['Dream Pop', 'Darkwave', 'Shoegaze', 'Gothic Rock'], 30, 35),
  StyleDef('Slowcore', r'slowcore|sadcore', 'etereo', ['Shoegaze', 'Dream Pop', 'Indie Folk', 'Post-Rock', 'Sad Pop'], 15, 15),
  StyleDef('Noise Pop', r'noise ?pop', 'etereo', ['Shoegaze', 'Indie Rock', 'Noise Rock'], 60, 50),
  StyleDef('Blackgaze', r'blackgaze|post black metal|post-black metal', 'etereo', ['Shoegaze', 'Black Metal', 'Post-Rock'], 75, 25),
  StyleDef('Chillwave', r'chillwave|glo ?fi', 'etereo', ['Dream Pop', 'Synthwave', 'Lo-Fi', 'Bedroom Pop'], 35, 60),
  StyleDef('Post-Rock', r'post ?rock', 'etereo', ['Slowcore', 'Ambient', 'Math Rock', 'Shoegaze', 'Blackgaze'], 45, 40),
  // --- sombrio / anos 80 ---
  StyleDef('Post-Punk', r'post ?punk|postpunk|post punk revival|russian post punk', 'sombrio', ['Darkwave', 'New Wave', 'Gothic Rock', 'Coldwave', 'Shoegaze', 'Indie Rock'], 60, 30),
  StyleDef('Darkwave', r'dark ?wave|darkwave', 'sombrio', ['Coldwave', 'Post-Punk', 'Gothic Rock', 'Synthpop', 'Ethereal Wave'], 50, 20),
  StyleDef('Coldwave', r'cold ?wave|minimal wave', 'sombrio', ['Darkwave', 'Post-Punk', 'Synthpop'], 55, 25),
  StyleDef('Gothic Rock', r'goth(ic)?( rock)?|deathrock', 'sombrio', ['Post-Punk', 'Darkwave', 'Ethereal Wave'], 55, 20),
  StyleDef('New Wave', r'new ?wave|new romantic', 'sombrio', ['Post-Punk', 'Synthpop', 'Pop Rock'], 65, 60),
  StyleDef('Synthpop', r'synth ?pop|electropop|electro pop', 'eletronica', ['New Wave', 'Darkwave', 'Indie Pop', 'Synthwave'], 65, 60),
  StyleDef('Rock Russo', r'russian rock|русский рок|rock russo|soviet rock', 'sombrio', ['Post-Punk', 'New Wave', 'Rock'], 60, 35),
  // --- indie / alternativo ---
  StyleDef('Indie Rock', r'indie ?rock', 'indie', ['Alternative Rock', 'Indie Pop', 'Post-Punk', 'Garage Rock', 'Noise Pop'], 65, 50),
  StyleDef('Indie Pop', r'indie ?pop|twee( pop)?', 'indie', ['Dream Pop', 'Indie Rock', 'Bedroom Pop', 'Synthpop'], 50, 65),
  StyleDef('Indie', r'indie|indie music', 'indie', ['Indie Rock', 'Indie Pop', 'Alternative'], 50, 50),
  StyleDef('Bedroom Pop', r'bedroom ?pop', 'indie', ['Indie Pop', 'Lo-Fi', 'Dream Pop', 'Chillwave'], 35, 50),
  StyleDef('Indie Folk', r'indie ?folk|folk ?pop|chamber folk', 'folk', ['Folk', 'Slowcore', 'Singer-Songwriter', 'Indie Pop'], 30, 45),
  StyleDef('Alternative', r'alternative|alternativo|alt', 'indie', ['Alternative Rock', 'Indie'], 60, 45),
  StyleDef('Alternative Rock', r'alternative ?rock|alt ?rock|rock alternativo', 'indie', ['Indie Rock', 'Grunge', 'Post-Grunge', 'Britpop'], 70, 40),
  StyleDef('Britpop', r'britpop|brit ?pop', 'indie', ['Alternative Rock', 'Indie Rock'], 65, 65),
  StyleDef('Grunge', r'grunge', 'rock', ['Alternative Rock', 'Post-Grunge', 'Punk Rock', 'Noise Rock'], 80, 25),
  StyleDef('Post-Grunge', r'post ?grunge', 'rock', ['Grunge', 'Alternative Rock', 'Hard Rock'], 75, 35),
  StyleDef('Noise Rock', r'noise ?rock|noise', 'rock', ['Noise Pop', 'Post-Punk', 'Grunge', 'Experimental'], 85, 25),
  StyleDef('Math Rock', r'math ?rock|midwest emo', 'rock', ['Post-Rock', 'Emo', 'Indie Rock'], 70, 50),
  StyleDef('Garage Rock', r'garage( rock)?|garage revival', 'rock', ['Indie Rock', 'Punk Rock', 'Rock'], 80, 60),
  StyleDef('Psychedelic', r'psychedelic( rock| pop)?|psych|neo ?psychedelia', 'rock', ['Indie Rock', 'Dream Pop', 'Space Rock', 'Classic Rock'], 55, 55),
  StyleDef('Space Rock', r'space ?rock', 'rock', ['Psychedelic', 'Shoegaze', 'Post-Rock'], 50, 40),
  StyleDef('Experimental', r'experimental|avant ?garde|art rock|art pop', 'rock', ['Noise Rock', 'Post-Rock', 'Ambient'], 50, 40),
  StyleDef('Lo-Fi', r'lo ?fi|lofi|lo fi hip hop|lofi hip hop', 'chill', ['Bedroom Pop', 'Chillhop', 'Chillwave'], 25, 50),
  // --- rock / metal / punk ---
  StyleDef('Rock', r'rock|rock nacional|brazilian rock|rock brasileiro', 'rock', ['Alternative Rock', 'Hard Rock', 'Classic Rock', 'Pop Rock'], 70, 50),
  StyleDef('Classic Rock', r'classic ?rock|70s rock', 'rock', ['Hard Rock', 'Psychedelic', 'Rock'], 70, 60),
  StyleDef('Hard Rock', r'hard ?rock|arena rock|glam rock|glam metal', 'rock', ['Classic Rock', 'Heavy Metal', 'Post-Grunge'], 85, 55),
  StyleDef('Pop Rock', r'pop ?rock|soft rock|power pop', 'pop', ['Pop', 'Rock', 'Pop Punk'], 65, 65),
  StyleDef('Punk Rock', r'punk( rock)?|hardcore punk|skate punk', 'punk', ['Pop Punk', 'Hardcore', 'Garage Rock', 'Post-Punk'], 90, 50),
  StyleDef('Pop Punk', r'pop ?punk|emo pop|neon pop punk', 'punk', ['Punk Rock', 'Emo', 'Pop Rock'], 85, 65),
  StyleDef('Emo', r'emo|emocore|screamo', 'punk', ['Pop Punk', 'Post-Hardcore', 'Math Rock'], 75, 25),
  StyleDef('Post-Hardcore', r'post ?hardcore', 'punk', ['Emo', 'Metalcore', 'Hardcore'], 85, 30),
  StyleDef('Hardcore', r'hardcore', 'punk', ['Punk Rock', 'Post-Hardcore', 'Metalcore'], 95, 30),
  StyleDef('Metalcore', r'metalcore|deathcore', 'metal', ['Post-Hardcore', 'Metal', 'Hardcore'], 95, 25),
  StyleDef('Nu Metal', r'nu ?metal|rap metal|rapcore', 'metal', ['Alternative Metal', 'Metal', 'Industrial'], 90, 25),
  StyleDef('Alternative Metal', r'alternative ?metal|alt metal', 'metal', ['Nu Metal', 'Metal', 'Hard Rock', 'Grunge'], 85, 30),
  StyleDef('Metal', r'metal|heavy ?metal|power metal|speed metal', 'metal', ['Hard Rock', 'Thrash Metal', 'Alternative Metal'], 90, 35),
  StyleDef('Thrash Metal', r'thrash( metal)?', 'metal', ['Metal', 'Death Metal'], 95, 25),
  StyleDef('Death Metal', r'death ?metal|melodic death metal|grindcore', 'metal', ['Thrash Metal', 'Black Metal', 'Metalcore'], 98, 10),
  StyleDef('Black Metal', r'black ?metal|depressive black metal|dsbm', 'metal', ['Death Metal', 'Blackgaze'], 90, 10),
  StyleDef('Doom', r'doom( metal)?|sludge( metal)?|stoner( rock| metal)?|drone( metal)?|drone', 'metal', ['Post-Rock', 'Metal', 'Slowcore'], 45, 15),
  StyleDef('Industrial', r'industrial( metal| rock)?|ebm', 'metal', ['Nu Metal', 'Darkwave', 'Electronic'], 85, 20),
  StyleDef('Symphonic Metal', r'symphonic ?metal|gothic metal|progressive metal|prog metal', 'metal', ['Metal', 'Progressive Rock'], 80, 40),
  StyleDef('Progressive Rock', r'progressive( rock)?|prog( rock)?', 'rock', ['Classic Rock', 'Psychedelic', 'Symphonic Metal'], 60, 50),
  // --- pop ---
  StyleDef('Pop', r'pop|mainstream pop|teen pop|dance pop', 'pop', ['Pop Rock', 'Synthpop', 'Dance', 'R&B'], 70, 75),
  StyleDef('Sad Pop', r'sad pop', 'pop', ['Pop', 'Slowcore', 'Indie Pop'], 30, 15),
  StyleDef('Ballad', r'ballad|power ballad|balada', 'pop', ['Pop', 'Soul', 'Singer-Songwriter'], 25, 40),
  StyleDef('K-Pop', r'k ?pop|kpop|korean', 'asia', ['J-Pop', 'Pop', 'Dance'], 80, 80),
  StyleDef('J-Pop', r'j ?pop|jpop|japanese pop|city pop', 'asia', ['J-Rock', 'Anime', 'K-Pop', 'Vocaloid'], 70, 75),
  StyleDef('J-Rock', r'j ?rock|jrock|japanese rock|visual kei', 'asia', ['J-Pop', 'Anime', 'Alternative Rock'], 80, 55),
  StyleDef('Anime', r'anime|anime ?(op|ed|opening|ending|soundtrack)|anisong', 'asia', ['J-Pop', 'J-Rock', 'Soundtrack', 'Vocaloid'], 75, 65),
  StyleDef('Vocaloid', r'vocaloid|utaite|hatsune miku', 'asia', ['J-Pop', 'Anime', 'Electronic'], 75, 70),
  // --- eletrônica ---
  StyleDef('Electronic', r'electronic|electronica|electro|eletronica|eletrônica', 'eletronica', ['House', 'Synthpop', 'IDM', 'Ambient'], 70, 55),
  StyleDef('House', r'(deep |french |tech |progressive )?house', 'eletronica', ['Dance', 'Techno', 'Electronic'], 80, 75),
  StyleDef('Techno', r'techno|minimal techno', 'eletronica', ['House', 'Industrial', 'Trance'], 85, 40),
  StyleDef('Trance', r'trance|psytrance', 'eletronica', ['Techno', 'EDM'], 85, 65),
  StyleDef('EDM', r'edm|big room|electro house|future bass|dubstep|brostep|drum and bass|dnb|drum n bass', 'eletronica', ['Dance', 'House', 'Trance'], 92, 70),
  StyleDef('Dance', r'dance|eurodance|disco|nu disco', 'eletronica', ['Pop', 'House', 'EDM', 'Funk'], 85, 85),
  StyleDef('Synthwave', r'synthwave|retrowave|outrun|vaporwave', 'eletronica', ['Synthpop', 'Chillwave', 'Darkwave'], 60, 50),
  StyleDef('IDM', r'idm|glitch|downtempo|trip ?hop', 'eletronica', ['Electronic', 'Ambient', 'Chillhop'], 40, 35),
  StyleDef('Ambient', r'ambient|dark ambient|new age|drone ambient', 'chill', ['Post-Rock', 'IDM', 'Classical', 'Lo-Fi'], 10, 45),
  StyleDef('Chillhop', r'chillhop|jazzhop|jazz hop|chill ?out|chill', 'chill', ['Lo-Fi', 'IDM', 'Jazz'], 25, 60),
  // --- hip hop / black music ---
  StyleDef('Hip Hop', r'hip ?hop|hiphop|rap|underground hip hop|boom bap', 'hiphop', ['Trap', 'R&B', 'Cloud Rap'], 70, 50),
  StyleDef('Trap', r'trap|drill|phonk', 'hiphop', ['Hip Hop', 'Cloud Rap'], 80, 40),
  StyleDef('Cloud Rap', r'cloud ?rap|emo rap|sad rap', 'hiphop', ['Trap', 'Hip Hop', 'Lo-Fi'], 45, 25),
  StyleDef('R&B', r'r ?& ?b|rnb|r and b|contemporary r&b|neo soul', 'soul', ['Soul', 'Pop', 'Hip Hop'], 50, 60),
  StyleDef('Soul', r'soul|motown|northern soul', 'soul', ['R&B', 'Funk', 'Jazz', 'Blues'], 55, 70),
  StyleDef('Funk', r'funk|p ?funk|boogie', 'soul', ['Soul', 'Dance', 'Disco'], 80, 85),
  StyleDef('Jazz', r'jazz|smooth jazz|bebop|jazz fusion|vocal jazz', 'jazz', ['Blues', 'Soul', 'Bossa Nova', 'Chillhop'], 40, 60),
  StyleDef('Blues', r'blues|blues rock|delta blues', 'jazz', ['Jazz', 'Classic Rock', 'Soul'], 45, 35),
  // --- folk / acústico / clássico ---
  StyleDef('Folk', r'folk|folk rock|americana|traditional folk', 'folk', ['Indie Folk', 'Singer-Songwriter', 'Country'], 35, 55),
  StyleDef('Singer-Songwriter', r'singer ?songwriter|cantautor|acoustic|acustico|acústico', 'folk', ['Folk', 'Indie Folk', 'Ballad'], 25, 50),
  StyleDef('Country', r'country|bluegrass|alt country', 'folk', ['Folk', 'Rock'], 55, 65),
  StyleDef('Classical', r'classical|classica|clássica|orchestral|neoclassical|modern classical|baroque|opera', 'erudito', ['Soundtrack', 'Ambient'], 25, 50),
  StyleDef('Soundtrack', r'soundtrack|ost|score|trilha sonora|film score|video game music|game music|vgm', 'erudito', ['Classical', 'Anime', 'Ambient'], 50, 50),
  // --- Brasil / latino ---
  StyleDef('MPB', r'mpb|musica popular brasileira|música popular brasileira|tropicalia|tropicália', 'brasil', ['Bossa Nova', 'Samba', 'Folk'], 40, 65),
  StyleDef('Bossa Nova', r'bossa ?nova|bossa', 'brasil', ['MPB', 'Jazz', 'Samba'], 30, 65),
  StyleDef('Samba', r'samba|pagode|samba rock', 'brasil', ['MPB', 'Bossa Nova', 'Funk Brasileiro'], 70, 85),
  StyleDef('Sertanejo', r'sertanejo|sertanejo universitario|sertanejo universitário|modao|modão', 'brasil', ['Forró', 'Country'], 60, 65),
  StyleDef('Forró', r'forro|forró|piseiro|arrocha|axe|axé', 'brasil', ['Sertanejo', 'Samba'], 80, 85),
  StyleDef('Funk Brasileiro', r'funk carioca|baile funk|funk brasileiro|funk ostentacao|brazilian funk', 'brasil', ['Trap', 'Dance', 'Samba'], 90, 80),
  StyleDef('Reggae', r'reggae|ska|dub|dancehall', 'latino', ['Reggaeton', 'Funk'], 55, 75),
  StyleDef('Reggaeton', r'reggaeton|latin( pop)?|cumbia|salsa|bachata', 'latino', ['Reggae', 'Pop', 'Dance'], 80, 80),
  StyleDef('Gospel', r'gospel|christian|worship|louvor', 'soul', ['Soul', 'Pop'], 50, 75),
];

/// Uma família parecida vale menos que um vizinho direto.
const Map<String, List<String>> _familyNeighbors = {
  'etereo': ['sombrio', 'indie', 'chill'],
  'sombrio': ['etereo', 'indie', 'eletronica'],
  'indie': ['etereo', 'rock', 'sombrio', 'folk'],
  'rock': ['indie', 'metal', 'punk'],
  'punk': ['rock', 'metal'],
  'metal': ['rock', 'punk'],
  'pop': ['eletronica', 'asia', 'soul'],
  'eletronica': ['pop', 'chill', 'sombrio'],
  'chill': ['eletronica', 'etereo', 'jazz'],
  'hiphop': ['soul', 'eletronica'],
  'soul': ['hiphop', 'jazz', 'pop'],
  'jazz': ['soul', 'chill', 'brasil'],
  'folk': ['indie', 'erudito'],
  'erudito': ['folk', 'chill'],
  'asia': ['pop', 'rock'],
  'brasil': ['latino', 'jazz'],
  'latino': ['brasil', 'pop'],
};

/// Mudanças feitas à mão na aba "Estilo" (estilos postos e tirados), guardadas no banco como "+A|-B".
class StyleEdits {
  final Set<String> added;
  final Set<String> removed;
  const StyleEdits(this.added, this.removed);
  static const none = StyleEdits({}, {});

  bool get isEmpty => added.isEmpty && removed.isEmpty;

  static StyleEdits parse(String raw) {
    if (raw.isEmpty) return none;
    final a = <String>{}, r = <String>{};
    for (final part in raw.split('|')) {
      if (part.length < 2) continue;
      (part[0] == '-' ? r : a).add(part.substring(1));
    }
    return StyleEdits(a, r);
  }

  String encode() => [for (final s in added) '+$s', for (final s in removed) '-$s'].join('|');
}

/// Energia e humor de 0 a 100 (as duas réguas). [manual] = arrastadas à mão na aba "Estilo".
class Vibe {
  final int energy;
  final int humor;
  final bool manual;
  const Vibe(this.energy, this.humor, {this.manual = false});

  /// Distância entre duas músicas nas réguas (0 = igual, ~141 = opostas).
  double distanceTo(Vibe o) {
    final de = (energy - o.energy).toDouble(), dh = (humor - o.humor).toDouble();
    return _sqrt(de * de + dh * dh);
  }

  static double _sqrt(double x) {
    if (x <= 0) return 0;
    var r = x / 2;
    for (var i = 0; i < 12; i++) {
      r = (r + x / r) / 2;
    }
    return r;
  }

  @override
  String toString() => 'Vibe($energy, $humor${manual ? ', manual' : ''})';
}

/// Estilos de cada música (até 5) e as réguas, tudo calculado na hora e guardado por objeto.
///
/// Pistas, da mais forte para a mais fraca: tags do Last.fm da própria música, tags do artista
/// (buscadas uma vez por artista), o gênero do arquivo. As mudanças à mão na aba "Estilo" valem por cima.
class Styles {
  static const maxPerTrack = 5;

  /// Tags do Last.fm guardadas para a música (preenchido pelo AppState).
  static List<MusicTag>? Function(Track t) trackTags = (_) => null;

  /// Tags do Last.fm guardadas para o artista (preenchido pelo AppState).
  static List<MusicTag>? Function(String artist) artistTags = (_) => null;

  /// Pares de estilos aprendidos com as suas playlists (0..1). Preenchido por [StyleLearning].
  static double Function(String a, String b) learnedPair = (_, _) => 0;

  static final Map<String, StyleDef> byName = {for (final s in styleCatalog) s.name: s};
  static final Map<String, StyleDef?> _tagCache = {};
  static Expando<List<String>> _cache = Expando();
  static Expando<Vibe> _vibeCache = Expando();

  /// Esquece os resultados guardados (tags novas chegaram, edições mudaram, biblioteca relida).
  static void invalidate() {
    _cache = Expando();
    _vibeCache = Expando();
  }

  static String normalize(String tag) => tag
      .toLowerCase()
      .replaceAll(RegExp(r'[-_/.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Estilo da lista fixa que corresponde a uma tag ou gênero ("post punk" -> Post-Punk), ou null.
  static StyleDef? styleOf(String tagOrGenre) {
    final n = normalize(tagOrGenre);
    if (n.isEmpty) return null;
    if (_tagCache.containsKey(n)) return _tagCache[n];
    if (_tagCache.length > 3000) _tagCache.clear();
    StyleDef? found;
    for (final s in styleCatalog) {
      if (s.match.hasMatch(n)) {
        found = s;
        break;
      }
    }
    return _tagCache[n] = found;
  }

  /// Estilos automáticos (sem as edições), do mais forte para o mais fraco. Função pura, testável.
  static List<String> auto({String genre = '', List<MusicTag> tags = const [], List<MusicTag> artistTags = const []}) {
    final score = <String, double>{};
    void addTags(List<MusicTag> list, double weight) {
      if (list.isEmpty) return;
      final maxCount = list.fold<int>(1, (m, t) => t.count > m ? t.count : m);
      for (final t in list) {
        final s = styleOf(t.name);
        if (s == null) continue;
        // tags fracas ainda valem um mínimo (no Last.fm a contagem cai rápido)
        final w = weight * (.35 + .65 * (t.count <= 0 ? .3 : t.count / maxCount));
        score.update(s.name, (v) => v + w, ifAbsent: () => w);
      }
    }

    addTags(tags, 1);
    addTags(artistTags, tags.isEmpty ? .9 : .5);
    for (final part in genre.split(RegExp(r'[;,/]'))) {
      final s = styleOf(part);
      if (s != null) score.update(s.name, (v) => v + .8, ifAbsent: () => .8);
    }
    // estilos "guarda-chuva" (Rock, Indie, Pop...) só entram se não houver outros mais específicos suficientes
    const umbrella = {'Rock', 'Indie', 'Alternative', 'Pop', 'Electronic', 'Metal', 'Hip Hop'};
    final ranked = score.entries.toList()
      ..sort((a, b) {
        final ua = umbrella.contains(a.key) ? 1 : 0, ub = umbrella.contains(b.key) ? 1 : 0;
        if (ua != ub) return ua - ub;
        return b.value.compareTo(a.value);
      });
    final best = ranked.isEmpty ? 0.0 : ranked.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    return [
      for (final e in ranked)
        if (e.value >= best * .2) e.key
    ].take(maxPerTrack).toList();
  }

  /// Estilos da música (automáticos + edições da aba "Estilo").
  static List<String> of(Track t) => _cache[t] ??= _compute(t);

  static List<String> _compute(Track t) {
    final edits = StyleEdits.parse(t.stylesEdit);
    final autoList = auto(genre: t.genre, tags: trackTags(t) ?? const [], artistTags: artistTags(t.artist) ?? const []);
    final out = <String>[...edits.added.where(byName.containsKey)];
    for (final s in autoList) {
      if (!edits.removed.contains(s) && !out.contains(s)) out.add(s);
    }
    return out.take(maxPerTrack).toList();
  }

  /// Parecença entre dois estilos: igual 1; vizinho direto .6; mesma família .35; famílias vizinhas .15.
  /// Os pares que aparecem juntos nas suas playlists ganham até +.4.
  static double similarity(String a, String b) {
    if (a == b) return 1;
    final da = byName[a], db = byName[b];
    if (da == null || db == null) return 0;
    var s = 0.0;
    if (da.neighbors.contains(b) || db.neighbors.contains(a)) {
      s = .6;
    } else if (da.family == db.family) {
      s = .35;
    } else if (_familyNeighbors[da.family]?.contains(db.family) ?? false) {
      s = .15;
    }
    final l = learnedPair(a, b);
    if (l > 0) s += .4 * l;
    return s > 1 ? 1 : s;
  }

  /// Parecença entre duas listas de estilos (0..1): para cada estilo de [a], o melhor par em [b].
  static double listSimilarity(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var sum = 0.0;
    for (final x in a) {
      var best = 0.0;
      for (final y in b) {
        final s = similarity(x, y);
        if (s > best) best = s;
      }
      sum += best;
    }
    return sum / a.length;
  }

  /// Os estilos vizinhos dos estilos da música (para a aba "Estilo").
  static List<String> neighborsOf(List<String> styles) {
    final out = <String>[];
    for (final s in styles) {
      for (final n in byName[s]?.neighbors ?? const <String>[]) {
        if (!styles.contains(n) && !out.contains(n)) out.add(n);
      }
    }
    return out;
  }

  // ---------- réguas ----------

  /// Pistas de clima nas tags: quanto mexem em energia (e) e humor (h).
  static const _vibeWords = <String, (int, int)>{
    'sad': (-10, -35), 'sadness': (-10, -35), 'melancholic': (-10, -30), 'melancholy': (-10, -30), 'depressing': (-15, -40),
    'depressive': (-15, -40), 'heartbreak': (-5, -30), 'lonely': (-10, -30), 'dark': (0, -30), 'gloomy': (-10, -30),
    'happy': (10, 35), 'feel good': (10, 35), 'upbeat': (20, 25), 'fun': (15, 30), 'uplifting': (10, 30), 'summer': (10, 25),
    'energetic': (30, 10), 'aggressive': (35, -15), 'angry': (30, -25), 'intense': (25, -5), 'heavy': (25, -10), 'party': (30, 30),
    'chill': (-25, 10), 'chillout': (-25, 10), 'relaxing': (-30, 10), 'calm': (-30, 5), 'mellow': (-25, 5), 'sleep': (-35, 0),
    'dreamy': (-15, 5), 'atmospheric': (-15, -5), 'ethereal': (-15, 0), 'beautiful': (-5, 10), 'romantic': (-10, 20), 'love': (-5, 20),
    'epic': (25, 10), 'nostalgic': (-10, -5), 'introspective': (-15, -15), 'haunting': (-10, -25), 'slow': (-25, -5), 'fast': (25, 5),
  };

  /// Réguas automáticas. Função pura (testável). [bpm] null = sem andamento.
  static Vibe autoVibe({List<String> styles = const [], List<MusicTag> tags = const [], int? bpm, String title = ''}) {
    double e = 50, h = 50;
    // 1. estilos (o primeiro pesa mais)
    if (styles.isNotEmpty) {
      double se = 0, sh = 0, sw = 0;
      for (var i = 0; i < styles.length; i++) {
        final d = byName[styles[i]];
        if (d == null) continue;
        final w = i == 0 ? 1.5 : 1.0;
        se += d.energy * w;
        sh += d.humor * w;
        sw += w;
      }
      if (sw > 0) {
        e = se / sw;
        h = sh / sw;
      }
    }
    // 2. palavras de clima nas tags
    if (tags.isNotEmpty) {
      double de = 0, dh = 0;
      var hits = 0;
      for (final t in tags.take(15)) {
        final v = _vibeWords[normalize(t.name)];
        if (v == null) continue;
        de += v.$1;
        dh += v.$2;
        hits++;
      }
      if (hits > 0) {
        e += de / hits;
        h += dh / hits;
      }
    }
    // 3. andamento: lento puxa para calma, rápido para agitada
    if (bpm != null && bpm > 40 && bpm < 220) {
      final fromBpm = ((bpm - 60) / 120 * 100).clamp(0, 100).toDouble();
      e = e * .7 + fromBpm * .3;
    }
    // 4. título
    final tl = title.toLowerCase();
    if (RegExp(r'acoustic|ac[uú]stic|slowed|piano|lullaby|unplugged').hasMatch(tl)) e -= 15;
    if (RegExp(r'remix|club mix|extended mix|sped up|nightcore').hasMatch(tl)) e += 15;
    return Vibe(e.round().clamp(0, 100), h.round().clamp(0, 100));
  }

  /// A música tem alguma pista para as réguas? Sem nenhuma, elas ficam no meio e não dizem nada.
  static bool hasVibe(Track t) =>
      (t.energy != null && t.humor != null) || t.bpm != null || of(t).isNotEmpty || (trackTags(t)?.isNotEmpty ?? false);

  /// Réguas da música: as arrastadas à mão ou as automáticas.
  static Vibe vibeOf(Track t) {
    if (t.energy != null && t.humor != null) return Vibe(t.energy!, t.humor!, manual: true);
    return _vibeCache[t] ??= autoVibe(styles: of(t), tags: trackTags(t) ?? const [], bpm: t.bpm, title: t.title);
  }
}
