import 'dart:io';

import 'package:path/path.dart' as p;

import 'db.dart';
import 'filename_parser.dart';
import 'metadata.dart';
import 'models.dart';

/// Varre a pasta-fonte e mantém o banco em dia (só relê o que mudou).
class LibraryScanner {
  final AppDb db;
  final MetadataReader metadata;
  LibraryScanner(this.db, this.metadata);

  /// [force] relê todas (ex.: quando a limpeza de nomes melhora).
  Future<int> scan(String root, {void Function(int done, int total)? onProgress, bool force = false}) async {
    final dir = Directory(root);
    if (!dir.existsSync()) return 0;
    final files = <File>[];
    await for (final e in dir.list(recursive: true, followLinks: false).handleError((_) {})) {
      if (e is File && isAudioFile(e.path)) {
        final rel = p.split(p.relative(e.path, from: root));
        if (rel.isNotEmpty && rel.first.toLowerCase() == 'gifs') continue;
        files.add(e);
      }
    }
    final known = await db.tracksByPath();
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = 0;
    // grava em lotes, cada lote numa transação: no celular cada gravação solta espera o disco confirmar,
    // e a primeira leitura de uma pasta grande ficava muito mais lenta. Lotes pequenos para não segurar
    // o banco (histórico, favoritas) por muito tempo.
    final pending = <Track>[];
    Future<void> flush() async {
      if (pending.isEmpty) return;
      final batch = List.of(pending);
      pending.clear();
      await db.db.transaction((tx) async {
        for (final t in batch) {
          await db.upsertTrack(t, tx: tx);
        }
      });
    }

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      onProgress?.call(i, files.length);
      final int mtime;
      try {
        mtime = f.statSync().modified.millisecondsSinceEpoch;
      } catch (_) {
        continue; // o arquivo sumiu no meio da leitura: segue com os outros
      }
      final old = known[f.path];
      if (!force && old != null && old.modifiedAt == mtime) continue;
      final tags = await metadata.read(f.path);
      final parsed = parseFileName(p.basenameWithoutExtension(f.path));
      final folderAlbum = p.basename(p.dirname(f.path));
      final tagTitle = (tags?.title.isNotEmpty ?? false) ? parseFileName(tags!.title) : null;
      final artist = cleanArtistName(tags?.artist ?? '') ?? tagTitle?.artist ?? parsed.artist ?? unknownArtist;
      pending.add(Track(
        path: f.path,
        title: tagTitle?.title ?? parsed.title,
        artist: artist,
        album: (tags?.album.isNotEmpty ?? false)
            ? tags!.album
            : (p.equals(p.dirname(f.path), root) ? unknownAlbum : folderAlbum),
        genre: tags?.genre ?? '',
        year: tags?.year,
        durationMs: tags?.duration?.inMilliseconds ?? 0,
        addedAt: now,
        modifiedAt: mtime,
      ));
      changed++;
      if (pending.length >= 50) await flush();
    }
    await flush();
    final present = files.map((f) => f.path).toSet();
    final removed = known.keys.where((k) => !present.contains(k)).toList();
    await db.deleteTracksNotIn(present);
    removeEmptyParents(root, removed);
    onProgress?.call(files.length, files.length);
    return changed;
  }
}

/// Depois que músicas somem, apaga as pastas de álbum/artista que ficaram vazias (nunca a pasta-fonte).
void removeEmptyParents(String root, Iterable<String> files) {
  for (final f in files) {
    var d = Directory(p.dirname(f));
    while (p.isWithin(root, d.path)) {
      try {
        if (!d.existsSync()) {
          d = d.parent;
          continue;
        }
        if (d.listSync().isNotEmpty) break;
        d.deleteSync();
      } catch (_) {
        break;
      }
      d = d.parent;
    }
  }
}
