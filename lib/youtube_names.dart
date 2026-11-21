import 'filename_parser.dart';
import 'models.dart';

/// Nome corrigido de um vídeo do YouTube (o que vira tag e caminho Artista/Álbum/Título.mp3).
class YtNames {
  final String artist;
  final String title;
  final String album;
  const YtNames({required this.artist, required this.title, required this.album});

  YtNames copyWith({String? artist, String? title, String? album}) =>
      YtNames(artist: artist ?? this.artist, title: title ?? this.title, album: album ?? this.album);
}

/// Restos comuns em títulos do YouTube que o leitor de nomes de arquivo não conhece.
final _ytJunk = RegExp(
    r'(\s|^)(#\S+|4k|8k|uhd|full hd|m/v|official\s+(music\s+)?video|clipe\s+oficial|v[ií]deo\s+oficial|lyric\s+video|lyrics|audio\s+oficial|official\s+audio)(?=\s|$)',
    caseSensitive: false);

/// Fim do nome do canal que não faz parte do artista: "Linkin Park - Topic", "RammsteinVEVO", "Fulano Official",
/// "MadrugadaOfficial" (grudado), "Fulano Oficial", "Fulano Official Channel".
final _channelSuffix = RegExp(
    r'(\s*-\s*topic|\s*-\s*tópico|\s*-\s*official|vevo|(?<![Uu]n)\s*offici[ae]l(\s*channel)?|\s*offical|\s*oficial|\s*official\s*page|\s+channel|\s+canal)$',
    caseSensitive: false);

/// Fins que só saem com espaço ou com maiúscula grudada ("Fulano Music", "FulanoTV", "Fulano HQ"):
/// assim "Electromusic" ou "KTV" não perdem pedaço.
final _channelSuffixSoftCamel = RegExp(r'(?<=[a-z0-9])(Music|TV|Tv|HQ|Videos?|Channel|Canal|BR)$');
final _channelSuffixSoftSpaced = RegExp(r'\s+(music|tv|hq|videos?|channel|canal|br)$', caseSensitive: false);

/// Canais de gravadora/compilação: não servem como artista.
final _labelChannel = RegExp(r'\b(records|recordings|entertainment|label|music group|lyrics?|letras?|nightcore|vibes|mix(es)?|world)\b', caseSensitive: false);

/// "LinkinPark" -> "Linkin Park" (canais VEVO juntam as palavras).
String _splitCamel(String s) => s.contains(' ') ? s : s.replaceAllMapped(RegExp(r'(?<=[a-z])(?=[A-Z])'), (_) => ' ');

/// Tira do fim do nome o que é do canal e não do artista ("Official", "VEVO", "- Topic", "Music"...).
String stripChannelSuffix(String name) {
  var c = name.trim();
  for (var i = 0; i < 3; i++) {
    final before = c;
    var next = c.replaceAll(_channelSuffix, '').trim();
    if (next.length < 2) next = c;
    c = next;
    next = c.replaceAll(_channelSuffixSoftCamel, '').replaceAll(_channelSuffixSoftSpaced, '').trim();
    if (next.length >= 2) c = next;
    c = c.replaceAll(RegExp(r'[\s\-–—_|:.]+$'), '').trim();
    if (c == before) break;
  }
  return c;
}

/// Artista a partir do nome do canal, ou null se o canal não parece ser do artista.
String? artistFromChannel(String channel) {
  var c = channel.trim();
  if (c.isEmpty) return null;
  final wasTopic = RegExp(r'-\s*(topic|tópico)$', caseSensitive: false).hasMatch(c);
  final wasVevo = RegExp(r'vevo$', caseSensitive: false).hasMatch(c);
  c = stripChannelSuffix(c);
  if (wasVevo) c = _splitCamel(c);
  if (!wasTopic && !wasVevo && _labelChannel.hasMatch(c)) return null;
  return cleanArtistName(c);
}

/// Jeitos de escrever um artista que pode ter vindo do nome do canal, do mais fiel ao mais limpo:
/// "MadrugadaOfficial" -> ["MadrugadaOfficial", "Madrugada"]; "LinkinParkVEVO" -> [..., "LinkinPark", "Linkin Park"].
List<String> artistNameVariants(String artist) {
  final out = <String>[];
  void add(String s) {
    final t = s.trim();
    if (t.isNotEmpty && !out.any((o) => o.toLowerCase() == t.toLowerCase())) out.add(t);
  }

  add(artist);
  final stripped = stripChannelSuffix(artist);
  add(stripped);
  add(_splitCamel(stripped));
  // "The Foo Fighters" -> "Foo Fighters" (títulos de vídeo costumam pôr o "The" a mais)
  add(stripped.replaceFirst(RegExp(r'^the\s+', caseSensitive: false), ''));
  return out;
}

/// Começo de título que diz quem toca, sem o " - ": "Foo Fighters w David Lee Roth playing Van Halen",
/// "Metallica performs Enter Sandman", "Nirvana covering Bowie". ("feat.", "with" e "live at" ficam de fora:
/// costumam vir depois do nome da música, como em "Bohemian Rhapsody Live at Wembley".)
final _leadArtist = RegExp(
    r'^(.{2,40}?)\s+(?:w/|w\.|w|joined\s+by|playing|plays|performs?|performing|covers?|covering)\s+\S',
    caseSensitive: false);

/// Artista pelo começo do título do vídeo, ou null se o título não começa dizendo quem toca.
/// Vem antes do nome do canal: vídeo de show postado por um fã ficava com o nome do fã como artista.
String? artistFromTitleLead(String title) {
  final m = _leadArtist.firstMatch(title.trim());
  if (m == null) return null;
  final lead = m.group(1)!.trim();
  // "I was playing...", "How to play...": frase, não nome de artista
  if (lead.split(RegExp(r'\s+')).length > 5 || RegExp(r'^(i|we|me|my|how|when|why|what|this|eu|nós|quando|como)\b', caseSensitive: false).hasMatch(lead)) {
    return null;
  }
  return cleanArtistName(lead);
}

/// "Artista A, Artista B" (campo artist do YouTube Music) -> "Artista A".
String _firstArtist(String s) => s.split(RegExp(r',|;')).first.trim();

/// Tira enfeites de um título do YouTube antes de usar o leitor de nomes de arquivo.
String preCleanYoutubeTitle(String s) {
  var out = s;
  for (var i = 0; i < 2; i++) {
    out = out.replaceAll(_ytJunk, ' ');
  }
  // "Título | Official Video" e restos vazios "()" "[]"
  out = out.replaceAll(RegExp(r'\(\s*\)|\[\s*\]|【\s*】'), ' ');
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Adivinha artista/título/álbum pelas informações que o yt-dlp devolve (-J).
/// Ordem: campos de música do YouTube (track/artist/album) > "Artista - Título" no nome do vídeo > nome do canal.
YtNames guessYoutubeNames(Map<String, dynamic> info) {
  String s(String k) => (info[k] ?? '').toString().trim();
  final track = s('track');
  final artistField = s('artist').isNotEmpty ? s('artist') : (s('artists').isNotEmpty ? s('artists') : s('creator'));
  final channel = s('channel').isNotEmpty ? s('channel') : s('uploader');
  final videoTitle = s('title');

  String? artist;
  String title;
  if (track.isNotEmpty && artistField.isNotEmpty) {
    artist = cleanArtistName(_firstArtist(artistField.replaceAll(RegExp(r'[\[\]"]'), '')));
    title = parseFileName(preCleanYoutubeTitle(track)).title;
  } else {
    final parsed = parseFileName(preCleanYoutubeTitle(videoTitle));
    title = parsed.title;
    artist = parsed.artist;
  }
  if (artist == null) {
    final fromChannel = artistFromChannel(channel);
    final cleanTitle = preCleanYoutubeTitle(videoTitle);
    // o canal é do artista quando o nome dele aparece no título; senão, o começo do título diz quem toca
    // canal oficial (Official, VEVO, - Topic) também é do artista
    final official = channel != stripChannelSuffix(channel);
    final channelIsArtist = fromChannel != null && (official || cleanTitle.toLowerCase().contains(fromChannel.toLowerCase()));
    artist = channelIsArtist ? fromChannel : (artistFromTitleLead(cleanTitle) ?? fromChannel);
  }
  final album = s('album');
  return YtNames(
    artist: (artist == null || artist.isEmpty) ? unknownArtist : artist,
    title: title.isEmpty ? (videoTitle.isEmpty ? 'Sem título' : videoTitle) : title,
    album: album.isEmpty ? unknownAlbum : album,
  );
}
