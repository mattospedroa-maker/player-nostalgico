import 'dart:io';

import 'models.dart';

/// Marcas de versão: com elas a música conta como outra (ao vivo, remix, acústica...).
final _versionWords = RegExp(
    r'\b(live|ao vivo|en vivo|remix|rmx|acoustic|ac[uú]stic[oa]?|unplugged version|instrumental|karaok[eê]|cover|demo|nightcore|slowed|sped up|reverb|8d)\b',
    caseSensitive: false);

/// Partes do título que não mudam a música: (feat. X), (Remastered 2011), (Radio Edit)...
final _ignoredParts = RegExp(
    r'[\(\[【]\s*(feat\.?|ft\.?|featuring|with|prod\.?|remaster(ed)?|\d{4}\s*remaster(ed)?|remaster(ed)?\s*\d{4}|radio edit|single version|album version|explicit|clean|mono|stereo|official)[^\)\]】]*[\)\]】]',
    caseSensitive: false);
final _trailingFeat = RegExp(r'\s+(feat\.?|ft\.?|featuring)\s+.*$', caseSensitive: false);

String _plain(String s) {
  const from = 'áàâãäåéèêëíìîïóòôõöúùûüçñýÿ';
  const to = 'aaaaaaeeeeiiiiooooouuuucnyy';
  final lower = s.toLowerCase();
  final b = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().replaceAll(RegExp(r'[^a-z0-9぀-ヿ一-鿿]+'), '');
}

/// Primeiro artista ("Linkin Park & Jay-Z" -> "linkinpark"). "The" no começo não conta.
String _artistKey(String artist) {
  var a = artist.split(RegExp(r'\s*(,|&|;|/|\bx\b|\bfeat\.?|\bft\.?|\band\b|\be\b)\s*', caseSensitive: false)).first;
  a = a.replaceFirst(RegExp(r'^the\s+', caseSensitive: false), '');
  return _plain(a);
}

/// Chave de "mesma música": artista + título sem enfeites + marcas de versão.
/// "Where Did You Sleep Last Night" e "Where Did You Sleep Last Night [Live]" dão chaves diferentes.
String songKey(String artist, String title) {
  final versions = _versionWords.allMatches(title).map((m) => _plain(m.group(0)!)).toSet().toList()..sort();
  var t = title.replaceAll(_ignoredParts, ' ').replaceAll(_trailingFeat, '');
  t = t.replaceAll(_versionWords, ' ');
  final base = _plain(t);
  return '${_artistKey(artist)}|$base${versions.isEmpty ? '' : '|${versions.join('+')}'}';
}

String trackKey(Track t) => songKey(t.artist == unknownArtist ? '' : t.artist, t.title);

/// Título que serve para comparar: precisa ter pelo menos 3 letras ("1", "10/89)", "(Outro)" sozinhos não servem).
bool usableTitle(String title) {
  final letters = RegExp(r'[A-Za-zÀ-ɏ぀-ヿ一-鿿]').allMatches(title.replaceAll(RegExp(r'\b(outro|intro|interlude|untitled|track|faixa|bonus)\b', caseSensitive: false), '')).length;
  return letters >= 3;
}

/// Diferença máxima de duração para ser a MESMA gravação (shows e versões diferentes têm durações diferentes).
const sameRecordingTolerance = Duration(milliseconds: 2500);

bool sameRecording(Track a, Track b) {
  if (a.durationMs <= 0 || b.durationMs <= 0) {
    // sem duração: só junta se for o mesmo álbum
    return a.album.toLowerCase() == b.album.toLowerCase();
  }
  return (a.durationMs - b.durationMs).abs() <= sameRecordingTolerance.inMilliseconds;
}

/// Repetidas = mesmo artista + mesmo título + mesma gravação (duração quase igual).
Iterable<List<Track>> _rawGroups(List<Track> tracks) {
  final byKey = <String, List<Track>>{};
  for (final t in tracks) {
    if (!usableTitle(t.title)) continue;
    final k = trackKey(t);
    if (k.split('|')[1].isEmpty) continue;
    byKey.putIfAbsent(k, () => []).add(t);
  }
  final out = <List<Track>>[];
  for (final g in byKey.values.where((g) => g.length > 1)) {
    // separa por gravação: cada cópia entra no primeiro grupo em que combina com todas
    final clusters = <List<Track>>[];
    for (final t in [...g]..sort((a, b) => a.durationMs.compareTo(b.durationMs))) {
      final c = clusters.where((c) => c.every((x) => sameRecording(x, t))).firstOrNull;
      if (c != null) {
        c.add(t);
      } else {
        clusters.add([t]);
      }
    }
    out.addAll(clusters.where((c) => c.length > 1));
  }
  return out;
}

/// Quantos arquivos sobram (cópias além da primeira de cada música). Não lê o disco.
int duplicateExtraCount(List<Track> tracks) => _rawGroups(tracks).fold(0, (a, g) => a + g.length - 1);

/// Grupos de músicas repetidas (2 ou mais cópias), a melhor cópia primeiro.
List<List<Track>> findDuplicateGroups(List<Track> tracks) {
  final groups = _rawGroups(tracks).map(rankCopies).toList()
    ..sort((a, b) => a.first.title.toLowerCase().compareTo(b.first.title.toLowerCase()));
  return groups;
}

/// Qualidade aproximada em kbps (tamanho do arquivo ÷ duração). 0 se não der para saber.
int estimatedKbps(Track t) {
  if (t.durationMs <= 0) return 0;
  try {
    final bytes = File(t.path).lengthSync();
    return (bytes * 8 / (t.durationMs / 1000) / 1000).round();
  } catch (_) {
    return 0;
  }
}

/// Ordena as cópias: com álbum, favorita, maior qualidade, nome sem "(2)", mais antiga.
List<Track> rankCopies(List<Track> group, {int Function(Track)? kbps}) {
  final q = kbps ?? estimatedKbps;
  final cache = {for (final t in group) t: q(t)};
  int score(Track t) {
    var s = 0;
    if (t.album.isNotEmpty && t.album != unknownAlbum) s += 1000;
    if (t.favorite) s += 500;
    s += (cache[t]!.clamp(0, 400));
    if (RegExp(r'\(\d+\)\.\w+$').hasMatch(t.path)) s -= 50;
    return s;
  }

  return [...group]..sort((a, b) {
      final d = score(b) - score(a);
      return d != 0 ? d : a.addedAt.compareTo(b.addedAt);
    });
}
