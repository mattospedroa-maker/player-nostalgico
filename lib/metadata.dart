import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;

import 'error_log.dart';
import 'genre.dart';

class TagInfo {
  final String title;
  final String artist;
  final String album;
  final String genre;
  final int? year;
  final Duration? duration;

  /// Andamento da tag TBPM (só se for um número plausível, 40 a 220).
  final int? bpm;
  const TagInfo({this.title = '', this.artist = '', this.album = '', this.genre = '', this.year, this.duration, this.bpm});
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
        genre: realGenre(m.genres), // "Music" (categoria do YouTube) e afins contam como vazio
        year: m.year?.year,
        duration: m.duration,
        bpm: path.toLowerCase().endsWith('.mp3') ? _bpmOf(path) : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// TBPM do ID3 (a leitura simples não traz). Só arquivos MP3; erro = sem andamento.
  static int? _bpmOf(String path) {
    try {
      final all = amr.readAllMetadata(File(path), getImage: false);
      return all is amr.Mp3Metadata ? parseBpm(all.bpm) : null;
    } catch (_) {
      return null;
    }
  }

  /// "128", "92.5" -> número; fora de 40–220 conta como ausente.
  static int? parseBpm(Object? raw) {
    final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}'.replaceAll('\u0000', '').trim().replaceAll(',', '.'));
    if (v == null || v < 40 || v > 220) return null;
    return v.round();
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
