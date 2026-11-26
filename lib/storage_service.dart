import 'dart:io';

import 'package:path/path.dart' as p;

import 'db.dart';
import 'error_log.dart';
import 'models.dart';

/// Quanto espaço cada coisa do app ocupa (em bytes).
class StorageReport {
  /// GIFs que alguma música usa ou que o usuário guardou (inclui os soltos nas subpastas).
  final int gifs;

  /// GIFs automáticos que nenhuma música usa mais (música apagada, GIFs refeitos...).
  final int orphans;
  final int photos;
  final int covers;

  /// Imagens da notificação (1º quadro de cada GIF): se refazem sozinhas quando precisam.
  final int cache;

  /// Pasta Podcasts inteira (episódios, resumos e miniaturas).
  final int podcasts;

  /// Pasta Audiolivros inteira (livros, texto da obra e ilustrações).
  final int audiobooks;
  const StorageReport({this.gifs = 0, this.orphans = 0, this.photos = 0, this.covers = 0, this.cache = 0, this.podcasts = 0, this.audiobooks = 0});

  /// GIFs e imagens das músicas (o que o app guarda além dos arquivos de música).
  int get total => gifs + orphans + photos + covers + cache;

  /// O que conta para o teto: GIFs (com os órfãos) e fotos dos artistas.
  int get capped => gifs + orphans + photos;

  /// O que o "Limpar agora" tira sem perder nada que esteja em uso.
  int get cleanable => orphans + cache;
}

/// Resultado de uma limpeza.
class CleanResult {
  final int freedBytes;
  final int deletedGifs;

  /// Músicas que perderam os GIFs automáticos por causa do teto (voltam quando tocarem).
  final int trimmedTracks;
  const CleanResult(this.freedBytes, this.deletedGifs, this.trimmedTracks);
}

/// Opções do teto (MB). 0 = sem limite.
const storageCapChoices = [500, 1024, 2048, 5120, 0];
const defaultStorageCapMb = 1024;

String formatBytes(int b) {
  if (b >= 1024 * 1024 * 1024) return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} GB';
  if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).round()} MB';
  if (b >= 1024) return '${(b / 1024).round()} KB';
  return '$b B';
}

String capLabel(int mb) => mb == 0 ? 'Sem limite' : (mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB');

/// Mede e limpa o espaço dos GIFs, fotos, capas e cache.
///
/// Regras da limpeza (nunca apaga nada que o usuário escolheu):
/// 1. GIFs automáticos (nome = hash, ex.: `3fa2b9c01d4e.gif`) que nenhuma música usa;
/// 2. o cache das imagens da notificação;
/// 3. passou do teto: os GIFs automáticos das músicas ouvidas há mais tempo (nunca ouvidas primeiro),
///    pulando as favoritas e a que está tocando. Eles voltam quando a música tocar de novo.
class StorageService {
  final AppDb db;
  final String? Function() gifRoot;
  final String dataDir;
  /// Pasta de músicas (onde ficam Podcasts/ e Audiolivros/).
  final String? Function() musicRoot;
  StorageService({required this.db, required this.gifRoot, required this.dataDir, String? Function()? musicRoot}) : musicRoot = musicRoot ?? (() => null);

  /// Tamanho de uma subpasta da pasta de músicas, sem diferenciar maiúsculas ("Podcasts", "podcasts").
  Future<int> _folderSize(String name) async {
    final root = musicRoot();
    if (root == null) return 0;
    var total = 0;
    try {
      await for (final e in Directory(root).list(followLinks: false).handleError((Object _) {})) {
        if (e is Directory && p.basename(e.path).toLowerCase() == name.toLowerCase()) total += await _dirSize(e.path);
      }
    } catch (_) {}
    return total;
  }

  static final autoName = RegExp(r'^[0-9a-f]{12}\.gif$');

  String get photosDir => p.join(dataDir, 'artistas');
  String get coversDir => p.join(dataDir, 'capas');
  String get cacheDir => p.join(dataDir, 'arte');

  bool _busy = false;
  bool get busy => _busy;

  static Future<int> _dirSize(String path) async {
    var total = 0;
    final d = Directory(path);
    if (!await d.exists()) return 0;
    await for (final e in d.list(recursive: true, followLinks: false).handleError((Object _) {})) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {
          // arquivo sumiu no meio da conta
        }
      }
    }
    return total;
  }

  /// GIFs automáticos da pasta, com o tamanho de cada.
  Future<Map<String, int>> _autoGifs(String root) async {
    final out = <String, int>{};
    final d = Directory(root);
    if (!await d.exists()) return out;
    await for (final e in d.list(recursive: true, followLinks: false).handleError((Object _) {})) {
      if (e is File && autoName.hasMatch(p.basename(e.path))) {
        try {
          out[e.path] = await e.length();
        } catch (_) {}
      }
    }
    return out;
  }

  Future<Set<String>> _usedGifs() async => {for (final l in (await db.allPinnedGifs()).values) ...l};

  Future<StorageReport> measure() async {
    final root = gifRoot();
    var gifs = 0, orphans = 0;
    if (root != null) {
      final all = await _dirSize(root);
      final used = await _usedGifs();
      for (final e in (await _autoGifs(root)).entries) {
        if (!used.contains(e.key)) orphans += e.value;
      }
      gifs = all - orphans;
    }
    return StorageReport(
      gifs: gifs,
      orphans: orphans,
      photos: await _dirSize(photosDir),
      covers: await _dirSize(coversDir),
      cache: await _dirSize(cacheDir),
      podcasts: await _folderSize('Podcasts'),
      audiobooks: await _folderSize('Audiolivros'),
    );
  }

  Future<bool> _delete(String path) async {
    try {
      await File(path).delete();
      return true;
    } catch (e) {
      errorLog.info('Espaço', 'Não deu para apagar ${p.basename(path)}', e);
      return false;
    }
  }

  /// Limpa os órfãos e o cache e, com [capBytes] > 0, apara os GIFs até caber no teto.
  Future<CleanResult> clean({
    required int capBytes,
    required List<Track> tracks,
    required Map<int, int> lastPlayed,
    Set<int> protect = const {},
  }) async {
    if (_busy) return const CleanResult(0, 0, 0);
    _busy = true;
    try {
      final root = gifRoot();
      var freed = 0, deleted = 0, trimmed = 0;
      final auto = root == null ? <String, int>{} : await _autoGifs(root);
      final used = await _usedGifs();
      // 1) órfãos
      for (final e in auto.entries) {
        if (used.contains(e.key)) continue;
        if (await _delete(e.key)) {
          freed += e.value;
          deleted++;
        }
      }
      // 2) cache da notificação
      final cacheBytes = await _dirSize(cacheDir);
      try {
        final d = Directory(cacheDir);
        if (await d.exists()) await d.delete(recursive: true);
        freed += cacheBytes;
      } catch (e) {
        errorLog.info('Espaço', 'Não deu para limpar o cache das imagens da notificação', e);
      }
      // 3) teto
      if (capBytes > 0 && root != null) {
        var size = (await _dirSize(root)) + (await _dirSize(photosDir));
        if (size > capBytes) {
          final pinned = await db.allPinnedGifs();
          final users = <String, int>{};
          for (final l in pinned.values) {
            for (final g in l) {
              users[g] = (users[g] ?? 0) + 1;
            }
          }
          final order = [
            for (final t in tracks)
              if (t.id != null && !t.favorite && !protect.contains(t.id) && pinned.containsKey(t.id)) t,
          ]..sort((a, b) => (lastPlayed[a.id] ?? 0).compareTo(lastPlayed[b.id] ?? 0));
          for (final t in order) {
            if (size <= capBytes) break;
            var touched = false;
            for (final g in pinned[t.id]!) {
              if (!autoName.hasMatch(p.basename(g)) || !p.isWithin(root, g)) continue; // escolhido pelo usuário
              await db.unpinGif(t.id!, g);
              touched = true;
              final left = (users[g] ?? 1) - 1;
              users[g] = left;
              if (left > 0) continue; // outra música ainda usa
              final bytes = auto[g] ?? 0;
              if (await _delete(g)) {
                freed += bytes;
                size -= bytes;
                deleted++;
              }
            }
            if (touched) trimmed++;
          }
        }
      }
      return CleanResult(freed, deleted, trimmed);
    } finally {
      _busy = false;
    }
  }
}
