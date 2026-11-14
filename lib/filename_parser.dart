import 'package:path/path.dart' as p;

const audioExtensions = {'.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wav'};

bool isAudioFile(String path) => audioExtensions.contains(p.extension(path).toLowerCase());

class ParsedName {
  final String? artist;
  final String title;
  const ParsedName(this.artist, this.title);
}

/// Palavras que aparecem entre colchetes mas não são artista nem título.
final _junkWords = RegExp(
    r'(official|oficial|video|vídeo|audio|áudio|lyrics?|letra|legenda|legendado|sub(s|bed|titulado)?|pt-?br|eng?|romaji|kara(oke)?|kbps|\bhd\b|\bhq\b|\bmv\b|\bpv\b|clipe|visualizer|full|completo|remaster(ed)?|\d{3,4}p)',
    caseSensitive: false);

/// Nomes genéricos que não servem como artista.
final _genericArtists = RegExp(r'^(vocaloid|various( artists)?|v\.?a\.?|unknown|desconhecido|artista desconhecido|music|musica|música|anime|ost)$',
    caseSensitive: false);

/// Limpa enfeites, números de faixa e textos de download de um nome.
/// Ex.: "00 - 002 - 【Hatsune Miku】 World is Mine 【Legenda PT-BR】" -> "World is Mine" (artista: Hatsune Miku).
String cleanTitle(String s) => parseFileName(s).title;

ParsedName parseFileName(String name) {
  var s = name.replaceAll('_', ' ');
  String? bracketArtist;
  // texto entre símbolos decorativos ("▓ Vocaloid ▓") funciona como 【...】
  const deco = r'[─-▟■-◿☀-➿⭐⭕]';
  s = s.replaceAllMapped(RegExp('$deco+\\s*([^─-▟■-◿☀-➿⭐⭕]+?)\\s*$deco+'), (m) {
    final inner = m.group(1)!.trim();
    if (inner.isNotEmpty && !_junkWords.hasMatch(inner) && !_genericArtists.hasMatch(inner)) bracketArtist ??= inner;
    return ' ';
  });
  // símbolos decorativos soltos (▓ █ ★ ♪ etc.)
  s = s.replaceAll(RegExp(deco), ' ');

  // 【...】 「...」 [...] (...) : remove os que são lixo; o primeiro 【...】 que sobra vira pista de artista
  s = s.replaceAllMapped(RegExp(r'[【\[\(「『]([^】\]\)」』]*)[】\]\)」』]'), (m) {
    final inner = m.group(1)!.trim();
    if (inner.isEmpty || _junkWords.hasMatch(inner)) return ' ';
    final open = m.group(0)![0];
    if (open == '【' || open == '「' || open == '『') {
      bracketArtist ??= inner;
      return ' ';
    }
    // (feat. X), (Remix) etc. ficam no título
    return m.group(0)!;
  });

  s = _stripLeadingNumbers(s);
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  final parts = s.split(RegExp(r'\s+[-–—~|]\s+')).map((x) => _stripLeadingNumbers(x).trim()).where((x) => x.isNotEmpty).toList();
  String? artist;
  String title;
  if (parts.length >= 2) {
    artist = parts.first;
    title = parts.sublist(1).join(' - ');
    if (_genericArtists.hasMatch(artist)) artist = null;
  } else {
    title = parts.isEmpty ? s : parts.first;
  }
  artist ??= bracketArtist;
  if (artist != null && _genericArtists.hasMatch(artist)) artist = null;
  title = title.replaceAll(RegExp(r'^[\s\-–—.:]+|[\s\-–—.:]+$'), '').trim();
  if (title.isEmpty) title = name.trim();
  return ParsedName(artist, title);
}

/// Limpa um artista vindo das tags (símbolos, 【】). Null se for genérico ("Vocaloid", "Unknown"...).
String? cleanArtistName(String s) {
  var a = s.replaceAll(RegExp(r'[─-▟■-◿☀-➿⭐⭕]'), ' ').replaceAll(RegExp(r'[【】「」『』]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (a.isEmpty || _genericArtists.hasMatch(a)) return null;
  return a;
}

/// "00 - 002 - ", "017 - ", "01. ", "3 " no começo.
String _stripLeadingNumbers(String s) {
  var out = s.trimLeft();
  final re = RegExp(r'^(\d{1,4}\s*[-–—.)_]\s*\d{1,4}\s+(?=\D)|\d{1,4}\s*[-–—.)_]\s*|0\d{0,3}\s+)');
  while (re.hasMatch(out)) {
    final next = out.replaceFirst(re, '');
    if (next.trim().isEmpty) break;
    out = next.trimLeft();
  }
  return out;
}
