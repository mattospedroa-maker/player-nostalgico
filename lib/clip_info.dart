import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'error_log.dart';
import 'visual_tags.dart';

/// O que a Wikipédia conta sobre o videoclipe da música.
class ClipInfo {
  /// Título do artigo (ex.: "Zeit (song)").
  final String article;

  /// Texto da seção do videoclipe, sem marcação.
  final String text;

  /// Cenas reconhecidas no texto (chave do dicionário -> vezes que apareceu).
  final Map<String, int> scenes;

  const ClipInfo(this.article, this.text, this.scenes);

  bool get hasScenes => scenes.isNotEmpty;

  /// Rótulos das cenas, da mais citada para a menos (para mostrar "Do clipe: ...").
  List<String> get sceneLabels {
    final keys = scenes.keys.toList()..sort((a, b) => scenes[b]!.compareTo(scenes[a]!));
    return [for (final k in keys) visualTags.firstWhere((e) => e.key == k).label];
  }
}

/// Procura o artigo da música na Wikipédia (inglês, que cobre mais clipes) e lê a seção do videoclipe.
/// Sem IA: as cenas saem de palavras do dicionário de cenas ([visualTags] com [VisualTag.scene]).
class ClipInfoClient {
  final http.Client client;
  ClipInfoClient(this.client);

  /// false = a última consulta não chegou na Wikipédia (sem internet); aí não vale guardar "sem clipe".
  bool reached = true;

  static const _host = 'en.wikipedia.org';
  static const _headers = {'User-Agent': 'NostalgicMPlayer/1.0 (app pessoal de musica offline)'};

  Future<Map<String, dynamic>?> _get(Map<String, String> params) async {
    try {
      final res = await client
          .get(Uri.https(_host, '/w/api.php', {...params, 'format': 'json', 'formatversion': '2'}), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        reached = false;
        return null;
      }
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      return j is Map<String, dynamic> ? j : null;
    } catch (e) {
      errorLog.info('GIFs', 'Wikipédia não respondeu (cenas do clipe)', e);
      reached = false;
      return null;
    }
  }

  /// null = não achou artigo ou o artigo não fala do clipe.
  Future<ClipInfo?> lookup(String artist, String title) async {
    reached = true;
    if (artist.trim().isEmpty || title.trim().isEmpty) return null;
    final search = await _get({'action': 'query', 'list': 'search', 'srsearch': '"$title" $artist song', 'srlimit': '6'});
    final article = pickArticle(search, artist, title);
    if (article == null) return null;
    final sections = await _get({'action': 'parse', 'page': article, 'prop': 'sections'});
    final index = videoSection(sections);
    if (index == null) return null;
    final body = await _get({'action': 'parse', 'page': article, 'section': index, 'prop': 'wikitext'});
    final wikitext = body?['parse'] is Map ? '${(body!['parse'] as Map)['wikitext'] ?? ''}' : '';
    final text = plainText(wikitext);
    if (text.length < 40) return null;
    return ClipInfo(article, text, scenesIn(text));
  }

  /// Escolhe o artigo da música: título parecido e que fale do artista.
  static String? pickArticle(Map<String, dynamic>? json, String artist, String title) {
    final list = json?['query'] is Map ? (json!['query'] as Map)['search'] : null;
    if (list is! List) return null;
    final t = VisualTagMapper.normalize(title);
    final a = VisualTagMapper.normalize(artist);
    for (final r in list) {
      if (r is! Map) continue;
      final name = '${r['title'] ?? ''}';
      final n = VisualTagMapper.normalize(name.replaceAll(RegExp(r'\s*\(.*?\)\s*'), ' ').trim());
      final snippet = VisualTagMapper.normalize('${r['snippet'] ?? ''}'.replaceAll(RegExp(r'<[^>]+>'), ''));
      // "Zeit (song)", "Zeit (Rammstein song)"; não aceita o álbum nem a página do artista
      if (n == t && (snippet.contains(a) || VisualTagMapper.normalize(name).contains(a) || name.toLowerCase().contains('song'))) {
        if (name.toLowerCase().contains('album')) continue;
        return name;
      }
    }
    return null;
  }

  /// Número da seção "Music video" (ou parecida).
  static String? videoSection(Map<String, dynamic>? json) {
    final secs = json?['parse'] is Map ? (json!['parse'] as Map)['sections'] : null;
    if (secs is! List) return null;
    for (final s in secs) {
      if (s is! Map) continue;
      final line = '${s['line'] ?? ''}'.toLowerCase();
      if (RegExp(r'music video|video clip|videoclip|\bvideo\b').hasMatch(line)) return '${s['index']}';
    }
    return null;
  }

  /// Wikitext -> texto simples (tira referências, predefinições, links e formatação).
  static String plainText(String w) {
    var s = w;
    s = s.replaceAll(RegExp(r'<ref[^>/]*/>'), ' ');
    s = s.replaceAll(RegExp(r'<ref[^>]*>.*?</ref>', dotAll: true), ' ');
    s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ');
    for (var i = 0; i < 4; i++) {
      s = s.replaceAll(RegExp(r'\{\{[^{}]*\}\}'), ' ');
    }
    s = s.replaceAll(RegExp(r'\[\[(?:File|Image|Arquivo):[^\]]*\]\]'), ' ');
    s = s.replaceAllMapped(RegExp(r'\[\[(?:[^|\]]*\|)?([^\]]*)\]\]'), (m) => m[1]!);
    s = s.replaceAllMapped(RegExp(r'\[https?://\S+\s([^\]]*)\]'), (m) => m[1]!);
    s = s.replaceAll(RegExp(r"'{2,}"), '');
    s = s.replaceAll(RegExp(r'^=+.*?=+\s*$', multiLine: true), ' ');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Conta as cenas do dicionário que aparecem no texto (palavra inteira, sem diferença de maiúsculas).
  static Map<String, int> scenesIn(String text) {
    final t = ' ${VisualTagMapper.normalize(text).replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')} ';
    final out = <String, int>{};
    for (final e in visualTags.where((e) => e.scene)) {
      var n = 0;
      for (final w in [e.key, ...e.aliases]) {
        n += RegExp(' ${RegExp.escape(VisualTagMapper.normalize(w))} ').allMatches(t).length;
      }
      if (n > 0) out[e.key] = n;
    }
    return out;
  }
}

/// Cache das cenas do clipe por música (`GIFs/.clipes.json`), para não consultar de novo.
class ClipCache {
  final File file;
  Map<String, dynamic>? _data;
  ClipCache(this.file);

  Map<String, dynamic> get _map {
    if (_data != null) return _data!;
    try {
      _data = file.existsSync() ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>() : {};
    } catch (e) {
      errorLog.info('GIFs', 'Cache das cenas de clipe estava ilegível e foi recomeçado', e);
      _data = {};
    }
    return _data!;
  }

  static String keyFor(String artist, String title) => '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';

  /// (achou no cache, info). info null = já procurou e não tem clipe descrito.
  (bool, ClipInfo?) get(String artist, String title) {
    final e = _map[keyFor(artist, title)];
    if (e is! Map) return (false, null);
    final at = DateTime.tryParse('${e['t']}');
    if (at == null || DateTime.now().difference(at) > const Duration(days: 90)) return (false, null);
    if (e['a'] == null) return (true, null);
    final scenes = <String, int>{for (final m in ((e['s'] as Map?) ?? const {}).entries) '${m.key}': (m.value as num).toInt()};
    return (true, ClipInfo('${e['a']}', '', scenes));
  }

  void put(String artist, String title, ClipInfo? info, {required bool reached}) {
    if (!reached) return; // sem internet: tenta outra vez depois
    _map[keyFor(artist, title)] = {'t': DateTime.now().toIso8601String(), 'a': info?.article, 's': info?.scenes ?? const {}};
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_map));
    } catch (e) {
      errorLog.warn('GIFs', 'Não deu para salvar o cache das cenas de clipe', error: e);
    }
  }
}
