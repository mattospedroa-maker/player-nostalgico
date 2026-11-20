import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'db.dart';
import 'error_log.dart';
import 'filename_parser.dart';
import 'metadata.dart';
import 'models.dart';
import 'podcasts.dart';

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

    // as tags são lidas em grupos de 25 arquivos; no app de verdade, fora da linha da tela (isolate)
    const group = 25;
    for (var g = 0; g < files.length; g += group) {
      final chunk = files.sublist(g, min(g + group, files.length));
      final toRead = <(File, int)>[];
      for (var k = 0; k < chunk.length; k++) {
        final f = chunk[k];
        onProgress?.call(g + k, files.length);
        final int mtime;
        try {
          mtime = f.statSync().modified.millisecondsSinceEpoch;
        } catch (e) {
          errorLog.info('Biblioteca', 'Um arquivo sumiu no meio da leitura', e);
          continue; // o arquivo sumiu no meio da leitura: segue com os outros
        }
        final old = known[f.path];
        // podcast lido antes como música (ex.: a pasta Podcasts já existia): relê para pegar o programa da pasta
        final staleEpisode = old != null && isPodcastPath(root, f.path) && old.artist != (programFromPath(root, f.path) ?? old.artist);
        if (!force && old != null && old.modifiedAt == mtime && !staleEpisode) continue;
        toRead.add((f, mtime));
      }
      if (toRead.isEmpty) continue;
      final paths = [for (final (f, _) in toRead) f.path];
      final allTags = metadata is FileMetadataReader
          ? await FileMetadataReader.readMany(paths)
          : [for (final path in paths) await metadata.read(path)];
      for (var k = 0; k < toRead.length; k++) {
        final (f, mtime) = toRead[k];
        final tags = allTags[k];
        final parsed = parseFileName(p.basenameWithoutExtension(f.path));
        final folderAlbum = p.basename(p.dirname(f.path));
        final tagTitle = (tags?.title.isNotEmpty ?? false) ? parseFileName(tags!.title) : null;
        final artist = cleanArtistName(tags?.artist ?? '') ?? tagTitle?.artist ?? parsed.artist ?? unknownArtist;
        if (isPodcastPath(root, f.path)) {
          // podcast: o "artista" é o programa (a pasta Podcasts/<Programa>/), e o título fica inteiro
          // (o título de episódio costuma ter convidados e número, que a limpeza de músicas cortaria)
          final program = programFromPath(root, f.path) ??
              ((tags?.artist.trim().isNotEmpty ?? false) ? tags!.artist.trim() : unknownProgram);
          final title = (tags?.title.trim().isNotEmpty ?? false) ? tags!.title.trim() : p.basenameWithoutExtension(f.path);
          pending.add(Track(
            path: f.path,
            title: title,
            artist: program,
            album: program,
            year: tags?.year,
            durationMs: tags?.duration?.inMilliseconds ?? 0,
            addedAt: now,
            modifiedAt: mtime,
          ));
          changed++;
          continue;
        }
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
          bpm: tags?.bpm,
          addedAt: now,
          modifiedAt: mtime,
        ));
        changed++;
      }
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
      } catch (e) {
        errorLog.info('Biblioteca', 'Não deu para apagar uma pasta vazia', e);
        break;
      }
      d = d.parent;
    }
  }
}
