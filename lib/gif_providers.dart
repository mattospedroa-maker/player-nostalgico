import 'dart:convert';

import 'package:http/http.dart' as http;

import 'service_health.dart';

/// Tipo do GIF na seleção: anime ou geral (cena, filme, paisagem...). Vem do metadado, não só da fonte.
enum GifKind { anime, general }

/// Um GIF encontrado numa fonte online.
class GifCandidate {
  final String url;
  final String source; // "openverse", "wikimedia"
  final String credit; // autor + licença, para o arquivo de créditos
  /// Categoria do clima de anime ("dance"), quando veio de uma; serve para emprestar GIFs guardados depois.
  final String? category;

  /// Texto que a fonte dá sobre o GIF (título, tags, nome do anime): serve para medir a relevância e o tipo.
  final String meta;

  /// Preenchidos na seleção: pesquisa que achou o GIF, nota de relevância e tipo.
  final String query;
  final double score;
  final GifKind? kind;
  const GifCandidate(
      {required this.url, required this.source, this.credit = '', this.category, this.meta = '', this.query = '', this.score = 0, this.kind});

  GifCandidate ranked({required String query, required double score, required GifKind kind}) =>
      GifCandidate(url: url, source: source, credit: credit, category: category, meta: meta, query: query, score: score, kind: kind);
}

abstract class GifProvider {
  String get name;

  /// false = os termos da fonte proíbem download em massa; fica fora do "Baixar GIFs para todas".
  bool get allowBulk => true;

  /// true = só GIFs de anime; usada só com palavras extras ou gênero de anime/J-pop.
  bool get animeOnly => false;

  Future<List<GifCandidate>> search(String query, {int limit = 20});
}

const _ua = 'PlayerNostalgico/0.2 (app pessoal offline)';

/// Openverse: acervo de imagens com licenças livres (permite baixar e guardar, com crédito).
/// Termos do Openverse: respeitar o limite de pedidos (sem chave: até 20 por página, ~1 pedido/s),
/// não raspar o acervo e dar crédito conforme a licença CC de cada obra (vai para `creditos.txt`).
class OpenverseProvider extends GifProvider {
  final http.Client client;
  final bool _bulk;
  final Duration minInterval;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  OpenverseProvider(this.client, {bool allowBulk = true, this.minInterval = Duration.zero}) : _bulk = allowBulk;

  @override
  String get name => 'Openverse';

  @override
  bool get allowBulk => _bulk;

  @override
  Future<List<GifCandidate>> search(String query, {int limit = 20}) async {
    final wait = minInterval - DateTime.now().difference(_last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _last = DateTime.now();
    limit = limit.clamp(1, 20);
    final uri = Uri.https('api.openverse.org', '/v1/images/', {
      'q': query,
      'extension': 'gif',
      'page_size': '$limit',
      'mature': 'false',
    });
    final res = await client.get(uri, headers: {'User-Agent': _ua, 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
    if (res.statusCode == 429 || res.statusCode >= 500) throw ServiceDown(name, res.statusCode);
    if (res.statusCode != 200) return const [];
    return parse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  static List<GifCandidate> parse(Map<String, dynamic> json) {
    final out = <GifCandidate>[];
    for (final r in (json['results'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final url = r['url'] as String?;
      if (url == null || !url.toLowerCase().contains('.gif')) continue;
      final lic = '${r['license'] ?? ''} ${r['license_version'] ?? ''}'.trim().toUpperCase();
      out.add(GifCandidate(
        url: url,
        source: 'openverse',
        credit: '${r['title'] ?? ''} · ${r['creator'] ?? 'autor desconhecido'} · CC $lic · ${r['foreign_landing_url'] ?? url} · via Openverse',
        meta: [
          '${r['title'] ?? ''}',
          for (final t in (r['tags'] as List? ?? const []))
            if (t is Map && t['name'] is String) t['name'] as String,
        ].join(' '),
      ));
    }
    return out;
  }
}

/// Wikimedia Commons: arquivos livres; busca só GIFs.
class WikimediaProvider extends GifProvider {
  final http.Client client;
  final bool _bulk;
  WikimediaProvider(this.client, {bool allowBulk = true}) : _bulk = allowBulk;

  @override
  String get name => 'Wikimedia';

  @override
  bool get allowBulk => _bulk;

  @override
  Future<List<GifCandidate>> search(String query, {int limit = 20}) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'generator': 'search',
      'gsrsearch': 'filetype:bitmap filemime:image/gif $query',
      'gsrnamespace': '6',
      'gsrlimit': '$limit',
      'prop': 'imageinfo',
      'iiprop': 'url|size|mime|extmetadata',
      'iiextmetadatafilter': 'Artist|LicenseShortName|ImageDescription|Categories',
    });
    final res = await client.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
    if (res.statusCode == 429 || res.statusCode >= 500) throw ServiceDown(name, res.statusCode);
    if (res.statusCode != 200) return const [];
    return parse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  static List<GifCandidate> parse(Map<String, dynamic> json) {
    final pages = (json['query']?['pages'] as Map<String, dynamic>?)?.values.cast<Map<String, dynamic>>().toList() ?? [];
    pages.sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    final out = <GifCandidate>[];
    for (final pg in pages) {
      final info = (pg['imageinfo'] as List?)?.cast<Map<String, dynamic>>().firstOrNull;
      if (info == null || info['mime'] != 'image/gif') continue;
      if (((info['size'] as num?) ?? 0) > 8 * 1024 * 1024) continue;
      final meta = info['extmetadata'] as Map<String, dynamic>? ?? const {};
      String strip(String? s) => (s ?? '').replaceAll(RegExp(r'<[^>]*>'), '').trim();
      out.add(GifCandidate(
        url: info['url'] as String,
        source: 'wikimedia',
        credit: '${pg['title']} · ${strip(meta['Artist']?['value'] as String?)} · ${strip(meta['LicenseShortName']?['value'] as String?)} · ${info['descriptionurl'] ?? info['url']}',
        meta: '${'${pg['title'] ?? ''}'.replaceFirst(RegExp(r'^File:'), '').replaceAll(RegExp(r'\.gif$', caseSensitive: false), '')} '
            '${strip(meta['ImageDescription']?['value'] as String?)} ${strip(meta['Categories']?['value'] as String?).replaceAll('|', ' ')}',
      ));
    }
    return out;
  }
}

/// Fonte de GIFs de anime por categoria de clima ("dance", "cry"...). Se a primeira cair, a próxima entra.
abstract class AnimeMoodSource {
  String get name;
  Future<List<GifCandidate>> random(String category, {int amount = 5});
}

/// nekos.best: GIFs de anime (busca pelo nome do anime). Termos: só uso pessoal, sem download em massa,
/// 7 buscas a cada 5 s. Por isso só é usada música a música, nunca no "Baixar para todas".
class NekosBestProvider extends GifProvider implements AnimeMoodSource {
  final http.Client client;
  final Duration minInterval;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  NekosBestProvider(this.client, {this.minInterval = const Duration(milliseconds: 800)});

  @override
  String get name => 'nekos.best';

  @override
  bool get allowBulk => false;

  @override
  bool get animeOnly => true;

  @override
  Future<List<GifCandidate>> search(String query, {int limit = 20}) async {
    final wait = minInterval - DateTime.now().difference(_last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _last = DateTime.now();
    final uri = Uri.https('nekos.best', '/api/v2/search', {'query': query, 'type': '2', 'amount': '${limit.clamp(1, 20)}'});
    final res = await client.get(uri, headers: {'User-Agent': 'PlayerNostalgico (app pessoal offline)'}).timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) return const [];
    if (res.statusCode != 200) throw ServiceDown(name, res.statusCode);
    return parse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  /// GIFs aleatórios de uma categoria (ex.: "punch", "dance"), para combinar com o clima da música.
  @override
  Future<List<GifCandidate>> random(String category, {int amount = 5}) async {
    final uri = Uri.https('nekos.best', '/api/v2/$category', {'amount': '${amount.clamp(1, 20)}'});
    final res = await client.get(uri, headers: {'User-Agent': 'PlayerNostalgico (app pessoal offline)'}).timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) return const []; // categoria que não existe
    if (res.statusCode != 200) throw ServiceDown(name, res.statusCode);
    return parse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  static List<GifCandidate> parse(Map<String, dynamic> json) => [
        for (final r in (json['results'] as List? ?? const []).cast<Map<String, dynamic>>())
          if (r['url'] is String)
            GifCandidate(
                url: r['url'] as String,
                source: 'nekos.best',
                credit: '${r['anime_name'] ?? 'anime'} · via nekos.best · ${r['url']}',
                meta: 'anime ${r['anime_name'] ?? ''}'),
      ];
}

/// waifu.pics: reserva de GIFs de anime quando o nekos.best cai. Só tem categorias (não busca por nome),
/// então entra só nos GIFs do clima. Os nomes das categorias são um pouco diferentes: [categoryFor] traduz.
class WaifuPicsProvider implements AnimeMoodSource {
  final http.Client client;
  WaifuPicsProvider(this.client);

  @override
  String get name => 'waifu.pics';

  /// Categorias do nekos.best -> as mais parecidas do waifu.pics (null = não tem nada parecido).
  static const _map = {
    'dance': 'dance', 'happy': 'happy', 'smile': 'smile', 'wave': 'wave', 'wink': 'wink', 'hug': 'hug',
    'cuddle': 'cuddle', 'kiss': 'kiss', 'handhold': 'handhold', 'blush': 'blush', 'cry': 'cry', 'pat': 'pat',
    'highfive': 'highfive', 'kick': 'kick', 'slap': 'slap', 'yeet': 'yeet', 'smug': 'smug', 'bite': 'bite',
    'poke': 'poke', 'punch': 'bonk', 'angry': 'bully', 'shoot': 'yeet', 'laugh': 'happy', 'clap': 'happy',
    'thumbsup': 'smile', 'nod': 'smile', 'run': 'glomp', 'sleep': 'cuddle', 'yawn': 'cuddle', 'pout': 'cry',
  };

  static String? categoryFor(String nekosCategory) => _map[nekosCategory];

  @override
  Future<List<GifCandidate>> random(String category, {int amount = 5}) async {
    final cat = categoryFor(category);
    if (cat == null) return const [];
    final res = await client
        .post(Uri.https('api.waifu.pics', '/many/sfw/$cat'),
            headers: {'User-Agent': _ua, 'Content-Type': 'application/json'}, body: '{"exclude":[]}')
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) return const [];
    if (res.statusCode != 200) throw ServiceDown(name, res.statusCode);
    return parse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>, category, amount: amount);
  }

  /// Só os .gif (a categoria mistura imagens paradas). [category] é a do nekos.best, para lembrar o clima.
  static List<GifCandidate> parse(Map<String, dynamic> json, String category, {int amount = 5}) => [
        for (final u in (json['files'] as List? ?? const []).whereType<String>())
          if (u.toLowerCase().endsWith('.gif')) GifCandidate(url: u, source: 'waifu.pics', credit: 'anime · via waifu.pics · $u', category: category, meta: 'anime $category'),
      ].take(amount).toList();
}

/// Um resultado do GIPHY: miniatura leve para a grade e o GIF inteiro para baixar.
class GiphyGif {
  final String id;
  final String title;
  final String previewUrl;
  final String url;
  final String pageUrl;

  /// Versão leve para miniatura (WebP animado de 200 px, ~100–300 KB). Vazio = usar [previewUrl].
  final String tileUrl;
  const GiphyGif({required this.id, required this.title, required this.previewUrl, required this.url, required this.pageUrl, this.tileUrl = ''});
}

/// Erros do GIPHY que a tela explica para o usuário.
enum GiphyError { noKey, invalidKey, network, badResponse }

class GiphyException implements Exception {
  final GiphyError error;
  const GiphyException(this.error);
  String get message => switch (error) {
        GiphyError.noKey => 'Chave do GIPHY não configurada',
        GiphyError.invalidKey => 'Chave do GIPHY inválida',
        GiphyError.network => 'GIPHY fora do ar ou sem internet',
        GiphyError.badResponse => 'Resposta estranha do GIPHY',
      };
  @override
  String toString() => message;
}

/// GIPHY: aceita pesquisas por frase ("rain scenery"). Só para a tela de resultados,
/// baixando um GIF por vez quando o usuário toca (os termos do GIPHY proíbem guardar em massa).
class GiphyProvider {
  final http.Client client;
  final String? apiKey;
  GiphyProvider(this.client, this.apiKey);

  static const pageSize = 12;

  Future<List<GiphyGif>> search(String query, {int offset = 0, int limit = pageSize}) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) throw const GiphyException(GiphyError.noKey);
    final uri = Uri.https('api.giphy.com', '/v1/gifs/search', {
      'api_key': key,
      'q': query,
      'limit': '$limit',
      'offset': '$offset',
      'rating': 'pg-13',
      'lang': 'en',
    });
    http.Response res;
    try {
      res = await client.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const GiphyException(GiphyError.network);
    }
    return parse(res.statusCode, res.body);
  }

  static List<GiphyGif> parse(int status, String body) {
    if (status == 401 || status == 403) throw const GiphyException(GiphyError.invalidKey);
    if (status == 429 || status >= 500) throw const GiphyException(GiphyError.network);
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw const GiphyException(GiphyError.badResponse);
    }
    if (json is! Map || json['data'] is! List) throw const GiphyException(GiphyError.badResponse);
    final out = <GiphyGif>[];
    for (final d in json['data'] as List) {
      if (d is! Map || d['images'] is! Map) continue;
      final img = d['images'] as Map;
      String? pick(List<String> names) {
        for (final n in names) {
          final v = img[n];
          if (v is Map && v['url'] is String && (v['url'] as String).isNotEmpty) return v['url'] as String;
        }
        return null;
      }

      final preview = pick(['fixed_width_small', 'fixed_width', 'preview_gif', 'downsized']);
      final full = pick(['downsized_medium', 'downsized', 'original', 'fixed_width']);
      if (preview == null || full == null) continue;
      final fw = img['fixed_width'];
      final webp = fw is Map && fw['webp'] is String ? fw['webp'] as String : '';
      out.add(GiphyGif(id: '${d['id']}', title: '${d['title'] ?? ''}', previewUrl: preview, url: full, pageUrl: '${d['url'] ?? ''}', tileUrl: webp));
    }
    return out;
  }
}
