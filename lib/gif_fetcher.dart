import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'filename_parser.dart';
import 'gif_providers.dart';
import 'gif_service.dart';
import 'models.dart';
import 'organizer.dart' show safeFolderName;

/// Máximo de GIFs por música (para não ocupar espaço demais).
const maxGifsPerTrack = 9;

/// Baixa GIFs da internet (Openverse + Wikimedia) pelo nome da música e do artista,
/// guarda em `GIFs/Artista/Título/` e fixa na música. Depois funciona offline.
class GifFetcher {
  final GifService gifs;
  final List<GifProvider> providers;
  final http.Client client;
  final int maxBytes;

  /// Não tenta de novo a mesma música antes disso (se a busca anterior não achou nada).
  final Duration retryAfter;

  final Set<int> _running = {};

  GifFetcher(this.gifs, {required this.client, List<GifProvider>? providers, this.maxBytes = 8 * 1024 * 1024, this.retryAfter = const Duration(days: 3)})
      : providers = providers ?? [OpenverseProvider(client), WikimediaProvider(client)];

  bool isFetching(Track t) => _running.contains(t.id);

  /// Buscas, da mais específica para a mais larga:
  /// palavras extras ("rock lee vs gaara"), "título artista", "artista", "título" e por fim o gênero.
  static List<String> queriesFor(Track t, {List<String> extras = const []}) {
    final parsed = parseFileName(t.title);
    final title = parsed.title.trim();
    var artist = t.artist.trim();
    if (artist.isEmpty || artist == unknownArtist) artist = parsed.artist ?? '';
    final genre = t.genre.trim();
    final qs = <String>[
      ...extras,
      if (artist.isNotEmpty) '$title $artist',
      if (artist.isNotEmpty) artist,
      title,
      if (genre.isNotEmpty && genre.toLowerCase() != 'desconhecido') genre,
    ];
    final seen = <String>{};
    return qs.map((q) => q.trim()).where((q) => q.length >= 2 && seen.add(q.toLowerCase())).toList();
  }

  /// Pastas onde os GIFs da música ficam: `GIFs/Artista/Título/`.
  static (String, String) dirsFor(Track t) {
    final parsed = parseFileName(t.title);
    final artist = t.artist == unknownArtist || t.artist.trim().isEmpty ? (parsed.artist ?? 'Outros') : t.artist;
    return (safeFolderName(artist), safeFolderName(parsed.title));
  }

  /// Texto pronto para a busca na web (inclui as palavras extras).
  String webQueryFor(Track t) {
    final parsed = parseFileName(t.title);
    final artist = t.artist == unknownArtist ? (parsed.artist ?? '') : t.artist;
    return [parsed.title, artist, ...gifs.extrasFor(t.artist, parsed.title), 'gif'].where((s) => s.trim().isNotEmpty).join(' ');
  }

  String? _logPath() => gifs.gifRoot == null ? null : p.join(gifs.gifRoot!, '.buscas.json');

  Map<String, dynamic> _readLog() {
    final path = _logPath();
    if (path == null || !File(path).existsSync()) return {};
    try {
      return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _writeLog(Map<String, dynamic> log) {
    final path = _logPath();
    if (path == null) return;
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(log));
  }

  /// Baixa GIFs até a música ter [maxGifsPerTrack] fixados. Retorna quantos baixou.
  /// Sem [force], não repete uma busca recente que não achou nada.
  Future<int> fetchFor(Track t, {bool force = false}) async {
    final root = gifs.gifRoot;
    if (root == null || t.id == null || _running.contains(t.id)) return 0;
    final pinned = (await gifs.db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    final need = maxGifsPerTrack - pinned.length;
    if (need <= 0) return 0;
    final key = t.path;
    final log = _readLog();
    final last = DateTime.tryParse('${log[key] ?? ''}');
    if (!force && last != null && DateTime.now().difference(last) < retryAfter) return 0;

    _running.add(t.id!);
    gifs.changed();
    var saved = 0;
    try {
      final candidates = <GifCandidate>[];
      final seen = <String>{};
      for (final q in queriesFor(t, extras: gifs.extrasFor(t.artist, parseFileName(t.title).title))) {
        for (final prov in providers) {
          try {
            for (final c in await prov.search(q, limit: 20)) {
              if (seen.add(c.url)) candidates.add(c);
            }
          } catch (_) {
            // sem internet ou fonte fora do ar: tenta a próxima
          }
        }
        if (candidates.length >= need * 2) break;
      }

      final (artistDir, titleDir) = dirsFor(t);
      final dest = Directory(p.join(root, artistDir, titleDir));
      final credits = <String>[];
      for (final c in candidates) {
        if (saved >= need) break;
        final name = '${sha1.convert(utf8.encode(c.url)).toString().substring(0, 12)}.gif';
        final target = p.join(dest.path, name);
        if (pinned.contains(target)) continue;
        if (!File(target).existsSync()) {
          final bytes = await _download(c.url);
          if (bytes == null) continue;
          await dest.create(recursive: true);
          await File(target).writeAsBytes(bytes, flush: true);
          credits.add('$name · ${c.credit}');
        }
        await gifs.db.pinGif(t.id!, target);
        saved++;
      }
      if (credits.isNotEmpty) {
        await File(p.join(dest.path, 'creditos.txt')).writeAsString('${credits.join('\n')}\n', mode: FileMode.append);
      }
      log[key] = DateTime.now().toIso8601String();
      _writeLog(log);
    } finally {
      _running.remove(t.id);
      await gifs.refresh();
    }
    return saved;
  }

  Future<Uint8List?> _download(String url) async {
    try {
      final req = http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'PlayerNostalgico/0.2 (app pessoal offline)';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return null;
      if ((res.contentLength ?? 0) > maxBytes) return null;
      final b = BytesBuilder(copy: false);
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        b.add(chunk);
        if (b.length > maxBytes) return null;
      }
      final bytes = b.takeBytes();
      // confere que é mesmo um GIF ("GIF87a"/"GIF89a")
      if (bytes.length < 6 || ascii.decode(bytes.sublist(0, 3), allowInvalid: true) != 'GIF') return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
