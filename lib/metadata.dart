import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;

import 'error_log.dart';

class TagInfo {
  final String title;
  final String artist;
  final String album;
  final String genre;
  final int? year;
  final Duration? duration;
  const TagInfo({this.title = '', this.artist = '', this.album = '', this.genre = '', this.year, this.duration});
}

/// Lê as tags do arquivo (ID3, Vorbis, MP4...). Interface para poder trocar nos testes.
abstract class MetadataReader {
  Future<TagInfo?> read(String path);
  Future<Uint8List?> cover(String path);
}

class FileMetadataReader implements MetadataReader {
  const FileMetadataReader();

  @override
  Future<TagInfo?> read(String path) async => readTagsSync(path);

  /// Lê as tags de vários arquivos num isolate separado (a leitura é síncrona e travaria a tela
  /// durante a leitura de uma pasta grande).
  static Future<List<TagInfo?>> readMany(List<String> paths) async {
    if (paths.isEmpty) return const [];
    try {
      return await Isolate.run(() => [for (final p in paths) readTagsSync(p)]);
    } catch (e) {
      errorLog.info('Biblioteca', 'Leitura das tags em segundo plano falhou; lendo do jeito lento', e);
      return [for (final p in paths) readTagsSync(p)]; // sem isolate: lê aqui mesmo, como antes
    }
  }

  static TagInfo? readTagsSync(String path) {
    try {
      final m = amr.readMetadata(File(path), getImage: false);
      String clean(String? s) => (s ?? '').replaceAll('\u0000', '').trim();
      final artist = clean(m.artist).isNotEmpty ? clean(m.artist) : clean(m.albumArtist);
      return TagInfo(
        title: clean(m.title),
        artist: artist,
        album: clean(m.album),
        genre: m.genres.isEmpty ? '' : clean(m.genres.first),
        year: m.year?.year,
        duration: m.duration,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> cover(String path) async {
    try {
      final m = amr.readMetadata(File(path), getImage: true);
      if (m.pictures.isNotEmpty) return m.pictures.first.bytes;
    } catch (e) {
      errorLog.info('Capas', 'Não deu para ler a capa de ${path.split(Platform.pathSeparator).last}', e);
    }
    // capa da pasta (cover.jpg / folder.jpg)
    final dir = File(path).parent;
    for (final n in const ['cover.jpg', 'folder.jpg', 'cover.png', 'folder.png', 'Cover.jpg', 'Folder.jpg']) {
      final f = File('${dir.path}${Platform.pathSeparator}$n');
      if (f.existsSync()) return f.readAsBytes();
    }
    return null;
  }
}
