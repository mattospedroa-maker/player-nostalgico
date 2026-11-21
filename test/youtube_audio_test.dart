import 'dart:async';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/download_service.dart';
import 'package:player_nostalgico/filename_parser.dart';
import 'package:player_nostalgico/metadata.dart';
import 'package:player_nostalgico/ytdlp.dart';

/// yt-dlp de mentira: guarda os comandos e faz o que cada teste mandar (sem rede).
class FakeYtDlp extends YtDlp {
  final List<List<String>> calls = [];
  final Future<YtRun> Function(List<String> args, String outDir) onRun;
  FakeYtDlp(this.onRun);

  @override
  Future<YtRun> run(List<String> args, {String? id, bool download = false, void Function(double, String)? onProgress}) {
    calls.add(args);
    final out = p.dirname(args[args.indexOf('-o') + 1]);
    return onRun(args, out);
  }
}

const noFormat = 'ERROR: [youtube] abc: Requested format is not available. Use --list-formats for a list of available formats';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('yt_audio_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('comando do yt-dlp', () {
    test('caminho AAC copia o áudio: m4a, qualidade 0, sem mp3, sem -c:a aac, sem capa embutida', () {
      final a = YtDlp.aacArgs('https://youtu.be/abc', '/tmp/x');
      final joined = a.join(' ');
      expect(a.sublist(0, 2), ['-f', 'ba[acodec^=aac][ext=m4a]/ba[ext=m4a]']);
      expect(joined, contains('-x --audio-format m4a --audio-quality 0'));
      expect(joined, isNot(contains('--audio-format mp3')));
      expect(joined, isNot(contains('-c:a aac')));
      expect(joined, isNot(contains('libfdk_aac')));
      for (final gone in ['--embed-thumbnail', '--convert-thumbnails', '--ppa', '--postprocessor-args']) {
        expect(a, isNot(contains(gone)));
      }
      expect(a, containsAll(['--embed-metadata', '--no-playlist', '--no-mtime', '--no-warnings', '--newline']));
      expect(a[a.indexOf('--concurrent-fragments') + 1], '4');
      expect(a, isNot(contains('-N'))); // -N é o mesmo que --concurrent-fragments: um só, no máximo 4
      expect(a.last, 'https://youtu.be/abc');
    });

    test('plano B do Opus converte uma vez para AAC 192k (podcast 96k), só no ExtractAudio', () {
      final a = YtDlp.opusFallbackArgs('https://youtu.be/abc', '/tmp/x');
      final joined = a.join(' ');
      expect(a.sublist(0, 2), ['-f', 'ba']);
      expect(joined, contains('--audio-format m4a'));
      expect(joined, contains('-c:a aac -b:a 192k'));
      expect(a[a.indexOf('--postprocessor-args') + 1], 'ExtractAudio:-c:a aac -b:a 192k -vn');
      expect(a[a.indexOf('--audio-quality') + 1], '192K'); // com 0 o FFmpeg ignoraria o -b:a
      expect(joined, isNot(contains('mp3')));
      expect(joined, isNot(contains('libfdk_aac')));
      expect(joined, isNot(contains('--embed-thumbnail')));

      final pod = YtDlp.opusFallbackArgs('https://youtu.be/abc', '/tmp/x', bitrate: '96k').join(' ');
      expect(pod, contains('-c:a aac -b:a 96k'));
    });

    test('"convertendo" só aparece na conversão de verdade (plano B)', () {
      expect(YtDlp.isConvertingLine('[download]  42.0% of 3.10MiB at 1.2MiB/s ETA 00:02'), isFalse);
      expect(YtDlp.isConvertingLine('[download] Destination: /tmp/x/abc.m4a'), isFalse);
      expect(YtDlp.isConvertingLine('[ExtractAudio] Not converting audio /tmp/x/abc.m4a; file is already in target format m4a'), isFalse);
      expect(YtDlp.isConvertingLine('[Metadata] Adding metadata to "/tmp/x/abc.m4a"'), isFalse);
      expect(YtDlp.isConvertingLine('[ExtractAudio] Destination: /tmp/x/abc.m4a'), isTrue);
    });
  });

  group('downloadAudio', () {
    test('vídeo com AAC: um comando só, devolve o .m4a', () async {
      final yt = FakeYtDlp((args, out) async {
        File(p.join(out, 'abc.m4a')).writeAsBytesSync([1, 2, 3]);
        return const YtRun(0, '', '');
      });
      final path = await yt.downloadAudio('https://youtu.be/abc', tmp.path, id: 'abc');
      expect(yt.calls, hasLength(1));
      expect(yt.calls.single.join(' '), isNot(contains('-c:a aac')));
      expect(p.basename(path), 'abc.m4a');
      expect(isAudioFile(path), isTrue);
    });

    test('vídeo sem AAC (só Opus): cai no plano B e converte uma vez', () async {
      final yt = FakeYtDlp((args, out) async {
        if (args.contains('--postprocessor-args')) {
          File(p.join(out, 'abc.m4a')).writeAsBytesSync([1, 2, 3]);
          return const YtRun(0, '', '');
        }
        return const YtRun(1, '', noFormat);
      });
      final path = await yt.downloadAudio('https://youtu.be/abc', tmp.path, id: 'abc', fallbackBitrate: '96k');
      expect(yt.calls, hasLength(2));
      expect(yt.calls.last.join(' '), contains('-c:a aac -b:a 96k'));
      expect(p.extension(path), '.m4a');
    });

    test('no Android o "sem formato" chega como exceção: também cai no plano B', () async {
      final yt = FakeYtDlp((args, out) async {
        if (!args.contains('--postprocessor-args')) throw YtDlpException.from(noFormat);
        File(p.join(out, 'abc.m4a')).writeAsBytesSync([1]);
        return const YtRun(0, '', '');
      });
      await yt.downloadAudio('https://youtu.be/abc', tmp.path, id: 'abc');
      expect(yt.calls, hasLength(2));
    });

    test('outro erro (vídeo privado) não tenta o plano B', () async {
      final yt = FakeYtDlp((args, out) async => throw YtDlpException.from('ERROR: [youtube] abc: Private video'));
      await expectLater(yt.downloadAudio('https://youtu.be/abc', tmp.path, id: 'abc'), throwsA(isA<YtDlpException>()));
      expect(yt.calls, hasLength(1));
    });
  });

  group('fila com dois ao mesmo tempo', () {
    test('três itens: dois andam juntos e o terceiro espera uma vaga', () async {
      final items = ['a', 'b', 'c'];
      final started = <String>[];
      final gates = {for (final i in items) i: Completer<void>()};
      final q = ParallelQueue<String>(2, () => items.isEmpty ? null : items.removeAt(0), (i) {
        started.add(i);
        return gates[i]!.future;
      });
      var finished = false;
      unawaited(q.run().then((_) => finished = true));
      await pumpEventQueue();
      expect(started, ['a', 'b']);
      expect(q.active, 2);

      gates['b']!.complete();
      await pumpEventQueue();
      expect(started, ['a', 'b', 'c']);
      expect(q.active, 2);

      gates['a']!.complete();
      gates['c']!.complete();
      await pumpEventQueue();
      expect(finished, isTrue);
      expect(q.active, 0);
    });

    test('item que entra depois ocupa a vaga livre (poke)', () async {
      final items = <String>['a'];
      final started = <String>[];
      final gate = Completer<void>();
      final q = ParallelQueue<String>(2, () => items.isEmpty ? null : items.removeAt(0), (i) {
        started.add(i);
        return gate.future;
      });
      unawaited(q.run());
      await pumpEventQueue();
      items.addAll(['b', 'c']);
      q.poke();
      await pumpEventQueue();
      expect(started, ['a', 'b']);
      gate.complete();
    });
  });

  group('tags e BPM no .m4a', () {
    File copyFixture() => File('test/fixtures/tagged.m4a').copySync(p.join(tmp.path, 'abc.m4a'));

    test('tags gravadas nos átomos do MP4 (sem ID3); gênero "Music" do YouTube sai', () {
      final f = copyFixture();
      writeDownloadTags(f.path, title: 'Numb', artist: 'Linkin Park', album: 'Meteora');
      final bytes = f.readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(0, 3)), isNot('ID3'));
      expect(amr.readAllMetadata(f, getImage: false), isA<amr.Mp4Metadata>());
      final t = FileMetadataReader.readTagsSync(f.path)!;
      expect([t.title, t.artist, t.album, t.genre], ['Numb', 'Linkin Park', 'Meteora', '']);
      expect(t.duration, isNotNull); // o áudio continua inteiro
      expect(t.year, isNull); // não fica ano absurdo
    });

    test('podcast leva gênero "Podcast"', () {
      final f = copyFixture();
      writeDownloadTags(f.path, title: 'Episódio 1', artist: 'Programa', album: 'Programa', podcast: true);
      final t = FileMetadataReader.readTagsSync(f.path)!;
      expect([t.title, t.artist, t.album, t.genre], ['Episódio 1', 'Programa', 'Programa', 'Podcast']);
    });

    test('BPM do átomo tmpo é lido do M4A; fora de 40–220 continua inválido', () {
      final f = copyFixture();
      expect(FileMetadataReader.readTagsSync(f.path)!.bpm, 128);

      final bytes = f.readAsBytesSync();
      final i = String.fromCharCodes(bytes).indexOf('tmpo');
      bytes[i + 20] = 0;
      bytes[i + 21] = 250; // 250 BPM: inválido
      f.writeAsBytesSync(bytes);
      expect(FileMetadataReader.readTagsSync(f.path)!.bpm, isNull);
    });

    test('M4A sem tmpo: sem BPM, sem erro', () {
      final f = copyFixture();
      writeDownloadTags(f.path, title: 'X', artist: 'Y', album: 'Z'); // a escrita reconstrói a lista de tags sem tmpo
      expect(FileMetadataReader.mp4BpmOf(f.path), isNull);
    });

    test('.m4a passa em isAudioFile', () {
      expect(isAudioFile('/musicas/Linkin Park/Meteora/Numb.m4a'), isTrue);
    });
  });
}
