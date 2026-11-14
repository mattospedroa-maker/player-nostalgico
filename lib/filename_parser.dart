import 'package:path/path.dart' as p;

const audioExtensions = {'.mp3', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wav'};

bool isAudioFile(String path) => audioExtensions.contains(p.extension(path).toLowerCase());

class ParsedName {
  final String? artist;
  final String title;
  const ParsedName(this.artist, this.title);
}

/// Tira artista e título de nomes como "01 - Artista - Título (Official Video) [320kbps]".
ParsedName parseFileName(String name) {
  var s = name.replaceAll('_', ' ');
  // remove lixo comum de downloads
  s = s.replaceAll(
      RegExp(r'[\(\[][^\)\]]*(official|video|audio|lyrics?|letra|legendado|kbps|hd|hq|mv|clipe|visualizer)[^\)\]]*[\)\]]',
          caseSensitive: false),
      '');
  s = s.replaceAll(RegExp(r'^\s*\d{1,3}\s*[-.\s]\s*'), ''); // número da faixa
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final parts = s.split(RegExp(r'\s+[-–—]\s+'));
  if (parts.length >= 2) {
    return ParsedName(parts.first.trim(), parts.sublist(1).join(' - ').trim());
  }
  return ParsedName(null, s);
}
