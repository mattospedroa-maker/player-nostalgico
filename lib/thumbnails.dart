import 'models.dart';

/// O GIF que mais aparece nas músicas do grupo (álbum/artista). Empate: o primeiro em ordem alfabética.
String? mostFrequentGif(Iterable<Track> group, Map<int, List<String>> pinnedByTrack, {bool Function(String path)? exists}) {
  final count = <String, int>{};
  for (final t in group) {
    for (final g in pinnedByTrack[t.id] ?? const <String>[]) {
      count[g] = (count[g] ?? 0) + 1;
    }
  }
  final ranked = count.keys.where((g) => exists == null || exists(g)).toList()
    ..sort((a, b) {
      final c = count[b]!.compareTo(count[a]!);
      return c != 0 ? c : a.compareTo(b);
    });
  return ranked.firstOrNull;
}

/// Músicas do grupo começando pelo álbum com mais faixas (para a "foto" do artista usar a capa principal).
List<Track> byMainAlbum(List<Track> group) {
  final n = <String, int>{};
  for (final t in group) {
    n[t.album] = (n[t.album] ?? 0) + 1;
  }
  return [...group]..sort((a, b) => n[b.album]!.compareTo(n[a.album]!));
}

/// Letra para o índice A–Z: sem acento, sem aspas/símbolos no começo; números e outros = '#'.
String indexLetter(String name) {
  const from = 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ';
  const to = 'AAAAAEEEEIIIIOOOOOUUUUCN';
  for (final ch in name.toUpperCase().split('')) {
    final i = from.indexOf(ch);
    final c = i >= 0 ? to[i] : ch;
    if (RegExp(r'[A-Z]').hasMatch(c)) return c;
    if (RegExp(r'[0-9]').hasMatch(c)) return '#';
  }
  return '#';
}

/// Posição do primeiro item da lista (já ordenada) cuja letra é [letter] ou vem depois dela.
int firstIndexForLetter(List<String> sortedNames, String letter) {
  const order = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final target = order.indexOf(letter);
  for (var i = 0; i < sortedNames.length; i++) {
    if (order.indexOf(indexLetter(sortedNames[i])) >= target) return i;
  }
  return sortedNames.isEmpty ? 0 : sortedNames.length - 1;
}

/// Ordena nomes como o índice: '#' primeiro, depois A–Z ignorando acentos e símbolos.
int compareForIndex(String a, String b) {
  const order = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final c = order.indexOf(indexLetter(a)).compareTo(order.indexOf(indexLetter(b)));
  return c != 0 ? c : a.toLowerCase().compareTo(b.toLowerCase());
}
