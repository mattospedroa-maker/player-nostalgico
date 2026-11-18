import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'error_log.dart';

/// Uma tag do Last.fm e quanto ela pesa (0 a 100, o Last.fm normaliza pela tag mais usada).
class MusicTag {
  final String name;
  final int count;
  const MusicTag(this.name, this.count);

  Map<String, Object> toJson() => {'n': name, 'c': count};
  static MusicTag fromJson(Map<String, dynamic> m) => MusicTag('${m['n']}', (m['c'] as num?)?.toInt() ?? 0);

  @override
  String toString() => '$name($count)';
}

/// O que aconteceu na consulta. Só [ok] traz tags; os outros explicam por que não.
enum TagStatus {
  ok('Tags do Last.fm'),
  noKey('Chave do Last.fm não configurada'),
  invalidKey('Chave do Last.fm inválida'),
  notFound('Música não encontrada no Last.fm'),
  noTags('Música sem tags no Last.fm'),
  network('Sem conexão com o Last.fm'),
  badResponse('Resposta estranha do Last.fm');

  final String message;
  const TagStatus(this.message);

  /// Vale guardar no cache? Erros de rede e de chave podem mudar logo, então não.
  bool get cacheable => this == ok || this == notFound || this == noTags;
}

class TagResult {
  final TagStatus status;
  final List<MusicTag> tags;
  const TagResult(this.status, [this.tags = const []]);
}

/// Consulta `track.getTopTags` da API oficial do Last.fm.
class LastFmClient {
  final http.Client client;
  final String? apiKey;

  /// O Last.fm pede no máximo ~5 consultas por segundo; aqui fica bem abaixo disso.
  static const minInterval = Duration(milliseconds: 400);
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  LastFmClient(this.client, this.apiKey);

  static Uri urlFor(String artist, String track, String key) => Uri.https('ws.audioscrobbler.com', '/2.0/', {
        'method': 'track.gettoptags',
        'artist': artist,
        'track': track,
        'autocorrect': '1', // corrige nomes escritos diferente ("rammstein" -> "Rammstein")
        'api_key': key,
        'format': 'json',
      });

  Future<TagResult> topTags(String artist, String track) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) return const TagResult(TagStatus.noKey);
    if (artist.trim().isEmpty || track.trim().isEmpty) return const TagResult(TagStatus.notFound);
    return _fetch(urlFor(artist, track, key));
  }

  static Uri artistUrlFor(String artist, String key) => Uri.https('ws.audioscrobbler.com', '/2.0/', {
        'method': 'artist.gettoptags',
        'artist': artist,
        'autocorrect': '1',
        'api_key': key,
        'format': 'json',
      });

  /// Tags do artista (`artist.getTopTags`, mesmo formato de resposta). Usado para descobrir o gênero.
  Future<TagResult> artistTopTags(String artist) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) return const TagResult(TagStatus.noKey);
    if (artist.trim().isEmpty) return const TagResult(TagStatus.notFound);
    return _fetch(artistUrlFor(artist, key));
  }

  static Uri infoUrlFor(String artist, String track, String key) => Uri.https('ws.audioscrobbler.com', '/2.0/', {
        'method': 'track.getinfo',
        'artist': artist,
        'track': track,
        'autocorrect': '1',
        'api_key': key,
        'format': 'json',
      });

  /// Andamento e energia de `track.getInfo`, só se a resposta trouxer (quase nunca traz; aí volta vazio).
  /// null = não deu para consultar (sem chave, sem internet): tenta outra hora.
  Future<TrackTempo?> trackTempo(String artist, String track) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty || artist.trim().isEmpty || track.trim().isEmpty) return null;
    final wait = minInterval - DateTime.now().difference(_last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _last = DateTime.now();
    try {
      final res = await client
          .get(infoUrlFor(artist, track, key), headers: {'User-Agent': 'PlayerNostalgico/1.0 (app pessoal offline)'})
          .timeout(const Duration(seconds: 15));
      return parseTempo(res.statusCode, res.body);
    } catch (e) {
      errorLog.info('GIFs', 'Last.fm não respondeu (andamento)', e);
      return null;
    }
  }

  /// Lê `bpm` e `energy` da resposta de `track.getInfo` (separado para testar sem internet).
  /// Música não encontrada = vazio (vale guardar); erro de serviço = null.
  static TrackTempo? parseTempo(int statusCode, String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (json is! Map) return null;
    final err = (json['error'] as num?)?.toInt();
    if (err == 6) return const TrackTempo();
    if (err != null || statusCode != 200) return null;
    final t = json['track'];
    if (t is! Map) return const TrackTempo();
    double? num_(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.trim());
    final b = num_(t['bpm']);
    var e = num_(t['energy']);
    if (e != null && e > 1 && e <= 100) e = e / 100; // alguns serviços mandam 0–100
    return TrackTempo(
      bpm: b == null || b < 40 || b > 220 ? null : b.round(),
      energy: e == null || e < 0 || e > 1 ? null : e,
    );
  }

  Future<TagResult> _fetch(Uri uri) async {
    final wait = minInterval - DateTime.now().difference(_last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _last = DateTime.now();
    try {
      final res = await client
          .get(uri, headers: {'User-Agent': 'PlayerNostalgico/1.0 (app pessoal offline)'})
          .timeout(const Duration(seconds: 15));
      return parse(res.statusCode, res.body);
    } on TimeoutException {
      return const TagResult(TagStatus.network);
    } on SocketException {
      return const TagResult(TagStatus.network);
    } on http.ClientException {
      return const TagResult(TagStatus.network);
    }
  }

  /// Lê a resposta (separado para dar para testar sem internet).
  /// Erros do Last.fm: 6 = não encontrada, 10/26 = chave inválida/suspensa, 29 = limite de consultas.
  static TagResult parse(int statusCode, String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return TagResult(statusCode >= 500 ? TagStatus.network : TagStatus.badResponse);
    }
    if (json is! Map) return const TagResult(TagStatus.badResponse);
    final err = (json['error'] as num?)?.toInt();
    if (err != null) {
      return TagResult(switch (err) {
        6 => TagStatus.notFound,
        10 || 26 => TagStatus.invalidKey,
        11 || 16 || 29 => TagStatus.network, // serviço fora do ar ou limite: tenta outra hora
        _ => TagStatus.badResponse,
      });
    }
    if (statusCode != 200) return const TagResult(TagStatus.badResponse);
    final top = json['toptags'];
    if (top is! Map) return const TagResult(TagStatus.badResponse);
    final raw = top['tag'];
    // o Last.fm devolve um objeto sozinho quando só há uma tag
    final list = raw is List ? raw : (raw is Map ? [raw] : const []);
    final tags = <MusicTag>[];
    for (final t in list) {
      if (t is! Map) continue;
      final name = '${t['name'] ?? ''}'.trim();
      final count = t['count'] is num ? (t['count'] as num).toInt() : int.tryParse('${t['count']}') ?? 0;
      if (name.isNotEmpty && count > 0) tags.add(MusicTag(name, count));
    }
    tags.sort((a, b) => b.count.compareTo(a.count));
    return tags.isEmpty ? const TagResult(TagStatus.noTags) : TagResult(TagStatus.ok, tags.take(15).toList());
  }
}

/// Guarda as tags de cada música num arquivo, para não consultar de novo a mesma música.
class TagCache {
  final File file;
  final Duration maxAge;
  Map<String, dynamic>? _data;

  TagCache(this.file, {this.maxAge = const Duration(days: 60)});

  static String keyFor(String artist, String track) => '${artist.trim().toLowerCase()}|${track.trim().toLowerCase()}';

  Map<String, dynamic> get _map {
    if (_data != null) return _data!;
    try {
      _data = file.existsSync() ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>() : {};
    } catch (e) {
      errorLog.info('GIFs', 'Cache do Last.fm estava ilegível e foi recomeçado', e);
      _data = {};
    }
    return _data!;
  }

  /// [ignoreAge]: devolve mesmo vencida (o clima automático prefere tags velhas a nenhuma).
  TagResult? get(String artist, String track, {bool ignoreAge = false}) {
    final e = _map[keyFor(artist, track)];
    if (e is! Map) return null;
    final at = DateTime.tryParse('${e['t']}');
    if (!ignoreAge && (at == null || DateTime.now().difference(at) > maxAge)) return null;
    final status = TagStatus.values.asNameMap()['${e['s']}'];
    if (status == null) return null;
    final tags = [for (final m in (e['tags'] as List? ?? const [])) if (m is Map) MusicTag.fromJson(m.cast<String, dynamic>())];
    return TagResult(status, tags);
  }

  void put(String artist, String track, TagResult r) {
    if (!r.status.cacheable) return;
    _map[keyFor(artist, track)] = {
      's': r.status.name,
      't': DateTime.now().toIso8601String(),
      'tags': [for (final t in r.tags) t.toJson()],
    };
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_map));
    } catch (e) {
      errorLog.warn('GIFs', 'Não deu para salvar o cache do Last.fm', error: e);
    }
  }
}

/// Andamento de uma música (BPM e energia 0–1), quando se sabe.
class TrackTempo {
  final int? bpm;
  final double? energy;
  const TrackTempo({this.bpm, this.energy});
  bool get isEmpty => bpm == null && energy == null;
}

/// Andamento do Last.fm por música (`GIFs/.ritmo.json`), para não consultar de novo. Guarda também "não tem".
class TempoCache {
  final File file;
  final Duration maxAge;
  Map<String, dynamic>? _data;
  TempoCache(this.file, {this.maxAge = const Duration(days: 60)});

  Map<String, dynamic> get _map {
    if (_data != null) return _data!;
    try {
      _data = file.existsSync() ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>() : {};
    } catch (e) {
      errorLog.info('GIFs', 'Cache do andamento estava ilegível e foi recomeçado', e);
      _data = {};
    }
    return _data!;
  }

  TrackTempo? get(String artist, String track) {
    final e = _map[TagCache.keyFor(artist, track)];
    if (e is! Map) return null;
    final at = DateTime.tryParse('${e['t']}');
    if (at == null || DateTime.now().difference(at) > maxAge) return null;
    return TrackTempo(bpm: (e['b'] as num?)?.toInt(), energy: (e['e'] as num?)?.toDouble());
  }

  void put(String artist, String track, TrackTempo t) {
    _map[TagCache.keyFor(artist, track)] = {'t': DateTime.now().toIso8601String(), 'b': ?t.bpm, 'e': ?t.energy};
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_map));
    } catch (e) {
      errorLog.warn('GIFs', 'Não deu para salvar o cache do andamento', error: e);
    }
  }
}
