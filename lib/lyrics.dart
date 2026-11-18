import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'error_log.dart';
import 'visual_tags.dart';

/// Uma cena tirada da letra: a chave (igual às cenas do clipe quando existe) e a pesquisa de GIF.
class LyricScene {
  final String key;
  final String query;
  const LyricScene(this.key, this.query);

  @override
  bool operator ==(Object other) => other is LyricScene && other.key == key && other.query == query;
  @override
  int get hashCode => Object.hash(key, query);
  @override
  String toString() => '$key: $query';
}

/// Tema da letra, sem mostrar e sem gravar a letra: só as cenas que ela cita.
/// Por dicionário (português e inglês), sem IA, casando cenas que o app já conhece.
class LyricScenes {
  /// Só o começo da letra conta (o tema costuma aparecer logo).
  static const maxChars = 600;

  /// Máximo de cenas por música.
  static const maxScenes = 4;

  /// Palavras -> cena. A ordem só desempata; o que vale é onde a palavra aparece primeiro na letra.
  static const _dict = <(String, String, List<String>)>[
    ('rain', 'rain window night', ['chuva', 'chuvas', 'rain', 'rains', 'raining', 'storm', 'storms', 'tempestade']),
    ('car', 'night drive aesthetic', ['carro', 'carros', 'car', 'cars', 'highway', 'highways', 'estrada', 'estradas', 'drive', 'driving']),
    ('city', 'city night lights', ['cidade', 'cidades', 'city', 'cities', 'street', 'streets', 'rua', 'ruas', 'neon']),
    ('ocean', 'ocean waves', ['mar', 'ocean', 'oceano', 'praia', 'praias', 'beach', 'sea']),
    ('night', 'night scenery', ['noite', 'noites', 'night', 'nights', 'midnight', 'madrugada']),
    ('war', 'war battlefield', ['guerra', 'guerras', 'war', 'wars', 'battle', 'battles', 'batalha']),
    ('snow', 'snow falling scenery', ['neve', 'snow', 'snowing', 'winter', 'inverno']),
  ];

  static final List<(String, String, RegExp)> _res = [
    for (final (k, q, words) in _dict) (k, q, RegExp('\\b(${words.map(RegExp.escape).join('|')})\\b')),
  ];

  /// Cenas da letra, na ordem em que aparecem, sem repetir e no máximo [maxScenes].
  static List<LyricScene> extract(String lyrics) {
    final head = lyrics.length > maxChars ? lyrics.substring(0, maxChars) : lyrics;
    final t = VisualTagMapper.normalize(head).replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    final found = <(int, LyricScene)>[];
    for (final (k, q, re) in _res) {
      final m = re.firstMatch(t);
      if (m != null) found.add((m.start, LyricScene(k, q)));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, s) in found.take(maxScenes)) s];
  }

  /// Chave guardada -> cena (para ler o cache).
  static LyricScene? byKey(String key) {
    for (final (k, q, _) in _dict) {
      if (k == key) return LyricScene(k, q);
    }
    return null;
  }
}

/// Busca a letra para tirar as cenas: LRCLIB primeiro; se não tiver, lyrics.ovh.
/// A letra não sai daqui: quem chama recebe só as cenas.
class LyricsClient {
  final http.Client client;
  LyricsClient(this.client);

  /// false = a última consulta não chegou em nenhum serviço (sem internet); aí não vale guardar "sem letra".
  bool reached = true;

  static const _headers = {'User-Agent': 'NostalgicMPlayer/1.0 (app pessoal de musica offline)'};

  static Uri lrclibUrl(String artist, String title, String album) => Uri.https('lrclib.net', '/api/get', {
        'artist_name': artist,
        'track_name': title,
        if (album.trim().isNotEmpty) 'album_name': album,
      });

  static Uri ovhUrl(String artist, String title) => Uri.https('api.lyrics.ovh', '/v1/$artist/$title');

  /// Cenas da letra. Vazio = sem letra ou sem cena conhecida. Nunca lança erro.
  Future<List<LyricScene>> scenes(String artist, String title, {String album = ''}) async {
    reached = true;
    if (artist.trim().isEmpty || title.trim().isEmpty) return const [];
    final text = await _lyrics(artist.trim(), title.trim(), album.trim());
    return text == null ? const [] : LyricScenes.extract(text);
  }

  Future<String?> _lyrics(String artist, String title, String album) async {
    final (s1, b1) = await _get(lrclibUrl(artist, title, album));
    if (s1 == 200) {
      final t = parseLrclib(b1);
      if (t != null) return t;
    }
    // LRCLIB não tem (404) ou não respondeu: tenta o lyrics.ovh
    final (s2, b2) = await _get(ovhUrl(artist, title));
    if (s2 == 200) return parseOvh(b2);
    // os dois falharam sem dizer "não tem": provavelmente sem internet
    if (s1 != 404 && s1 != 200 && s2 != 404) reached = false;
    return null;
  }

  Future<(int, String)> _get(Uri uri) async {
    try {
      final res = await client.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      return (res.statusCode, utf8.decode(res.bodyBytes, allowMalformed: true));
    } catch (e) {
      errorLog.info('GIFs', 'Serviço de letras não respondeu (${uri.host})', e);
      return (0, '');
    }
  }

  /// Letra simples do LRCLIB (ou a sincronizada sem os tempos).
  static String? parseLrclib(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final plain = '${j['plainLyrics'] ?? ''}'.trim();
      if (plain.isNotEmpty) return plain;
      final synced = '${j['syncedLyrics'] ?? ''}'.replaceAll(RegExp(r'\[[0-9:.]+\]'), ' ').trim();
      return synced.isEmpty ? null : synced;
    } catch (_) {
      return null;
    }
  }

  static String? parseOvh(String body) {
    try {
      final j = jsonDecode(body);
      final t = j is Map ? '${j['lyrics'] ?? ''}'.trim() : '';
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }
}

/// Cenas da letra por música (`GIFs/.lyrics.json`). Guarda só as chaves das cenas, nunca a letra.
class LyricsCache {
  final File file;
  final Duration maxAge;
  Map<String, dynamic>? _data;
  LyricsCache(this.file, {this.maxAge = const Duration(days: 90)});

  static String keyFor(String artist, String title) => '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';

  Map<String, dynamic> get _map {
    if (_data != null) return _data!;
    try {
      _data = file.existsSync() ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>() : {};
    } catch (e) {
      errorLog.info('GIFs', 'Cache das cenas da letra estava ilegível e foi recomeçado', e);
      _data = {};
    }
    return _data!;
  }

  /// null = nunca procurou (ou venceu); lista (talvez vazia) = já procurou.
  List<LyricScene>? get(String artist, String title) {
    final e = _map[keyFor(artist, title)];
    if (e is! Map) return null;
    final at = DateTime.tryParse('${e['t']}');
    if (at == null || DateTime.now().difference(at) > maxAge) return null;
    return [for (final k in (e['s'] as List? ?? const [])) ?LyricScenes.byKey('$k')];
  }

  void put(String artist, String title, List<LyricScene> scenes) {
    _map[keyFor(artist, title)] = {'t': DateTime.now().toIso8601String(), 's': [for (final s in scenes) s.key]};
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_map));
    } catch (e) {
      errorLog.warn('GIFs', 'Não deu para salvar o cache das cenas da letra', error: e);
    }
  }
}
