import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'error_log.dart';

/// Fotos dos artistas e bandas, para aparecer de vez em quando entre os GIFs do Tocando agora.
///
/// Fontes (sem chave): Deezer (foto oficial do artista) e Wikipédia (foto da página, em inglês e em
/// português). Ficam guardadas em `dataDir/artistas/` e depois funcionam offline.
class ArtistPhotoService {
  final String dir;
  final http.Client client;

  /// Não procura de novo um artista que não teve foto antes disso.
  final Duration retryAfter;

  ArtistPhotoService(String dataDir, {http.Client? client, this.retryAfter = const Duration(days: 7)})
      : dir = p.join(dataDir, 'artistas'),
        client = client ?? http.Client();

  static const maxPhotos = 2;
  static const _ua = 'PlayerNostalgico/1.0 (app pessoal offline)';

  static String keyFor(String artist) => sha1.convert(utf8.encode(_norm(artist))).toString().substring(0, 16);

  /// Fotos já guardadas do artista (pode ser vazio).
  List<String> photosFor(String artist) {
    if (_norm(artist).isEmpty) return const [];
    final k = keyFor(artist);
    return [
      for (var i = 1; i <= maxPhotos; i++)
        if (File(p.join(dir, '${k}_$i.jpg')).existsSync()) p.join(dir, '${k}_$i.jpg'),
    ];
  }

  /// O arquivo é uma foto de artista guardada por este serviço?
  bool isPhoto(String path) => p.isWithin(dir, path);

  final Set<String> _running = {};

  /// Baixa as fotos que faltam (uma vez; se não achar, tenta de novo depois de [retryAfter]).
  /// Devolve quantas fotos novas guardou.
  Future<int> fetch(String artist) async {
    final name = artist.trim();
    if (_norm(name).length < 2 || _isUnknown(name)) return 0;
    final k = keyFor(name);
    if (photosFor(name).length >= maxPhotos || !_running.add(k)) return 0;
    try {
      final tried = _readTried();
      final last = DateTime.tryParse('${tried[k] ?? ''}');
      if (last != null && DateTime.now().difference(last) < retryAfter) return 0;
      final urls = <String>[];
      for (final source in [_deezer, _wikipedia]) {
        try {
          final u = await source(name);
          if (u != null && !urls.contains(u)) urls.add(u);
        } catch (e) {
          errorLog.info('Fotos', 'Foto de "$name" não veio de uma das fontes', e);
        }
      }
      var n = 0;
      var slot = photosFor(name).length + 1;
      final have = {for (final f in photosFor(name)) _hash(File(f).readAsBytesSync())};
      for (final u in urls) {
        if (slot > maxPhotos) break;
        final bytes = await _download(u);
        if (bytes == null || !have.add(_hash(bytes))) continue;
        await Directory(dir).create(recursive: true);
        await File(p.join(dir, '${k}_$slot.jpg')).writeAsBytes(bytes, flush: true);
        slot++;
        n++;
      }
      tried[k] = DateTime.now().toIso8601String();
      _writeTried(tried);
      return n;
    } finally {
      _running.remove(k);
    }
  }

  /// Deezer: procura o artista e confere se o nome bate (para não pegar a foto de outro).
  Future<String?> _deezer(String artist) async {
    final res = await client
        .get(Uri.https('api.deezer.com', '/search/artist', {'q': artist, 'limit': '5'}), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    return parseDeezer(jsonDecode(utf8.decode(res.bodyBytes)), artist);
  }

  static String? parseDeezer(Object? json, String artist) {
    if (json is! Map || json['data'] is! List) return null;
    for (final a in (json['data'] as List).whereType<Map>()) {
      if (!sameName('${a['name']}', artist)) continue;
      final url = (a['picture_xl'] ?? a['picture_big']) as String?;
      // artista sem foto: o Deezer manda uma silhueta padrão (endereço com o hash vazio)
      if (url == null || url.contains('/artist//') || url.contains('d41d8cd98f00b204e9800998ecf8427e')) return null;
      return url;
    }
    return null;
  }

  /// Wikipédia: foto principal da página do artista. Tenta em inglês e depois em português.
  Future<String?> _wikipedia(String artist) async {
    for (final lang in ['en', 'pt']) {
      final res = await client.get(
          Uri.https('$lang.wikipedia.org', '/w/api.php', {
            'action': 'query',
            'format': 'json',
            'generator': 'search',
            'gsrsearch': artist,
            'gsrlimit': '3',
            'prop': 'pageimages|description',
            'piprop': 'thumbnail',
            'pithumbsize': '800',
          }),
          headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) continue;
      final u = parseWikipedia(jsonDecode(utf8.decode(res.bodyBytes)), artist);
      if (u != null) return u;
    }
    return null;
  }

  /// Pega a página cujo título é o nome do artista (ou "Nome (banda)") e que fala de música.
  static String? parseWikipedia(Object? json, String artist) {
    final pages = json is Map ? (json['query']?['pages'] as Map?)?.values.whereType<Map>().toList() : null;
    if (pages == null) return null;
    pages.sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    final musical = RegExp(
        r'band|singer|rapper|musician|music|group|duo|dj\b|producer|songwriter|cantor|cantora|banda|grupo|músic|compositor|dupla|rapper|mc\b',
        caseSensitive: false);
    for (final pg in pages) {
      final title = '${pg['title'] ?? ''}'.replaceAll(RegExp(r'\s*\(.*\)$'), '');
      if (!sameName(title, artist)) continue;
      final desc = '${pg['description'] ?? ''} ${pg['title']}';
      if (!musical.hasMatch(desc)) continue;
      final src = pg['thumbnail']?['source'] as String?;
      // logotipos e capas em .svg/.png não são foto da pessoa
      if (src == null || !RegExp(r'\.jpe?g', caseSensitive: false).hasMatch(src)) continue;
      return src;
    }
    return null;
  }

  Future<List<int>?> _download(String url) async {
    try {
      final res = await client.get(Uri.parse(url), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 30));
      final b = res.bodyBytes;
      if (res.statusCode != 200 || b.length < 4096 || b.length > 6 * 1024 * 1024) return null;
      if (!(b[0] == 0xFF && b[1] == 0xD8)) return null; // só JPG
      return b;
    } catch (e) {
      errorLog.info('Fotos', 'Download de uma foto de artista falhou', e);
      return null;
    }
  }

  static String _hash(List<int> b) => sha1.convert(b).toString();

  File get _triedFile => File(p.join(dir, '.buscas.json'));

  Map<String, dynamic> _readTried() {
    try {
      if (_triedFile.existsSync()) return (jsonDecode(_triedFile.readAsStringSync()) as Map).cast<String, dynamic>();
    } catch (e) {
      errorLog.info('Fotos', 'Registro de buscas de fotos ilegível, recomeçado', e);
    }
    return {};
  }

  void _writeTried(Map<String, dynamic> m) {
    try {
      _triedFile
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(m));
    } catch (e) {
      errorLog.info('Fotos', 'Não deu para salvar o registro de buscas de fotos', e);
    }
  }

  static bool _isUnknown(String a) => RegExp(r'^(desconhecido|unknown|various artists|vários artistas|<unknown>)$', caseSensitive: false).hasMatch(a);

  /// Mesmo nome, sem ligar para maiúsculas, acentos, "The" e pontuação ("The Beatles" = "beatles").
  static bool sameName(String a, String b) {
    final x = _norm(a), y = _norm(b);
    return x.isNotEmpty && x == y;
  }

  static String _norm(String s) {
    var t = s.toLowerCase().trim();
    const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    const to = 'aaaaaeeeeiiiiooooouuuucn';
    for (var i = 0; i < from.length; i++) {
      t = t.replaceAll(from[i], to[i]);
    }
    t = t.replaceFirst(RegExp(r'^the\s+'), '').replaceAll('&', 'and');
    return t.replaceAll(RegExp(r'[^a-z0-9぀-ヿ一-鿿가-힣]+'), '');
  }
}

/// Junta a capa e as fotos entre os GIFs: uma imagem extra depois de cada [every] GIFs, sem tirar nenhum GIF.
/// Se há poucos GIFs, as que sobram vão no fim (sem GIF nenhum, a roda fica só com elas).
List<String> mixExtras(List<String> gifs, List<String> extras, {int every = 3}) {
  if (extras.isEmpty) return gifs;
  final out = <String>[];
  var e = 0;
  for (var i = 0; i < gifs.length; i++) {
    out.add(gifs[i]);
    if ((i + 1) % every == 0 && e < extras.length) out.add(extras[e++]);
  }
  out.addAll(extras.skip(e));
  return out;
}
