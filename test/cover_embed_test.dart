import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/cover_embed.dart';
import 'package:player_nostalgico/download_service.dart';
import 'package:player_nostalgico/metadata.dart';

/// "JPEG" mínimo: o leitor só olha os primeiros bytes.
Uint8List fakeJpeg([int fill = 7]) => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(2000, fill), 0xFF, 0xD9]);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cover_embed_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File m4a() => File('test/fixtures/tagged.m4a').copySync(p.join(tmp.path, 'Numb.m4a'));

  test('capa entra no .m4a (átomo covr) e as tags continuam', () async {
    final f = m4a();
    writeDownloadTags(f.path, title: 'Numb', artist: 'Linkin Park', album: 'Meteora');
    expect(await const FileMetadataReader().cover(f.path), isNull);

    expect(embedCoverSync(f.path, fakeJpeg()), isTrue);
    expect(String.fromCharCodes(f.readAsBytesSync()).contains('covr'), isTrue);
    expect(await const FileMetadataReader().cover(f.path), fakeJpeg());
    final t = FileMetadataReader.readTagsSync(f.path)!;
    expect([t.title, t.artist, t.album], ['Numb', 'Linkin Park', 'Meteora']);
    expect(t.duration, isNotNull);
  });

  test('não troca capa que já existe', () async {
    final f = m4a();
    expect(embedCoverSync(f.path, fakeJpeg(1)), isTrue);
    expect(embedCoverSync(f.path, fakeJpeg(2)), isFalse);
    expect(await const FileMetadataReader().cover(f.path), fakeJpeg(1));
  });

  test('arquivo que não é imagem não entra; ano absurdo do yt-dlp não é regravado', () {
    final f = m4a();
    expect(embedCoverSync(f.path, Uint8List.fromList(List.filled(3000, 1))), isFalse);
    expect(imageMime(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]))!, 'image/png');
    expect(embedCoverSync(f.path, fakeJpeg()), isTrue); // o fixture tem ©day 20261121
    expect(FileMetadataReader.readTagsSync(f.path)!.year, isNull);
  });

  test('em segundo plano (isolate) também grava', () async {
    final f = m4a();
    expect(await embedCoverInBackground(f.path, fakeJpeg()), isTrue);
    expect(await const FileMetadataReader().cover(f.path), fakeJpeg());
  });
}
