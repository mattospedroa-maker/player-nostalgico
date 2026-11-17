import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'error_log.dart';

/// Resultado de uma execução do yt-dlp.
class YtRun {
  final int exitCode;
  final String out;
  final String err;
  const YtRun(this.exitCode, this.out, this.err);
}

class YtDlpException implements Exception {
  final String message;
  const YtDlpException(this.message);
  @override
  String toString() => message;
}

/// O yt-dlp (o mesmo programa do yt-dlp.exe).
/// No Android roda a versão embarcada no APK (com Python e ffmpeg). No PC chama o yt-dlp instalado (precisa do ffmpeg).
class YtDlp {
  static const _channel = MethodChannel('nostalgic/ytdlp');
  static const _events = EventChannel('nostalgic/ytdlp/progress');

  /// No PC: caminho do yt-dlp (padrão: o que estiver no PATH).
  String desktopBinary = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';

  final Map<String, void Function(double progress, String line)> _listeners = {};
  final Map<String, Process> _desktopProcs = {};
  StreamSubscription<dynamic>? _sub;

  void _listen() {
    if (!Platform.isAndroid || _sub != null) return;
    _sub = _events.receiveBroadcastStream().listen((e) {
      final m = (e as Map).cast<String, dynamic>();
      _listeners[m['id']]?.call((m['progress'] as num?)?.toDouble() ?? 0, '${m['line'] ?? ''}');
    }, onError: (_) {});
  }

  /// Roda o yt-dlp com [args]. [id] permite cancelar e receber o progresso.
  Future<YtRun> run(List<String> args, {String? id, bool download = false, void Function(double, String)? onProgress}) async {
    if (Platform.isAndroid) {
      _listen();
      if (id != null && onProgress != null) _listeners[id] = onProgress;
      try {
        final r = await _channel.invokeMapMethod<String, dynamic>('run', {'args': args, 'id': id, 'download': download});
        return YtRun((r?['exitCode'] as int?) ?? -1, '${r?['out'] ?? ''}', '${r?['err'] ?? ''}');
      } on PlatformException catch (e) {
        if (e.code == 'canceled') throw const YtDlpException('Cancelado');
        throw YtDlpException(_friendly(e.message ?? e.code));
      } finally {
        if (id != null) _listeners.remove(id);
      }
    }
    return _runDesktop(args, id: id, onProgress: onProgress);
  }

  Future<YtRun> _runDesktop(List<String> args, {String? id, void Function(double, String)? onProgress}) async {
    final Process proc;
    try {
      proc = await Process.start(desktopBinary, ['--newline', ...args]);
    } on ProcessException {
      throw const YtDlpException('Não achei o yt-dlp no computador. Coloque o yt-dlp (e o ffmpeg) no PATH.');
    }
    if (id != null) _desktopProcs[id] = proc;
    final out = StringBuffer(), err = StringBuffer();
    final percent = RegExp(r'\[download\]\s+([\d.]+)%');
    final a = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      out.writeln(l);
      final m = percent.firstMatch(l);
      if (m != null) onProgress?.call(double.tryParse(m.group(1)!) ?? 0, l);
    }).asFuture<void>();
    final b = proc.stderr.transform(utf8.decoder).listen(err.write).asFuture<void>();
    final code = await proc.exitCode;
    await Future.wait([a, b]);
    final killed = id != null && _desktopProcs.remove(id) == null;
    if (killed) throw const YtDlpException('Cancelado');
    return YtRun(code, out.toString(), err.toString());
  }

  Future<void> cancel(String id) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<bool>('cancel', {'id': id});
    } else {
      _desktopProcs.remove(id)?.kill();
    }
  }

  /// Atualiza o yt-dlp embarcado (o YouTube muda e versões velhas param de funcionar).
  Future<String> update() async {
    if (!Platform.isAndroid) return '';
    return await _channel.invokeMethod<String>('update') ?? '';
  }

  Future<String> version() async {
    if (Platform.isAndroid) return await _channel.invokeMethod<String>('version') ?? '';
    final r = await _runDesktop(['--version']);
    return r.out.trim();
  }

  /// Notificação "Baixando 3 de 11" (só Android).
  Future<void> notify(String title, String text, {int progress = -1, bool done = false}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('notify', {'title': title, 'text': text, 'progress': progress, 'done': done});
    } catch (e) {
      errorLog.info('YouTube', 'Não deu para atualizar a notificação do download', e);
    }
  }

  /// Informações do vídeo ou da playlist (JSON do -J).
  Future<Map<String, dynamic>> info(String url, {required bool playlist}) async {
    final r = await run([
      '-J',
      '--no-warnings',
      if (playlist) '--flat-playlist' else '--no-playlist',
      url,
    ]);
    final start = r.out.indexOf('{');
    if (r.exitCode != 0 || start < 0) throw YtDlpException(_friendly(r.err.isNotEmpty ? r.err : r.out));
    return jsonDecode(r.out.substring(start)) as Map<String, dynamic>;
  }

  /// Argumentos para baixar só o áudio e converter em .mp3 (com capa quadrada e tags).
  static List<String> mp3Args(String url, String outDir) => [
        '-f', 'bestaudio/best',
        '-x', '--audio-format', 'mp3', '--audio-quality', '192K',
        '--embed-metadata',
        '--embed-thumbnail', '--convert-thumbnails', 'jpg',
        // capa quadrada (miniatura do YouTube é 16:9)
        '--ppa', r'ThumbnailsConvertor+FFmpeg_o:-c:v mjpeg -vf "crop=min(iw\,ih):min(iw\,ih)"',
        '--no-playlist', '--no-mtime', '--no-warnings', '--newline',
        '-o', '$outDir${Platform.pathSeparator}%(id)s.%(ext)s',
        url,
      ];

  /// Baixa e converte. Devolve o caminho do .mp3 gerado dentro de [outDir].
  Future<String> downloadMp3(String url, String outDir, {required String id, void Function(double, String)? onProgress}) async {
    await Directory(outDir).create(recursive: true);
    final r = await run(mp3Args(url, outDir), id: id, download: true, onProgress: onProgress);
    final mp3s = Directory(outDir).listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.mp3')).toList();
    if (mp3s.isEmpty) throw YtDlpException(_friendly(r.err.isNotEmpty ? r.err : 'O yt-dlp terminou sem gerar o .mp3 (código ${r.exitCode}).'));
    return mp3s.first.path;
  }

  /// Mensagens do yt-dlp em português, para os erros mais comuns.
  static String _friendly(String raw) {
    final s = raw.trim();
    final l = s.toLowerCase();
    if (l.contains('private video')) return 'Vídeo privado.';
    if (l.contains('video unavailable') || l.contains('has been removed')) return 'Vídeo indisponível ou removido.';
    if (l.contains('sign in to confirm your age') || l.contains('age-restricted')) return 'Vídeo com restrição de idade (o YouTube pede login).';
    if (l.contains('sign in to confirm') && l.contains('bot')) return 'O YouTube pediu confirmação de que não é robô. Tente de novo mais tarde.';
    if (l.contains('unable to download webpage') || l.contains('failed to resolve') || l.contains('network is unreachable')) {
      return 'Sem internet ou o YouTube não respondeu.';
    }
    if (l.contains('is not a valid url') || l.contains('unsupported url')) return 'Esse link não é de um vídeo ou playlist.';
    if (l.contains('ytdlpexception') && (l.contains('init') || l.contains('python') || l.contains('extract'))) {
      return 'Não consegui preparar o yt-dlp no celular. Feche e abra o app e tente de novo. (Detalhe: $s)';
    }
    final lines = s.split('\n').where((x) => x.contains('ERROR')).toList();
    final msg = (lines.isNotEmpty ? lines.last : s).replaceFirst(RegExp(r'^ERROR:\s*'), '').trim();
    // nunca mostrar só um código curto sem explicação
    if (msg.length < 12) return 'O yt-dlp falhou (detalhe técnico: ${msg.isEmpty ? 'sem mensagem' : msg}). Tente de novo; se continuar, me mande este texto.';
    return msg;
  }
}
