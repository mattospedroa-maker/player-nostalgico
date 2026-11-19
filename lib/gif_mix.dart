import 'gif_providers.dart';

/// Uma pesquisa já roteada: texto, peso (importância no plano visual) e grupo de onde veio.
class RoutedQuery {
  final String text;
  final double weight;
  final String group;
  const RoutedQuery(this.text, this.weight, this.group);
  @override
  String toString() => '$text [$group $weight]';
}

/// Para onde vão as pesquisas de uma música.
/// [general]: provedores gerais (Openverse, Wikimedia) — cena, clima, título, artista, gênero e palavras do usuário.
/// [anime]: provedores de anime com busca por nome (nekos.best) — palavras do usuário e nome da trilha sonora.
/// As categorias de clima de anime (dance, cry...) seguem pelas fontes de clima, à parte.
class GifRoutes {
  final List<RoutedQuery> general;
  final List<RoutedQuery> anime;
  const GifRoutes({required this.general, required this.anime});
}

/// Monta as rotas a partir dos grupos do plano. Função pura (testável).
/// [userWords]: palavras do usuário; [scenes]: cenas (letra, clipe, dicionário) em ordem;
/// [ost]: nome da trilha sonora (ex.: "Naruto"); [mood]: pesquisa do clima (ex.: "rain window").
GifRoutes routeQueries({
  List<String> userWords = const [],
  List<String> scenes = const [],
  String? ost,
  String? mood,
  List<String> title = const [],
  List<String> artist = const [],
  List<String> genre = const [],
}) {
  final seen = <String>{};
  List<RoutedQuery> group(Iterable<String> qs, double Function(int i) weight, String name) {
    final out = <RoutedQuery>[];
    for (final (i, q) in qs.indexed) {
      final g = generalVariant(q);
      if (g.trim().length < 2 || !seen.add(g.toLowerCase())) continue;
      out.add(RoutedQuery(g, weight(i), name));
    }
    return out;
  }

  final words = group(userWords, (_) => 1.0, 'palavras');
  final soundtrack = group([?ost], (_) => 0.95, 'trilha');
  final scene = group(scenes, (i) => (0.9 - i * 0.03).clamp(0.6, 0.9), 'cena');
  final clima = group([?mood], (_) => 0.7, 'clima');
  final titles = group(title, (i) => i == 0 ? 0.8 : 0.7, 'título');
  final artists = group(artist, (i) => 0.5 - i * 0.05, 'artista');
  final genres = group(genre, (i) => 0.45 - i * 0.05, 'gênero');
  // Ordem dos pedidos (cada provedor tem poucos): palavras e trilha, depois cenas intercaladas com
  // título e clima (para todos chegarem ao provedor geral mesmo com muitas cenas), artista e gênero no fim.
  // A importância de cada uma fica no peso, que entra na nota.
  RoutedQuery? take(List<RoutedQuery> l) => l.isEmpty ? null : l.removeAt(0);
  final general = <RoutedQuery>[
    ...words,
    ...soundtrack,
    ?take(scene),
    ?take(titles),
    ?take(scene),
    ?take(clima),
    ?take(scene),
    ?take(titles),
    ...scene,
    ...artists,
    ...genres,
  ];

  final anime = <RoutedQuery>[];
  final seenA = <String>{};
  for (final w in [...userWords, ?ost]) {
    final q = w.trim();
    if (q.length >= 2 && seenA.add(q.toLowerCase())) anime.add(RoutedQuery(q, q == ost ? 0.95 : 1.0, q == ost ? 'trilha' : 'palavras'));
  }
  return GifRoutes(general: general, anime: anime);
}

/// "sad anime" -> "sad" (o provedor geral procura a cena; o lado anime vem das fontes de anime).
String generalVariant(String q) {
  final g = q.replaceAll(RegExp(r'\banime\b', caseSensitive: false), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return g.isEmpty ? q.trim() : g;
}

/// Palavras no metadado que dizem que o GIF é de anime (vale também para o que vem de provedor geral).
final _animeWords = RegExp(r'\b(anime|manga|mang[aá]|otaku|chibi|waifu|kawaii|shounen|shonen|shoujo|shojo|ghibli|mecha|isekai|vtuber)\b',
    caseSensitive: false);

/// Tipo do GIF: fonte só de anime = anime; senão olha o metadado.
GifKind kindOf(GifCandidate c, {bool animeOnlySource = false}) =>
    animeOnlySource || _animeWords.hasMatch(c.meta) ? GifKind.anime : GifKind.general;

const _generic = {'the', 'and', 'of', 'with', 'for', 'a', 'an', 'in', 'on', 'band', 'music', 'gif', 'anime', 'de', 'da', 'do', 'e'};

List<String> _tokens(String s) => s
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9à-ÿ]+'))
    .where((w) => w.length >= 2 && !_generic.contains(w))
    .toList();

/// Quanto do texto da pesquisa aparece no metadado (0..1).
/// Sem metadado (a fonte não contou nada), confia em parte na busca da fonte: 0.6.
double queryMatch(String query, String meta) {
  final q = _tokens(query).toSet();
  if (q.isEmpty || meta.trim().isEmpty) return 0.6;
  final m = _tokens(meta).toSet();
  bool hit(String w) => m.contains(w) || m.any((x) => x.length >= 4 && w.length >= 4 && (x.startsWith(w) || w.startsWith(x)));
  return q.where(hit).length / q.length;
}

/// Nota de relevância de um GIF achado pela pesquisa [q] na posição [rank] da lista da fonte.
double relevance(RoutedQuery q, String meta, int rank) {
  final match = queryMatch(q.text, meta);
  final pos = (1 - rank * 0.02).clamp(0.7, 1.0);
  return q.weight * match * pos;
}

/// Nota mínima para um GIF geral entrar (abaixo disso é fraco e fica de fora, mesmo faltando GIF).
const minGoodScore = 0.3;

/// Junta GIFs de anime e gerais numa seleção intercalada.
///
/// Meta (não cota): ~70% anime e ~30% geral quando os dois lados têm candidatos bons.
/// - Nunca três do mesmo tipo seguidos se o outro lado ainda tem candidato bom.
/// - Relevância parecida (diferença até [tieMargin]) fica com o anime.
/// - Geral bem mais relevante (mais que [tieMargin]) passa na frente enquanto a meta de gerais não fechou;
///   depois dela, só se for muito melhor ([clearMargin]).
/// - Com 2 vagas ou mais, pelo menos um geral bom (se houver).
/// - Só candidatos bons entram: quem chama já tira os fracos; aqui nada completa a porcentagem.
///
/// Uso: [next] dá o próximo candidato; quando ele é salvo de verdade, chame [accept].
/// Se o download falhar, chame [next] de novo (a decisão é a mesma, vem o próximo do mesmo tipo).
class GifMix {
  final List<GifCandidate> _anime;
  final List<GifCandidate> _general;
  final int total;
  final List<GifKind> taken = [];

  static const tieMargin = 0.1;
  static const clearMargin = 0.25;
  static const generalShare = 0.3;

  GifMix({required List<GifCandidate> anime, required List<GifCandidate> general, required this.total})
      : _anime = [...anime]..sort((a, b) => b.score.compareTo(a.score)),
        _general = [...general]..sort((a, b) => b.score.compareTo(a.score));

  /// Quantos gerais a seleção quer (com candidatos bons dos dois lados).
  int get generalTarget {
    if (total < 2) return 0;
    final t = (total * generalShare).round();
    return t < 1 ? 1 : t;
  }

  bool get isEmpty => _anime.isEmpty && _general.isEmpty;

  GifKind? nextKind() {
    if (isEmpty) return null;
    if (_anime.isEmpty) return GifKind.general;
    if (_general.isEmpty) return GifKind.anime;
    final n = taken.length;
    if (n >= 2 && taken[n - 1] == taken[n - 2]) {
      return taken.last == GifKind.anime ? GifKind.general : GifKind.anime;
    }
    final gLeft = generalTarget - taken.where((k) => k == GifKind.general).length;
    final remaining = total - n;
    if (gLeft > 0 && gLeft >= remaining) return GifKind.general;
    final a = _anime.first.score, g = _general.first.score;
    final margin = gLeft > 0 ? tieMargin : clearMargin;
    return g > a + margin + 1e-9 ? GifKind.general : GifKind.anime;
  }

  /// Próximo candidato (tirado da lista), ou null quando acabou.
  GifCandidate? next() {
    final k = nextKind();
    if (k == null) return null;
    return (k == GifKind.anime ? _anime : _general).removeAt(0);
  }

  /// O candidato [c] foi salvo na música.
  void accept(GifCandidate c) => taken.add(c.kind ?? GifKind.general);
}
