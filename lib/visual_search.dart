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
  const VisualResult(this.gif, this.query, this.group, {required this.anime});
}

/// Pagina um termo visual no GIPHY sempre com foco em anime:
/// primeiro `anime TERMO`; quando a versão anime acaba ou vem pouca coisa, completa com o termo geral.
class TermPager {
  final GiphyProvider giphy;
  final VisualQuery term;
  int _animeOffset = 0, _generalOffset = 0;
  bool _animeDone = false, _generalDone = false;
  final Set<String> _seen = {};

  TermPager(this.giphy, this.term);

  bool get done => _animeDone && _generalDone;

  /// "dark cinematic" -> "anime dark cinematic"; "sad anime" continua igual.
  static String animeVariant(String q) => RegExp(r'\banime\b', caseSensitive: false).hasMatch(q) ? q : 'anime $q';

  /// "sad anime" -> "sad"; sem "anime" fica igual.
  static String generalVariant(String q) {
    final g = q.replaceAll(RegExp(r'\banime\b', caseSensitive: false), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return g.isEmpty ? q : g;
  }

  /// Próxima página de até [count] GIFs (anime primeiro). Erros do GIPHY sobem como [GiphyException].
  Future<List<VisualResult>> next({int count = GiphyProvider.pageSize}) async {
    final out = <VisualResult>[];
    final animeQ = animeVariant(term.text);
    final generalQ = generalVariant(term.text);
    if (!_animeDone) {
      final page = await giphy.search(animeQ, offset: _animeOffset, limit: count);
      _animeOffset += page.length;
      if (page.length < count) _animeDone = true;
      out.addAll([for (final g in page) if (_seen.add(g.id)) VisualResult(g, animeQ, term.group, anime: true)]);
    }
    // pouco anime: completa com o termo geral (se for diferente)
    if (out.length < count ~/ 2 || (_animeDone && out.length < count)) {
      if (generalQ.toLowerCase() == animeQ.toLowerCase()) _generalDone = true;
      if (!_generalDone) {
        final want = count - out.length;
        final page = await giphy.search(generalQ, offset: _generalOffset, limit: want);
        _generalOffset += page.length;
        if (page.length < want) _generalDone = true;
        out.addAll([for (final g in page) if (_seen.add(g.id)) VisualResult(g, generalQ, term.group, anime: false)]);
      }
    }
    return out;
  }
}

/// GIFs do GIPHY para a roda do Tocando agora: poucos, dos termos mais importantes, anime primeiro.
/// Não são salvos (os termos do GIPHY proíbem guardar sem o usuário pedir); passam direto da internet.
class PlayerVisuals {
  final GiphyProvider giphy;
  PlayerVisuals(this.giphy);

  Future<List<VisualResult>> pick(VisualPlan plan, {int count = 5, int terms = 3}) async {
    final top = plan.top(terms);
    if (top.isEmpty) return const [];
    final per = (count / top.length).ceil();
    final lists = <List<VisualResult>>[];
    for (final q in top) {
      try {
        lists.add(await TermPager(giphy, q).next(count: per));
      } on GiphyException catch (e) {
        if (e.error == GiphyError.noKey || e.error == GiphyError.invalidKey) rethrow;
        lists.add(const []);
      }
    }
    // um de cada termo por vez, para variar
    final seen = <String>{};
    return interleave(lists).where((r) => seen.add(r.gif.id)).take(count).toList();
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
