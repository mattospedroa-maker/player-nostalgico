import 'lastfm.dart' show MusicTag;

/// Gêneros que não dizem nada sobre a música. O "Music" vem da categoria do vídeo no YouTube
/// (o yt-dlp grava a categoria como gênero); os outros aparecem em arquivos baixados de vários lugares.
const _generic = {
  'music', 'musica', 'música', 'musique', 'musik', 'songs', 'song', 'audio', 'mp3',
  'other', 'others', 'outro', 'outros', 'misc', 'miscellaneous', 'various', 'variado', 'variados',
  'unknown', 'unknown genre', 'desconhecido', 'genre', 'genero', 'gênero', 'none', 'null', 'n/a', 'na', '-', '?',
  'default', 'youtube', 'download', 'downloads',
  // categorias do YouTube
  'entertainment', 'people & blogs', 'people and blogs', 'film & animation', 'film and animation', 'gaming',
  'comedy', 'education', 'howto & style', 'news & politics', 'nonprofits & activism', 'science & technology',
  'sports', 'travel & events', 'autos & vehicles', 'pets & animals', 'shows',
};

/// Palavras que indicam um gênero de verdade (para escolher entre as tags do MusicBrainz/Last.fm).
final genreWords = RegExp(
    r'rock|metal|pop|punk|rap|hip.?hop|trap|jazz|blues|soul|funk|disco|r&b|rnb|electr|techno|house|trance|dubstep|drum|edm|synth|ambient|'
    r'classical|folk|country|reggae|ska|samba|bossa|mpb|sertanejo|forr|pagode|ax[eé]|gospel|indie|alternative|grunge|emo|core\b|'
    r'industrial|gothic|wave|lo.?fi|chill|vocaloid|anime|j-?pop|k-?pop|j-?rock|soundtrack|latin|reggaeton|cumbia|swing|opera|instrumental|dance|idm|shoegaze|ballad',
    caseSensitive: false);

/// Vazio ou sem significado ("Music", "Other", "(12)"...): vale procurar o gênero real.
bool isGenericGenre(String genre) {
  final g = genre.replaceAll('\u0000', '').trim().toLowerCase();
  if (g.isEmpty || _generic.contains(g)) return true;
  // código numérico do ID3v1 sem tradução, ex.: "(12)" ou "255"
  return RegExp(r'^\(?\d+\)?$').hasMatch(g);
}

/// O primeiro gênero de verdade da lista (as tags podem ter vários), ou ''.
String realGenre(Iterable<String> genres) {
  for (final g in genres) {
    final c = g.replaceAll('\u0000', '').trim();
    if (!isGenericGenre(c)) return c;
  }
  return '';
}

/// "industrial metal" -> "Industrial Metal".
String titleCaseGenre(String g) =>
    g.trim().split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

/// Gênero tirado das tags do Last.fm: a tag mais usada que parece gênero (ignora "seen live", "favorites"...).
String? genreFromTags(List<MusicTag> tags) {
  final sorted = [...tags]..sort((a, b) => b.count.compareTo(a.count));
  for (final t in sorted) {
    if (genreWords.hasMatch(t.name) && !isGenericGenre(t.name)) return titleCaseGenre(t.name);
  }
  return null;
}
