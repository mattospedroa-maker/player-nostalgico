import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'filename_parser.dart';
import 'metadata.dart';
import 'models.dart';

/// Resultado da busca de artista/álbum para uma música.
class SongInfo {
  final String title;
  final String artist;
  final String album;
  final int score; // 0-100, confiança
  final String source; // "tags", "musicbrainz", "nome do arquivo"
  const SongInfo({required this.title, required this.artist, required this.album, required this.score, required this.source});
}

enum PlanStatus { move, alreadyOrganized, notFound, error }

/// Uma linha do plano mostrado ao usuário antes de mover.
class PlanItem {
  final String sourcePath;
  final String? targetPath;
  final SongInfo? info;
  final PlanStatus status;
  final String? message;
  bool selected;
  PlanItem({required this.sourcePath, this.targetPath, this.info, required this.status, this.message})
      : selected = status == PlanStatus.move;
}

/// Consulta o MusicBrainz (gratuito, sem chave, limite de 1 pedido por segundo).
class MusicBrainzClient {
  final http.Client client;
  final Duration minInterval;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  MusicBrainzClient({http.Client? client, this.minInterval = const Duration(milliseconds: 1100)})
      : client = client ?? http.Client();

  static const userAgent = 'PlayerNostalgico/0.1 (app pessoal offline)';

  Future<SongInfo?> lookup(String title, {String? artist}) async {
    final wait = _last.add(minInterval).difference(DateTime.now());
    if (wait > Duration.zero) await Future.delayed(wait);
    _last = DateTime.now();

    final q = StringBuffer('recording:"${_escape(title)}"');
    if (artist != null && artist.isNotEmpty) q.write(' AND artist:"${_escape(artist)}"');
    final uri = Uri.https('musicbrainz.org', '/ws/2/recording', {'query': q.toString(), 'fmt': 'json', 'limit': '10'});
    var res = await _get(uri);
    // 503 = limite de pedidos do MusicBrainz: espera e tenta de novo (até 3 vezes).
    for (var attempt = 1; res.statusCode == 503 && attempt <= 3; attempt++) {
      await Future.delayed(Duration(seconds: 2 * attempt));
      res = await _get(uri);
    }
    if (res.statusCode == 503) throw const HttpException('MusicBrainz ocupado (limite de pedidos). Tente de novo mais tarde.');
    if (res.statusCode != 200) throw HttpException('MusicBrainz respondeu ${res.statusCode}');
    return parseRecordingSearch(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>, title: title, artistHint: artist);
  }

  Future<http.Response> _get(Uri uri) {
    _last = DateTime.now();
    return client.get(uri, headers: {'User-Agent': userAgent, 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
  }

  static String _escape(String s) => s.replaceAll(RegExp(r'[\\"]'), ' ').trim();

  /// Escolhe a melhor gravação e o melhor lançamento (prefere álbum oficial de estúdio).
  static SongInfo? parseRecordingSearch(Map<String, dynamic> json, {required String title, String? artistHint}) {
    final recs = (json['recordings'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    SongInfo? best;
    var bestRank = -1.0;
    for (final r in recs) {
      final score = (r['score'] as num?)?.toInt() ?? 0;
      if (score < 70) continue;
      final credits = (r['artist-credit'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final artist = credits.map((c) => '${c['name'] ?? c['artist']?['name'] ?? ''}${c['joinphrase'] ?? ''}').join().trim();
      if (artist.isEmpty) continue;
      final releases = (r['releases'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      final rel = _pickRelease(releases);
      if (rel == null) continue;
      var rank = score.toDouble() + rel.$2;
      if (artistHint != null && _norm(artist).contains(_norm(artistHint))) rank += 15;
      if (_norm(r['title'] as String? ?? '') == _norm(title)) rank += 10;
      if (rank > bestRank) {
        bestRank = rank;
        best = SongInfo(
          title: (r['title'] as String?) ?? title,
          artist: artist,
          album: rel.$1,
          score: score,
          source: 'musicbrainz',
        );
      }
    }
    return best;
  }

  static (String, double)? _pickRelease(List<Map<String, dynamic>> releases) {
    (String, double)? best;
    var bestYear = 9999;
    for (final rel in releases) {
      final rg = rel['release-group'] as Map<String, dynamic>? ?? const {};
      final primary = rg['primary-type'] as String?;
      final secondary = (rg['secondary-types'] as List?)?.cast<String>() ?? const [];
      final official = rel['status'] == 'Official';
      var bonus = 0.0;
      if (primary == 'Album') bonus += 20;
      if (primary == 'EP') bonus += 10;
      if (official) bonus += 5;
      if (secondary.contains('Compilation')) bonus -= 15;
      if (secondary.contains('Live')) bonus -= 10;
      final year = int.tryParse(((rel['date'] as String?) ?? '').split('-').first) ?? 9999;
      final title = rel['title'] as String?;
      if (title == null || title.isEmpty) continue;
      if (best == null || bonus > best.$2 || (bonus == best.$2 && year < bestYear)) {
        best = (title, bonus);
        bestYear = year;
      }
    }
    return best;
  }
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9À-ɏ぀-ヿ一-鿿]+'), '');

/// Remove caracteres proibidos em nomes de pasta (Android/Windows).
String safeFolderName(String s) {
  var out = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  out = out.replaceAll(RegExp(r'[. ]+$'), '');
  if (out.isEmpty) out = '_';
  if (out.length > 80) out = out.substring(0, 80).trim();
  return out;
}

/// Caminho final: Fonte/Artista/Álbum/arquivo.ext
String targetPathFor(String sourceRoot, String filePath, String artist, String album) =>
    p.join(sourceRoot, safeFolderName(artist), safeFolderName(album), p.basename(filePath));

/// Monta o plano e executa a organização da pasta-fonte.
class Organizer {
  final String sourceRoot;
  final MusicBrainzClient mb;
  final MetadataReader metadata;
  final bool useOnline;

  Organizer({required this.sourceRoot, required this.mb, required this.metadata, this.useOnline = true});

  /// Lista as músicas que ainda não estão em Artista/Álbum.
  List<File> filesToCheck() {
    final root = Directory(sourceRoot);
    if (!root.existsSync()) return const [];
    return root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => isAudioFile(f.path))
        .where((f) => !_isInsideGifFolder(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  bool _isInsideGifFolder(String path) =>
      p.split(p.relative(path, from: sourceRoot)).first.toLowerCase() == 'gifs';

  /// Já está em Fonte/Artista/Álbum/arquivo?
  bool isOrganized(String path, String artist, String album) =>
      p.equals(p.dirname(path), p.dirname(targetPathFor(sourceRoot, path, artist, album)));

  Future<SongInfo?> identify(String path) async {
    final tags = await metadata.read(path);
    final parsed = parseFileName(p.basenameWithoutExtension(path));
    final title = (tags?.title.isNotEmpty ?? false) ? tags!.title : parsed.title;
    final tagArtist = tags?.artist ?? '';
    final tagAlbum = tags?.album ?? '';

    // 1. As tags do arquivo já dizem tudo: não precisa de internet.
    if (tagArtist.isNotEmpty && tagAlbum.isNotEmpty) {
      return SongInfo(title: title, artist: tagArtist, album: tagAlbum, score: 100, source: 'tags');
    }
    final artistHint = tagArtist.isNotEmpty ? tagArtist : parsed.artist;

    // 2. Pesquisa o título (e o artista, se souber) no MusicBrainz.
    if (useOnline && title.isNotEmpty) {
      final found = await mb.lookup(title, artist: artistHint);
      if (found != null) return found;
      if (artistHint != null) {
        final retry = await mb.lookup(title);
        if (retry != null && _norm(retry.artist).contains(_norm(artistHint))) return retry;
      }
    }
    // 3. Sem resposta online, mas o nome do arquivo trazia o artista.
    if (artistHint != null && artistHint.isNotEmpty) {
      return SongInfo(title: title, artist: artistHint, album: tagAlbum.isNotEmpty ? tagAlbum : unknownAlbum, score: 40, source: 'nome do arquivo');
    }
    return null;
  }

  Future<List<PlanItem>> buildPlan({void Function(int done, int total, String current)? onProgress, bool Function()? cancelled}) async {
    final files = filesToCheck();
    final plan = <PlanItem>[];
    final targets = <String>{};
    for (var i = 0; i < files.length; i++) {
      if (cancelled?.call() ?? false) break;
      final f = files[i];
      onProgress?.call(i, files.length, p.basename(f.path));
      try {
        final info = await identify(f.path);
        if (info == null) {
          plan.add(PlanItem(sourcePath: f.path, status: PlanStatus.notFound, message: 'Não encontrei artista/álbum'));
          continue;
        }
        if (isOrganized(f.path, info.artist, info.album)) {
          plan.add(PlanItem(sourcePath: f.path, info: info, status: PlanStatus.alreadyOrganized));
          continue;
        }
        var target = targetPathFor(sourceRoot, f.path, info.artist, info.album);
        target = _uniqueTarget(target, targets);
        targets.add(target);
        plan.add(PlanItem(sourcePath: f.path, targetPath: target, info: info, status: PlanStatus.move));
      } catch (e) {
        plan.add(PlanItem(sourcePath: f.path, status: PlanStatus.error, message: '$e'));
      }
    }
    onProgress?.call(files.length, files.length, '');
    return plan;
  }

  String _uniqueTarget(String target, Set<String> reserved) {
    var candidate = target;
    var n = 2;
    while (reserved.contains(candidate) || File(candidate).existsSync()) {
      candidate = p.join(p.dirname(target), '${p.basenameWithoutExtension(target)} ($n)${p.extension(target)}');
      n++;
    }
    return candidate;
  }

  /// Move os arquivos selecionados e grava um registro para poder desfazer.
  Future<List<MoveRecord>> execute(List<PlanItem> plan, {required String undoLogPath}) async {
    final done = <MoveRecord>[];
    for (final item in plan.where((i) => i.selected && i.status == PlanStatus.move && i.targetPath != null)) {
      final src = File(item.sourcePath);
      if (!src.existsSync()) continue;
      await Directory(p.dirname(item.targetPath!)).create(recursive: true);
      await _move(src, item.targetPath!);
      done.add(MoveRecord(from: item.sourcePath, to: item.targetPath!, artist: item.info!.artist, album: item.info!.album));
    }
    await File(undoLogPath).writeAsString(jsonEncode(done.map((m) => m.toJson()).toList()));
    _removeEmptyDirs(Directory(sourceRoot));
    return done;
  }

  /// Desfaz a última organização (volta cada arquivo para onde estava).
  static Future<List<MoveRecord>> undo(String undoLogPath, String sourceRoot) async {
    final f = File(undoLogPath);
    if (!f.existsSync()) return const [];
    final list = (jsonDecode(await f.readAsString()) as List).map((e) => MoveRecord.fromJson(e as Map<String, dynamic>)).toList();
    final undone = <MoveRecord>[];
    for (final m in list.reversed) {
      final cur = File(m.to);
      if (!cur.existsSync() || File(m.from).existsSync()) continue;
      await Directory(p.dirname(m.from)).create(recursive: true);
      await _move(cur, m.from);
      undone.add(m);
    }
    await f.delete();
    _removeEmptyDirs(Directory(sourceRoot));
    return undone;
  }

  static Future<void> _move(File src, String target) async {
    try {
      await src.rename(target);
    } on FileSystemException {
      // rename falha entre partições (ex.: cartão SD): copia e apaga.
      await src.copy(target);
      await src.delete();
    }
  }

  static void _removeEmptyDirs(Directory root) {
    if (!root.existsSync()) return;
    for (final d in root.listSync(recursive: true).whereType<Directory>().toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length))) {
      try {
        if (d.listSync().isEmpty) d.deleteSync();
      } catch (_) {}
    }
  }
}

class MoveRecord {
  final String from;
  final String to;
  final String artist;
  final String album;
  const MoveRecord({required this.from, required this.to, required this.artist, required this.album});
  Map<String, String> toJson() => {'from': from, 'to': to, 'artist': artist, 'album': album};
  static MoveRecord fromJson(Map<String, dynamic> j) =>
      MoveRecord(from: j['from'] as String, to: j['to'] as String, artist: j['artist'] as String, album: j['album'] as String);
}
