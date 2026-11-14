import 'dart:convert';

import 'package:http/http.dart' as http;

/// Um GIF encontrado numa fonte online.
class GifCandidate {
  final String url;
  final String source; // "openverse", "wikimedia"
  final String credit; // autor + licença, para o arquivo de créditos
  const GifCandidate({required this.url, required this.source, this.credit = ''});
}

abstract class GifProvider {
  String get name;
  Future<List<GifCandidate>> search(String query, {int limit = 20});
}

const _ua = 'PlayerNostalgico/0.2 (app pessoal offline)';

/// Openverse: acervo de imagens com licenças livres (permite baixar e guardar, com crédito).
class OpenverseProvider implements GifProvider {
  final http.Client client;
  OpenverseProvider(this.client);

  @override
  String get name => 'Openverse';

  @override
  Future<List<GifCandidate>> search(String query, {int limit = 20}) async {
    final uri = Uri.https('api.openverse.org', '/v1/images/', {
      'q': query,
      'extension': 'gif',
      'page_size': '$limit',
      'mature': 'false',
    });
    final res = await client.get(uri, headers: {'User-Agent': _ua, 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
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
        credit: '${r['title'] ?? ''} · ${r['creator'] ?? 'autor desconhecido'} · CC $lic · ${r['foreign_landing_url'] ?? url}',
      ));
    }
    return out;
  }
}

/// Wikimedia Commons: arquivos livres; busca só GIFs.
class WikimediaProvider implements GifProvider {
  final http.Client client;
  WikimediaProvider(this.client);

  @override
  String get name => 'Wikimedia';

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
      'iiextmetadatafilter': 'Artist|LicenseShortName',
    });
    final res = await client.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
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
      ));
    }
    return out;
  }
}
