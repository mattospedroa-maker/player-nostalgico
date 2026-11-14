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

  Future<int> scan(String root, {void Function(int done, int total)? onProgress}) async {
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
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      onProgress?.call(i, files.length);
      final mtime = f.statSync().modified.millisecondsSinceEpoch;
      final old = known[f.path];
      if (old != null && old.modifiedAt == mtime) continue;
      final tags = await metadata.read(f.path);
      final parsed = parseFileName(p.basenameWithoutExtension(f.path));
      final folderAlbum = p.basename(p.dirname(f.path));
      await db.upsertTrack(Track(
        path: f.path,
        title: (tags?.title.isNotEmpty ?? false) ? tags!.title : parsed.title,
        artist: (tags?.artist.isNotEmpty ?? false) ? tags!.artist : (parsed.artist ?? unknownArtist),
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
    }
    await db.deleteTracksNotIn(files.map((f) => f.path).toSet());
    onProgress?.call(files.length, files.length);
    return changed;
  }
}
