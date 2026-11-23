import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'library_search.dart';
import 'models.dart';
import 'theme.dart';
import 'xp_icons.dart';

/// Busca DENTRO de uma lista (álbum, artista, playlist, favoritas, lista de álbuns…).
///
/// Só filtra o que já está na tela: monta um índice pequeno da própria lista (uma vez por lista)
/// e não mexe no índice grande da Biblioteca.
class InListIndex {
  final List<Track> tracks;
  final LibraryIndex _index;
  final _cache = <String, Set<String>>{};
  InListIndex(this.tracks) : _index = LibraryIndex.build(tracks);

  /// As faixas que batem com [query], na MESMA ordem da lista (álbum continua na ordem do álbum).
  List<Track> filter(List<Track> list, String query) {
    if (normalizeText(query).isEmpty) return list;
    final hits = _cache.putIfAbsent(query, () => {for (final (t, _) in _index.search(query)) t.path});
    return [for (final t in list) if (hits.contains(t.path)) t];
  }
}

/// O nome (e, se quiser, outros textos como o artista do álbum) bate com a busca?
/// Mesmas regras da Biblioteca: sem acento, pedaço de palavra e pequenos erros de digitação.
bool textMatches(String query, List<String> texts) {
  final q = normalizeText(query);
  if (q.isEmpty) return true;
  final words = [for (final s in texts) ...normalizeText(s).split(' ')]..removeWhere((w) => w.isEmpty);
  for (final tok in q.split(' ')) {
    final typos = tok.length < 4 ? 0 : (tok.length < 8 ? 1 : 2);
    var ok = false;
    for (final w in words) {
      if (w.startsWith(tok) || (tok.length >= 3 && w.contains(tok))) {
        ok = true;
      } else if (typos > 0) {
        final whole = editDistance(tok, w, typos);
        final prefix = w.length > tok.length ? editDistance(tok, w.substring(0, tok.length), typos) : typos + 1;
        ok = min(whole, prefix) <= typos;
      }
      if (ok) break;
    }
    if (!ok) return false;
  }
  return true;
}

/// Troca letras acentuadas pela sem acento, mantendo o MESMO tamanho do texto (para marcar o trecho).
String _fold(String s) {
  final b = StringBuffer();
  for (final c in s.toLowerCase().split('')) {
    final r = _foldOne[c];
    b.write(r ?? c);
  }
  return b.toString();
}

const _foldOne = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', //
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', //
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ÿ': 'y',
};

/// Trechos de [text] que batem com as palavras da busca (início, fim), já juntos e em ordem.
List<(int, int)> matchRanges(String text, String query) {
  final q = normalizeText(query);
  if (q.isEmpty || text.isEmpty) return const [];
  final folded = _fold(text);
  if (folded.length != text.length) return const [];
  final ranges = <(int, int)>[];
  for (final tok in q.split(' ')) {
    if (tok.isEmpty) continue;
    var from = 0;
    while (true) {
      final i = folded.indexOf(tok, from);
      if (i < 0) break;
      // pedaço curto só no começo de uma palavra ("a" não marca o meio de tudo)
      final start = i == 0 || !_isWordChar(folded.codeUnitAt(i - 1));
      if (start || tok.length >= 3) ranges.add((i, i + tok.length));
      from = i + tok.length;
    }
  }
  if (ranges.isEmpty) return const [];
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[ranges.first];
  for (final r in ranges.skip(1)) {
    final last = merged.last;
    if (r.$1 <= last.$2) {
      merged[merged.length - 1] = (last.$1, max(last.$2, r.$2));
    } else {
      merged.add(r);
    }
  }
  return merged;
}

bool _isWordChar(int u) => (u >= 97 && u <= 122) || (u >= 48 && u <= 57) || u > 127;

/// Texto com o trecho encontrado marcado em amarelo (como o "Localizar" do XP).
TextSpan highlightSpan(String text, String? query, TextStyle style) {
  final ranges = query == null ? const <(int, int)>[] : matchRanges(text, query);
  if (ranges.isEmpty) return TextSpan(text: text, style: style);
  const mark = TextStyle(backgroundColor: Color(0xFFFFE680), color: Colors.black);
  final parts = <TextSpan>[];
  var at = 0;
  for (final (s, e) in ranges) {
    if (s > at) parts.add(TextSpan(text: text.substring(at, s)));
    parts.add(TextSpan(text: text.substring(s, e), style: mark));
    at = e;
  }
  if (at < text.length) parts.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: style, children: parts);
}

/// Estado da lupa de uma tela: aberta/fechada, o texto e a espera de 250 ms entre teclas.
mixin InListSearch<T extends StatefulWidget> on State<T> {
  final searchCtl = TextEditingController();
  final searchFocus = FocusNode();
  Timer? _searchDebounce;
  bool searchOpen = false;
  String searchQuery = '';

  bool get searching => searchOpen && normalizeText(searchQuery).isNotEmpty;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    searchCtl.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void toggleSearch() {
    if (searchOpen) {
      closeSearch();
    } else {
      setState(() => searchOpen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) searchFocus.requestFocus();
      });
    }
  }

  void closeSearch() {
    _searchDebounce?.cancel();
    searchCtl.clear();
    searchFocus.unfocus();
    setState(() {
      searchOpen = false;
      searchQuery = '';
    });
    onSearchChanged();
  }

  void _onSearchType(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => searchQuery = v.trim());
      onSearchChanged();
    });
  }

  /// Chamado quando o texto da busca muda (ex.: voltar a lista para o topo).
  void onSearchChanged() {}

  /// A lupa da barra azul (fica "afundada" enquanto a busca está aberta).
  Widget searchButton() => XpTitleButton(icon: Icons.search, tooltip: searchOpen ? 'Fechar busca' : 'Pesquisar nesta lista', onTap: toggleSearch, pressed: searchOpen);

  /// Endereço com "\Busca: "…"" no fim enquanto busca.
  String searchPath(String path) => searching ? '$path\\Busca: "$searchQuery"' : path;

  /// A caixa de busca. Fica SEMPRE no mesmo lugar da árvore (fora da troca lista cheia ↔ resultados),
  /// para o teclado não fechar ao digitar a 1ª letra ou apagar a última (ver PR #21).
  Widget searchBox(String hint) => !searchOpen
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Bevel(
            sunken: true,
            child: TextField(
              controller: searchCtl,
              focusNode: searchFocus,
              onChanged: _onSearchType,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                prefixIcon: const Padding(padding: EdgeInsets.all(8), child: XpIcon(XpIcons.find, size: 18)),
                prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                suffixIcon: IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Fechar busca', onPressed: closeSearch),
                hintText: hint,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        );

  /// Aviso quando nada bate.
  Widget noMatches() => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Nada encontrado para "$searchQuery" nesta lista.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF666666), fontSize: 13.5),
        ),
      );
}
