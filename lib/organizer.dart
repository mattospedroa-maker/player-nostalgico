import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'error_log.dart';
import 'filename_parser.dart';
import 'genre.dart';
import 'metadata.dart';
import 'models.dart';
import 'podcasts.dart';
import 'youtube_names.dart';

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

  /// [hints]: pistas de artista para desempatar quando a busca é só pelo título.
  Future<SongInfo?> lookup(String title, {String? artist, List<String> hints = const []}) async {
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
    return parseRecordingSearch(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>, title: title, artistHint: artist, hints: hints);
  }

  /// Como [lookup], mas aguenta artista com nome de canal do YouTube ("MadrugadaOfficial", "FulanoVEVO",
  /// "Fulano - Topic"): tenta o nome como está, depois limpo, e por fim só o título — aceitando a resposta
  /// só título se o artista bater com algum jeito de escrever a pista (ou se o MusicBrainz tiver muita certeza).
  ///
  /// [moreHints] são outras pistas de artista (ex.: a pasta Artista/Álbum onde o arquivo está). Cada uma é
  /// tentada na busca; na busca só pelo título, ganha quem bate com alguma pista. Se nenhuma bate, a
  /// certeza mostrada cai para no máximo 60% (o MusicBrainz dá 100 só porque o título é igual, e aí vinha
  /// um cover lofi com "100% de certeza").
  Future<SongInfo?> lookupSmart(String title, {String? artist, List<String> moreHints = const [], int titleOnlyMinScore = 90}) async {
    final hints = <String>[];
    for (final h in [artist ?? '', ...moreHints]) {
      final t = h.trim();
      if (t.isEmpty || t == unknownArtist || hints.any((x) => _norm(x) == _norm(t))) continue;
      hints.add(t);
    }
    if (hints.isEmpty) return lookup(title);
    final variants = <String>[];
    for (final h in hints) {
      for (final v in artistNameVariants(h)) {
        if (!variants.any((x) => _norm(x) == _norm(v))) variants.add(v);
      }
    }
    for (final v in variants) {
      final found = await lookup(title, artist: v, hints: variants);
      // a busca do MusicBrainz é aproximada: mesmo pedindo o artista, pode voltar outro
      if (found != null && artistMatchesAny(found.artist, variants)) return found;
    }
    final retry = await lookup(title, hints: variants);
    if (retry == null) return null;
    if (artistMatchesAny(retry.artist, variants)) return retry;
    if (retry.score < titleOnlyMinScore) return null;
    return SongInfo(title: retry.title, artist: retry.artist, album: retry.album, score: retry.score.clamp(0, 60), source: retry.source);
  }

  /// Parece cover/versão alternativa (lofi, karaokê, tributo...) pelo artista ou álbum?
  static bool looksLikeCover(SongInfo i) => _coverWords.hasMatch('${i.artist} ${i.album}');

  /// O artista achado bate com algum jeito de escrever as pistas ("Tame Impala" x "tame impala - topic")?
  static bool artistMatchesAny(String found, List<String> hints) {
    final got = _norm(found);
    return got.isNotEmpty && hints.map(_norm).any((v) => v.isNotEmpty && (got.contains(v) || (got.length >= 3 && v.contains(got))));
  }

  /// Gênero/subgênero do artista pelas tags do MusicBrainz (ex.: "Industrial Metal"). Null se não achar.
  Future<String?> artistGenre(String artist) async {
    final wait = _last.add(minInterval).difference(DateTime.now());
    if (wait > Duration.zero) await Future.delayed(wait);
    final uri = Uri.https('musicbrainz.org', '/ws/2/artist', {'query': 'artist:"${_escape(artist)}"', 'fmt': 'json', 'limit': '3'});
    var res = await _get(uri);
    for (var attempt = 1; res.statusCode == 503 && attempt <= 3; attempt++) {
      await Future.delayed(Duration(seconds: 2 * attempt));
      res = await _get(uri);
    }
    if (res.statusCode != 200) return null;
    return parseArtistGenre(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>, artist);
  }

  /// Id do álbum (release group) no MusicBrainz, para buscar a capa no Cover Art Archive.
  Future<String?> releaseGroupId(String artist, String album) async {
    final wait = _last.add(minInterval).difference(DateTime.now());
    if (wait > Duration.zero) await Future.delayed(wait);
    final uri = Uri.https('musicbrainz.org', '/ws/2/release-group',
        {'query': 'releasegroup:"${_escape(album)}" AND artist:"${_escape(artist)}"', 'fmt': 'json', 'limit': '5'});
    var res = await _get(uri);
    for (var attempt = 1; res.statusCode == 503 && attempt <= 3; attempt++) {
      await Future.delayed(Duration(seconds: 2 * attempt));
      res = await _get(uri);
    }
    // erro do servidor não é "não achei": quem chamou tenta de novo depois
    if (res.statusCode != 200) throw HttpException('MusicBrainz respondeu ${res.statusCode}');
    return parseReleaseGroup(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  static String? parseReleaseGroup(Map<String, dynamic> json) {
    final groups = (json['release-groups'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    for (final g in groups) {
      if (((g['score'] as num?) ?? 0) >= 85 && g['id'] is String) return g['id'] as String;
    }
    return null;
  }

  static String? parseArtistGenre(Map<String, dynamic> json, String artist) {
    String norm(String x) => x.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final artists = (json['artists'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    for (final a in artists) {
      if (((a['score'] as num?) ?? 0) < 85 && norm('${a['name']}') != norm(artist)) continue;
      final tags = ((a['tags'] as List?)?.cast<Map<String, dynamic>>() ?? const [])
          .where((t) => genreWords.hasMatch('${t['name']}') && !isGenericGenre('${t['name']}'))
          .toList()
        ..sort((x, y) => ((y['count'] as num?) ?? 0).compareTo((x['count'] as num?) ?? 0));
      if (tags.isEmpty) continue;
      return titleCaseGenre('${tags.first['name']}');
    }
    return null;
  }

  Future<http.Response> _get(Uri uri) {
    _last = DateTime.now();
    return client.get(uri, headers: {'User-Agent': userAgent, 'Accept': 'application/json'}).timeout(const Duration(seconds: 20));
  }

  static String _escape(String s) => s.replaceAll(RegExp(r'[\\"]'), ' ').trim();

  /// Escolhe a melhor gravação e o melhor lançamento (prefere álbum oficial de estúdio).
  static SongInfo? parseRecordingSearch(Map<String, dynamic> json, {required String title, String? artistHint, List<String> hints = const []}) {
    final allHints = [if (artistHint != null && artistHint.isNotEmpty) artistHint, ...hints];
    // "lofi", "karaokê", "tribute"... só valem se você mesmo escreveu isso no título ou no artista
    final wantsCover = _coverWords.hasMatch([title, ...allHints].join(' '));
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
      if (allHints.isNotEmpty && artistMatchesAny(artist, allHints)) rank += 30;
      if (!wantsCover && _coverWords.hasMatch([artist, rel.$1, r['disambiguation'] ?? ''].join(' '))) rank -= 40;
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

  /// Versões que não são a original: lofi, karaokê, tributo, "no estilo de", caixinha de música...
  static final _coverWords = RegExp(
      r'\b(lo-?fi|chill|karaok[eê]|tribute|in the style of|made famous|originally performed|cover|covers|8-?bit|lullab(y|ies)|rockabye|music box|piano version|string quartet|instrumental version|workout|kids)\b',
      caseSensitive: false);

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

String _usableArtist(String a) {
  final t = a.trim();
  if (t.isEmpty) return '';
  return parseFileName('$t - x').artist ?? '';
}

/// Artista pela pasta: Fonte/Artista/Álbum/música.m4a -> "Artista". Null se o arquivo está solto
/// ou a pasta é genérica ("Desconhecido", "Download", "Music"...).
String? folderArtistHint(String path) {
  final album = p.dirname(path);
  final artist = p.basename(p.dirname(album));
  if (artist.isEmpty || artist == unknownArtist || artist == '.' || artist == p.separator) return null;
  if (RegExp(r'^(desconhecid[oa]|unknown|downloads?|music|m[uú]sicas?|youtube|audio|0|emulated|storage|sdcard)$', caseSensitive: false).hasMatch(artist)) return null;
  return cleanArtistName(artist);
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

/// Caminho final: Fonte/Artista/Álbum/arquivo.ext (ou Título.ext, se [title] vier preenchido).
String targetPathFor(String sourceRoot, String filePath, String artist, String album, {String? title}) => p.join(
      sourceRoot,
      safeFolderName(artist),
      safeFolderName(album),
      title == null || title.trim().isEmpty ? p.basename(filePath) : '${safeFolderName(title)}${p.extension(filePath).toLowerCase()}',
    );

/// Monta o plano e executa a organização da pasta-fonte.
class Organizer {
  final String sourceRoot;
  final MusicBrainzClient mb;
  final MetadataReader metadata;
  final bool useOnline;

  /// Renomeia o arquivo para "Título.ext", tirando "00 - 002 - " e outros restos.
  final bool cleanNames;

  Organizer({required this.sourceRoot, required this.mb, required this.metadata, this.useOnline = true, this.cleanNames = true});

  /// Lista as músicas que ainda não estão em Artista/Álbum.
  List<File> filesToCheck() {
    final root = Directory(sourceRoot);
    if (!root.existsSync()) return const [];
    return root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => isAudioFile(f.path))
        .where((f) => !_isInsideGifFolder(f.path))
        // podcasts têm a própria organização (Podcasts/Programa/): o organizador de músicas não mexe
        .where((f) => !isPodcastPath(sourceRoot, f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  bool _isInsideGifFolder(String path) =>
      p.split(p.relative(path, from: sourceRoot)).first.toLowerCase() == 'gifs';

  String _target(String path, SongInfo info) =>
      targetPathFor(sourceRoot, path, info.artist, info.album, title: cleanNames ? info.title : null);

  /// Já está em Fonte/Artista/Álbum/arquivo (com o nome certo)?
  bool isOrganized(String path, SongInfo info) => p.equals(path, _target(path, info));

  Future<SongInfo?> identify(String path) async {
    final tags = await metadata.read(path);
    final parsed = parseFileName(p.basenameWithoutExtension(path));
    final rawTagTitle = tags?.title ?? '';
    final parsedTag = rawTagTitle.isEmpty ? null : parseFileName(rawTagTitle);
    final title = parsedTag?.title ?? parsed.title;
    final tagArtist = _usableArtist(tags?.artist ?? '');
    final tagAlbum = tags?.album ?? '';
    final tagsAreClean = rawTagTitle.isNotEmpty && parsedTag!.title == rawTagTitle.trim();

    // 1. Tags completas e limpas: não precisa de internet.
    if (tagArtist.isNotEmpty && tagAlbum.isNotEmpty && tagsAreClean) {
      return SongInfo(title: title, artist: tagArtist, album: tagAlbum, score: 100, source: 'tags');
    }
    final artistHint = tagArtist.isNotEmpty ? tagArtist : (parsedTag?.artist ?? parsed.artist);

    // 2. Pesquisa o título limpo (e o artista, se souber) no MusicBrainz.
    if (useOnline && title.isNotEmpty) {
      // a pista de artista pode estar errada (nome do canal do YouTube, cantora virtual em vez do produtor...)
      final folder = folderArtistHint(path);
      final found = await mb.lookupSmart(title, artist: artistHint, moreHints: [?folder]);
      // até 60% = o MusicBrainz só achou outro artista: sozinho não mexe, fica com o que a música já diz
      final hadHint = (artistHint ?? '').isNotEmpty || folder != null;
      if (found != null && !(hadHint && found.score <= 60)) return found;
    }
    if (tagArtist.isNotEmpty && tagAlbum.isNotEmpty) {
      return SongInfo(title: title, artist: tagArtist, album: tagAlbum, score: 90, source: 'tags');
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
        if (isOrganized(f.path, info)) {
          plan.add(PlanItem(sourcePath: f.path, info: info, status: PlanStatus.alreadyOrganized));
          continue;
        }
        var target = _target(f.path, info);
        target = _uniqueTarget(target, targets);
        targets.add(target);
        plan.add(PlanItem(sourcePath: f.path, targetPath: target, info: info, status: PlanStatus.move));
      } catch (e) {
        plan.add(PlanItem(sourcePath: f.path, status: PlanStatus.error, message: '$e'));
        errorLog.warn('Organizador', 'Não deu para analisar ${p.basename(f.path)}', error: e);
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
      done.add(MoveRecord(from: item.sourcePath, to: item.targetPath!, artist: item.info!.artist, album: item.info!.album, title: item.info!.title));
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

  static Future<void> moveFile(File src, String target) => _move(src, target);

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
      } catch (e) {
        errorLog.info('Organizador', 'Não deu para apagar uma pasta vazia', e);
      }
    }
  }
}

class MoveRecord {
  final String from;
  final String to;
  final String artist;
  final String album;
  final String title;
  const MoveRecord({required this.from, required this.to, required this.artist, required this.album, this.title = ''});
  Map<String, String> toJson() => {'from': from, 'to': to, 'artist': artist, 'album': album, 'title': title};
  static MoveRecord fromJson(Map<String, dynamic> j) => MoveRecord(
      from: j['from'] as String,
      to: j['to'] as String,
      artist: j['artist'] as String,
      album: j['album'] as String,
      title: (j['title'] as String?) ?? '');
}
