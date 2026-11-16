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

/// Trecho de versão no fim ou entre colchetes: "(Live)", "[Live at Reading 1992]", " - Live in New York", "Remix XYZ".
/// Só conta depois do começo do título ("Live Forever" não é versão ao vivo).
final _versionTail = RegExp(
    r'(?<=\S)\s*(?:[\(\[【][^\)\]】]*\b(?:live|ao vivo|en vivo|remix|rmx|acoustic|ac[uú]stic[oa]?|unplugged version|instrumental|karaok[eê]|cover|demo|nightcore|slowed|sped up|reverb|8d)\b[^\)\]】]*[\)\]】]|\s[-–—]?\s*(?:live|ao vivo|en vivo|remix|rmx|acoustic|ac[uú]stic[oa]?|instrumental|karaok[eê]|nightcore|slowed|sped up|8d)\b.*$)',
    caseSensitive: false);

/// Álbum ou pasta de show: a música é ao vivo mesmo sem "live" no título.
final _liveAlbum = RegExp(r'\b(live|ao vivo|en vivo|concerts?|in concert|unplugged|bootleg|sessions? at|tour \d{4})\b|\b\d{2,4}[.\-]\d{2}[.\-]\d{2,4}\b', caseSensitive: false);

/// Normaliza a versão: "ao vivo"/"en vivo" = live, "rmx" = remix, "acústico" = acoustic.
String _versionName(String w) {
  final p = _plain(w);
  if (p == 'aovivo' || p == 'envivo') return 'live';
  if (p == 'rmx') return 'remix';
  if (p.startsWith('acust') || p.startsWith('acoust')) return 'acoustic';
  if (p == 'unpluggedversion') return 'acoustic';
  return p;
}

/// (título base, tipo de versão). Tipo '' = original.
(String, String) songParts(String title, {String album = '', String path = ''}) {
  final versions = <String>{};
  var t = title.replaceAll(_ignoredParts, ' ').replaceAll(_trailingFeat, '');
  t = t.replaceAllMapped(_versionTail, (m) {
    for (final v in _versionWords.allMatches(m.group(0)!)) {
      versions.add(_versionName(v.group(0)!));
    }
    return ' ';
  });
  if (_liveAlbum.hasMatch(album) || _liveAlbum.hasMatch(path.replaceAll(RegExp(r'[\\/][^\\/]*$'), ''))) versions.add('live');
  return (_plain(t), (versions.toList()..sort()).join('+'));
}

/// Chave de "mesma música": artista + título sem enfeites + tipo de versão.
/// "Where Did You Sleep Last Night" e "Where Did You Sleep Last Night [Live]" dão chaves diferentes.
String songKey(String artist, String title, {String album = '', String path = ''}) {
  final (base, version) = songParts(title, album: album, path: path);
  return '${_artistKey(artist)}|$base${version.isEmpty ? '' : '|$version'}';
}

String _artistOf(Track t) => t.artist == unknownArtist ? '' : t.artist;

/// Chave só do título (sem tipo de versão): junta original, lives e remixes da mesma música.
String baseKey(Track t) => '${_artistKey(_artistOf(t))}|${songParts(t.title).$1}';

/// Tipo de versão da música ('' = original, 'live', 'remix'...), olhando título, álbum e pasta.
String versionOf(Track t) => songParts(t.title, album: t.album, path: t.path).$2;

String trackKey(Track t) => songKey(_artistOf(t), t.title, album: t.album, path: t.path);

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

/// Repetidas:
/// - mesma gravação (mesmo artista e título, duração quase igual), em qualquer álbum/pasta;
/// - versões que não são a original (ao vivo, remix, acústica...): fica só UMA de cada tipo por música,
///   mesmo que sejam shows diferentes. Gravações originais com durações diferentes ficam todas.
Iterable<List<Track>> _rawGroups(List<Track> tracks) {
  final byBase = <String, List<Track>>{};
  for (final t in tracks) {
    if (!usableTitle(t.title)) continue;
    final k = baseKey(t);
    if (k.split('|')[1].isEmpty) continue;
    byBase.putIfAbsent(k, () => []).add(t);
  }
  final out = <List<Track>>[];
  for (final g in byBase.values.where((g) => g.length > 1)) {
    // 1. junta cópias da mesma gravação
    final clusters = <List<Track>>[];
    for (final t in [...g]..sort((a, b) => a.durationMs.compareTo(b.durationMs))) {
      final c = clusters.where((c) => c.every((x) => sameRecording(x, t))).firstOrNull;
      if (c != null) {
        c.add(t);
      } else {
        clusters.add([t]);
      }
    }
    // 2. por tipo de versão: originais separadas por gravação; cada outro tipo vira um grupo só
    final byType = <String, List<Track>>{};
    for (final c in clusters) {
      final types = c.map(versionOf).where((v) => v.isNotEmpty).toSet();
      final type = types.isEmpty ? '' : (types.toList()..sort()).first;
      if (type.isEmpty) {
        if (c.length > 1) out.add(c);
      } else {
        byType.putIfAbsent(type, () => []).addAll(c);
      }
    }
    out.addAll(byType.values.where((v) => v.length > 1));
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
