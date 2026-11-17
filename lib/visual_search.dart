import 'dart:math';

import 'error_log.dart';
import 'gif_feedback.dart';
import 'gif_providers.dart';
import 'visual_tags.dart';

/// De onde vêm os GIFs da roda do Tocando agora.
enum GifSource {
  auto('Automático', 'Anime salvo intercalado com GIPHY (recomendado)'),
  anime('Só anime', 'Só os GIFs de anime salvos; funciona sem internet'),
  giphy('Preferir GIPHY', 'Mais GIFs do GIPHY; precisa de internet');

  final String label;
  final String hint;
  const GifSource(this.label, this.hint);
}

/// Um GIF do GIPHY achado por um termo visual.
class VisualResult {
  final GiphyGif gif;
  final String query;
  final String group;

  /// true = veio da pesquisa na versão anime do termo.
  final bool anime;

  /// Termo do dicionário que achou o GIF (para o 👎 e o ⬇ ensinarem o app).
  final String term;

  /// Nota para a vibe (maior = melhor).
  final double score;
  const VisualResult(this.gif, this.query, this.group, {required this.anime, this.term = '', this.score = 0});
}

/// Pagina um termo visual no GIPHY com preferência por anime (mas não 100%):
/// cada página tem ~70% da versão anime (`anime TERMO`) e ~30% do termo geral; se um lado acabar, o outro completa.
/// Memes, reações e GIFs com texto ficam de fora; [exclude] tira os que o usuário rejeitou.
class TermPager {
  final GiphyProvider giphy;
  final VisualQuery term;
  final Set<String> exclude;
  final double generalShare;
  final String artist, song;
  int _animeOffset = 0, _generalOffset = 0;
  bool _animeDone = false, _generalDone = false;
  final Set<String> _seen = {};

  /// [startOffset]: começa mais adiante nos resultados (cada música pega uma parte diferente da lista).
  TermPager(this.giphy, this.term,
      {int startOffset = 0, this.exclude = const {}, this.generalShare = 0.3, this.artist = '', this.song = ''}) {
    _animeOffset = startOffset;
    _generalOffset = startOffset;
    if (generalVariant(term.text).toLowerCase() == animeVariant(term.text).toLowerCase()) _generalDone = true;
  }

  bool get done => _animeDone && _generalDone;

  /// "dark cinematic" -> "anime dark cinematic"; "sad anime" continua igual.
  static String animeVariant(String q) => RegExp(r'\banime\b', caseSensitive: false).hasMatch(q) ? q : 'anime $q';

  /// "sad anime" -> "sad"; sem "anime" fica igual.
  static String generalVariant(String q) {
    final g = q.replaceAll(RegExp(r'\banime\b', caseSensitive: false), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return g.isEmpty ? q : g;
  }

  Future<List<VisualResult>> _page(bool anime, int want) async {
    if (want <= 0 || (anime ? _animeDone : _generalDone)) return const [];
    final q = anime ? animeVariant(term.text) : generalVariant(term.text);
    final page = await giphy.search(q, offset: anime ? _animeOffset : _generalOffset, limit: want);
    if (anime) {
      _animeOffset += page.length;
      if (page.length < want) _animeDone = true;
    } else {
      _generalOffset += page.length;
      if (page.length < want) _generalDone = true;
    }
    return [
      for (final g in page)
        if (!exclude.contains(g.id) && !looksLikeMeme(g.title) && _seen.add(g.id))
          VisualResult(g, q, term.group,
              anime: anime,
              term: term.text,
              score: resultScore(termScore: term.score, anime: anime, title: g.title, artist: artist, song: song)),
    ];
  }

  /// Próxima página de até [count] GIFs, anime na frente. Erros do GIPHY sobem como [GiphyException].
  Future<List<VisualResult>> next({int count = GiphyProvider.pageSize}) async {
    final general = _generalDone ? 0 : (count * generalShare).round();
    final anime = await _page(true, count - general);
    // anime acabou ou veio pouco: o geral completa
    final gen = await _page(false, count - anime.length);
    var out = [...anime, ...gen];
    if (out.length < count && !_animeDone) out = [...out, ...await _page(true, count - out.length)];
    // anime primeiro (preferência), depois pela nota
    out.sort((a, b) => a.anime == b.anime ? b.score.compareTo(a.score) : (a.anime ? -1 : 1));
    return out;
  }
}

/// GIFs do GIPHY para a roda do Tocando agora: poucos, dos termos mais importantes, anime primeiro.
/// Não são salvos (os termos do GIPHY proíbem guardar sem o usuário pedir); passam direto da internet.
class PlayerVisuals {
  final GiphyProvider giphy;
  PlayerVisuals(this.giphy);

  /// [rnd]: sorteio próprio da música (músicas do mesmo álbum têm tags parecidas; assim cada uma
  /// pega termos e trechos diferentes dos resultados). [avoid]: GIFs já usados por músicas do mesmo álbum/artista.
  /// [rejected]: GIFs que o usuário marcou como "não combina" (nunca voltam).
  Future<List<VisualResult>> pick(VisualPlan plan,
      {int count = 5, int terms = 3, Random? rnd, Set<String> avoid = const {}, Set<String> rejected = const {}, String artist = '', String song = ''}) async {
    final r = rnd ?? Random();
    // o termo principal fica; os outros são sorteados entre os seguintes
    final pool = plan.top(terms * 2);
    if (pool.isEmpty) return const [];
    final rest = pool.sublist(1)..shuffle(r);
    final top = [pool.first, ...rest].take(terms).toList();
    final per = (count / top.length).ceil();
    final lists = <List<VisualResult>>[];
    for (final q in top) {
      try {
        // começa num trecho sorteado dos resultados e pede o dobro, para pular os repetidos
        final pager = TermPager(giphy, q, startOffset: r.nextInt(4) * per * 2, exclude: rejected, artist: artist, song: song);
        var page = (await pager.next(count: per * 2)).where((x) => !avoid.contains(x.gif.id)).toList();
        // trecho vazio: volta para o começo
        if (page.isEmpty) page = await TermPager(giphy, q, exclude: rejected, artist: artist, song: song).next(count: per);
        lists.add(page.take(per).toList());
      } on GiphyException catch (e) {
        if (e.error == GiphyError.noKey || e.error == GiphyError.invalidKey) rethrow;
        errorLog.info('GIFs', 'GIPHY não respondeu para "${q.text}"', e);
        lists.add(const []);
      }
    }
    // um de cada termo por vez, para variar
    final seen = <String>{};
    return interleave(lists).where((x) => seen.add(x.gif.id)).take(count).toList();
  }
}

/// Junta listas alternando: a1, b1, a2, b2...
List<T> interleave<T>(List<List<T>> lists) {
  final out = <T>[];
  final longest = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
  for (var i = 0; i < longest; i++) {
    for (final l in lists) {
      if (i < l.length) out.add(l[i]);
    }
  }
  return out;
}
