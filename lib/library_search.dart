import 'dart:math';

import 'models.dart';
import 'mood.dart';
import 'play_stats.dart';

/// Tira acentos, deixa minúsculo e troca símbolos por espaço ("Ação!" -> "acao").
String normalizeText(String s) {
  final b = StringBuffer();
  var space = true;
  for (final r in s.toLowerCase().runes) {
    var c = String.fromCharCode(r);
    c = _accents[c] ?? c;
    final u = c.codeUnitAt(0);
    final keep = c.length > 1 || (u < 128 ? _alnum(u) : _letter(r));
    if (keep) {
      b.write(c);
      space = false;
    } else if (!space) {
      b.write(' ');
      space = true;
    }
  }
  return b.toString().trim();
}

bool _alnum(int u) => (u >= 97 && u <= 122) || (u >= 48 && u <= 57);

// letras de outros alfabetos (japonês, cirílico…) continuam valendo na busca
bool _letter(int r) => r >= 0x370 && !(r >= 0x2000 && r <= 0x2BFF) && !(r >= 0x3000 && r <= 0x303F) && !(r >= 0xFF00 && r <= 0xFF0F) && r < 0x1F000;

const _accents = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', //
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', //
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

/// Distância de edição (com troca de letras vizinhas), parando cedo quando passa de [max].
int editDistance(String a, String b, int max) {
  if ((a.length - b.length).abs() > max) return max + 1;
  var prev2 = List<int>.filled(b.length + 1, 0);
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    var rowMin = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
      if (i > 1 && j > 1 && a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) && a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
        v = min(v, prev2[j - 2] + 1);
      }
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return max + 1;
    final t = prev2;
    prev2 = prev;
    prev = cur;
    cur = t;
  }
  return prev[b.length];
}

/// Erros de digitação tolerados para uma palavra desse tamanho.
int _typos(int len) => len < 4 ? 0 : (len < 8 ? 1 : 2);

class _Entry {
  final Track track;
  final List<List<String>> fields; // palavras de cada campo, na ordem de [_weights]
  final String title;
  _Entry(this.track, this.fields, this.title);
}

// título, artista, álbum, gênero, clima, outros (ano, nome do arquivo)
const _weights = [3.0, 2.5, 2.0, 1.6, 1.6, 1.0];

/// Índice de busca da biblioteca: monta as palavras normalizadas uma vez por lista de músicas
/// (a busca de cada tecla só compara com ele, sem ir ao banco).
class LibraryIndex {
  final List<Track> tracks;
  final List<_Entry> _entries;
  final Set<String> _vocab;

  LibraryIndex._(this.tracks, this._entries, this._vocab);

  static LibraryIndex? _last;

  /// Reaproveita o índice enquanto a lista de músicas for a mesma.
  static LibraryIndex of(List<Track> tracks) {
    final l = _last;
    if (l != null && identical(l.tracks, tracks)) return l;
    return _last = LibraryIndex.build(tracks);
  }

  factory LibraryIndex.build(List<Track> tracks) {
    final vocab = <String>{};
    final cache = <String, List<String>>{};
    List<String> words(String s) => cache.putIfAbsent(s, () {
          final n = normalizeText(s);
          return n.isEmpty ? const [] : n.split(' ');
        });
    final entries = <_Entry>[];
    for (final t in tracks) {
      final mood = t.effectiveMood;
      final file = t.path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final fields = [
        words(t.title),
        t.artist == unknownArtist ? const <String>[] : words(t.artist),
        t.album == unknownAlbum ? const <String>[] : words(t.album),
        words(t.genre),
        mood == null ? const <String>[] : words(mood.label),
        [if ((t.year ?? 0) > 0) '${t.year}', ...words(file)],
      ];
      for (final f in fields) {
        vocab.addAll(f);
      }
      entries.add(_Entry(t, fields, normalizeText(t.title)));
    }
    return LibraryIndex._(tracks, entries, vocab);
  }

  /// Busca por título, artista, álbum, gênero, clima e nome do arquivo.
  /// Ignora acentos e maiúsculas, aceita pedaços de palavra e pequenos erros de digitação.
  /// Todas as palavras digitadas precisam aparecer; o resultado vem do mais parecido para o menos.
  List<(Track, double)> search(String query) {
    final q = normalizeText(query);
    if (q.isEmpty) return [for (final e in _entries) (e.track, 0.0)];
    final tokens = q.split(' ');
    // para cada palavra digitada, as palavras da biblioteca que batem (calculado uma vez, não por música)
    final matches = [for (final tok in tokens) _matchesFor(tok)];
    final out = <(Track, double)>[];
    for (final e in _entries) {
      var total = 0.0;
      var ok = true;
      for (final m in matches) {
        var best = 0.0;
        for (var f = 0; f < e.fields.length; f++) {
          for (final w in e.fields[f]) {
            final s = m[w];
            if (s != null && s * _weights[f] > best) best = s * _weights[f];
          }
        }
        if (best == 0) {
          ok = false;
          break;
        }
        total += best;
      }
      if (!ok) continue;
      if (e.title == q) {
        total += 6;
      } else if (e.title.startsWith(q)) {
        total += 4;
      } else if (tokens.length > 1 && e.title.contains(q)) {
        total += 3;
      }
      out.add((e.track, total));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  final Map<String, Map<String, double>> _tokenCache = {};

  Map<String, double> _matchesFor(String tok) => _tokenCache.putIfAbsent(tok, () {
        final m = <String, double>{};
        final maxTypos = _typos(tok.length);
        for (final w in _vocab) {
          if (w == tok) {
            m[w] = 1;
          } else if (w.startsWith(tok)) {
            m[w] = .85;
          } else if (tok.length >= 3 && w.contains(tok)) {
            m[w] = .6;
          } else if (maxTypos > 0) {
            // erro de digitação: compara com a palavra inteira e com o começo dela (busca enquanto digita)
            final whole = editDistance(tok, w, maxTypos);
            final prefix = w.length > tok.length ? editDistance(tok, w.substring(0, tok.length), maxTypos) : maxTypos + 1;
            final d = min(whole, prefix);
            if (d <= maxTypos) m[w] = (whole <= prefix ? .55 : .45) - .1 * (d - 1);
          }
        }
        return m;
      });
}

/// Critérios de ordem da lista de músicas.
enum TrackSort {
  relevance('Relevância'),
  title('Nome'),
  artist('Artista'),
  album('Álbum'),
  added('Data de adição'),
  plays('Mais tocadas'),
  recent('Tocadas recentemente'),
  favorites('Favoritas primeiro');

  final String label;
  const TrackSort(this.label);
}

/// Filtros que podem ser combinados (vazio = todos).
class TrackFilter {
  final String? artist;
  final String? album;
  final String? genre;
  final Mood? mood;
  final bool favoritesOnly;
  const TrackFilter({this.artist, this.album, this.genre, this.mood, this.favoritesOnly = false});

  bool get isEmpty => artist == null && album == null && genre == null && mood == null && !favoritesOnly;
  int get count => [artist, album, genre, mood].where((x) => x != null).length + (favoritesOnly ? 1 : 0);

  bool matches(Track t) =>
      (artist == null || t.artist == artist) &&
      (album == null || t.album == album) &&
      (genre == null || t.genre.toLowerCase() == genre!.toLowerCase()) &&
      (mood == null || t.effectiveMood == mood) &&
      (!favoritesOnly || t.favorite);

  TrackFilter copyWith({String? Function()? artist, String? Function()? album, String? Function()? genre, Mood? Function()? mood, bool? favoritesOnly}) =>
      TrackFilter(
        artist: artist == null ? this.artist : artist(),
        album: album == null ? this.album : album(),
        genre: genre == null ? this.genre : genre(),
        mood: mood == null ? this.mood : mood(),
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      );
}

/// Busca + filtros + ordem, tudo na memória (a biblioteca já está carregada no AppState).
List<Track> queryLibrary(List<Track> tracks, {String query = '', TrackFilter filter = const TrackFilter(), TrackSort sort = TrackSort.relevance, PlayStats? stats}) {
  final hits = LibraryIndex.of(tracks).search(query);
  final list = [for (final (t, _) in hits) if (filter.matches(t)) t];
  return sortTracks(list, query.trim().isEmpty && sort == TrackSort.relevance ? TrackSort.artist : sort, stats: stats);
}

/// Ordena (estável: empate mantém a ordem anterior, ex. a da relevância).
List<Track> sortTracks(List<Track> list, TrackSort sort, {PlayStats? stats}) {
  int text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  final s = stats ?? PlayStats.empty;
  final Comparator<Track>? cmp = switch (sort) {
    TrackSort.relevance => null,
    TrackSort.title => (a, b) => text(a.title, b.title),
    TrackSort.artist => (a, b) {
        final c = text(a.artist, b.artist);
        return c != 0 ? c : (text(a.album, b.album) != 0 ? text(a.album, b.album) : text(a.title, b.title));
      },
    TrackSort.album => (a, b) {
        final c = text(a.album, b.album);
        return c != 0 ? c : text(a.title, b.title);
      },
    TrackSort.added => (a, b) => b.addedAt.compareTo(a.addedAt),
    TrackSort.plays => (a, b) => s.count(b.id).compareTo(s.count(a.id)),
    TrackSort.recent => (a, b) => s.last(b.id).compareTo(s.last(a.id)),
    TrackSort.favorites => (a, b) => (b.favorite ? 1 : 0).compareTo(a.favorite ? 1 : 0),
  };
  if (cmp == null) return list;
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((x, y) {
    final c = cmp(x.$2, y.$2);
    return c != 0 ? c : x.$1.compareTo(y.$1);
  });
  return [for (final (_, t) in indexed) t];
}
