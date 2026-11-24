import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'metadata.dart';

/// Tipo da imagem pelos primeiros bytes (só JPEG e PNG vão dentro do arquivo de música).
String? imageMime(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
  if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
  return null;
}

/// Grava a capa dentro do arquivo (.m4a: átomo covr; .mp3: APIC). Não troca uma capa que já existe.
/// Devolve true se gravou. O arquivo inteiro é relido e regravado (de forma atômica: .tmp e depois renomeia).
bool embedCoverSync(String path, Uint8List image) {
  final mime = imageMime(image);
  if (mime == null) return false;
  final file = File(path);
  FileMetadataReader.fixMp4Date(path); // a data "20180724" do yt-dlp quebraria a leitura
  final has = switch (readAllMetadata(file, getImage: true)) {
    Mp4Metadata(:final picture) => picture != null,
    Mp3Metadata(:final pictures) => pictures.isNotEmpty,
    _ => true, // outros formatos: não mexe
  };
  if (has) return false;
  updateMetadata(file, (m) {
    m.setPictures([Picture(image, mime, PictureType.coverFront)]);
    // data de envio do yt-dlp (20261121) lida como ano absurdo: não regrava lixo
    if (m is Mp4Metadata && m.year != null && (m.year!.year < 1000 || m.year!.year > 9999)) m.year = null;
  });
  return true;
}

/// [embedCoverSync] fora da tela (num isolate), para não travar a interface.
Future<bool> embedCoverInBackground(String path, Uint8List image) => Isolate.run(() => embedCoverSync(path, image));
