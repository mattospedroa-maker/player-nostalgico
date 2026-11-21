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
        bpm: _bpmFor(path),
      );
    } catch (_) {
      return null;
    }
  }

  /// Andamento gravado no arquivo: TBPM do MP3 ou átomo tmpo do M4A. Sem tag ou erro = sem andamento.
  static int? _bpmFor(String path) {
    final l = path.toLowerCase();
    if (l.endsWith('.mp3')) return _bpmOf(path);
    if (l.endsWith('.m4a')) return mp4BpmOf(path);
    return null;
  }

  /// tmpo do MP4/M4A (o audio_metadata_reader não traz). Caminho: moov > udta > meta > ilst > tmpo > data.
  /// Lê só o moov (pula o áudio), então é barato mesmo em arquivo grande.
  static int? mp4BpmOf(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      final len = f.lengthSync();
      var pos = 0;
      while (pos + 8 <= len) {
        f.setPositionSync(pos);
        final h = f.readSync(16);
        if (h.length < 8) return null;
        final bd = ByteData.sublistView(h);
        var size = bd.getUint32(0);
        var header = 8;
        if (size == 1) {
          if (h.length < 16) return null;
          size = bd.getUint64(8);
          header = 16;
        } else if (size == 0) {
          size = len - pos;
        }
        if (size < header) return null;
        if (String.fromCharCodes(h, 4, 8) == 'moov') {
          if (size > 32 * 1024 * 1024) return null; // moov gigante não é de áudio normal
          f.setPositionSync(pos + header);
          final moov = f.readSync(size - header);
          return parseBpm(_tmpoIn(moov, 0, moov.length, 0));
        }
        pos += size;
      }
    } catch (_) {
      // arquivo estranho: sem andamento
    } finally {
      f?.closeSync();
    }
    return null;
  }

  static const _tmpoPath = ['udta', 'meta', 'ilst', 'tmpo'];

  static int? _tmpoIn(Uint8List b, int start, int end, int depth) {
    final bd = ByteData.sublistView(b);
    var p = start;
    while (p + 8 <= end) {
      final size = bd.getUint32(p);
      if (size < 8 || p + size > end) return null;
      final type = String.fromCharCodes(b, p + 4, p + 8);
      if (type == _tmpoPath[depth]) {
        var body = p + 8;
        final boxEnd = p + size;
        if (type == 'tmpo') {
          // data: tamanho(4) 'data'(4) tipo(4) idioma(4) valor (inteiro de 1 ou 2 bytes)
          if (body + 17 > boxEnd || String.fromCharCodes(b, body + 4, body + 8) != 'data') return null;
          final v = body + 16;
          return boxEnd - v >= 2 ? bd.getUint16(v) : b[v];
        }
        // meta costuma ter 4 bytes de versão antes dos filhos (alguns arquivos não têm)
        if (type == 'meta' && body + 8 <= boxEnd && String.fromCharCodes(b, body + 4, body + 8) != 'hdlr') body += 4;
        return _tmpoIn(b, body, boxEnd, depth + 1);
      }
      p += size;
    }
    return null;
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
