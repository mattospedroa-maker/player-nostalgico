import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'error_log.dart';
import 'filename_parser.dart';

/// Resultado de uma execução do yt-dlp.
class YtRun {
  final int exitCode;
  final String out;
  final String err;
  const YtRun(this.exitCode, this.out, this.err);
}

class YtDlpException implements Exception {
  final String message;

  /// O erro tem cara de yt-dlp velho (o YouTube mudou): vale atualizar e tentar de novo.
  final bool outdated;
  const YtDlpException(this.message, {this.outdated = false});

  /// Monta a exceção a partir do texto do yt-dlp: mensagem em português e se parece versão velha.
  factory YtDlpException.from(String raw) => YtDlpException(YtDlp.friendly(raw), outdated: YtDlp.looksOutdated(raw));
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
        throw YtDlpException.from(e.message ?? e.code);
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
  /// Devolve "DONE" (atualizou) ou "ALREADY_UP_TO_DATE" (já era a mais nova).
  Future<String> update() async {
    if (!Platform.isAndroid) {
      // no PC: o próprio yt-dlp se atualiza (se foi instalado de um jeito que permite)
      final r = await _runDesktop(['-U']);
      if (r.exitCode != 0) throw YtDlpException(friendly(r.err.isNotEmpty ? r.err : r.out));
      return r.out.toLowerCase().contains('up to date') ? 'ALREADY_UP_TO_DATE' : 'DONE';
    }
    return await _channel.invokeMethod<String>('update') ?? '';
  }

  /// Sinais de que o yt-dlp ficou velho para o YouTube de hoje (e não de vídeo privado, sem internet etc.).
  static bool looksOutdated(String raw) {
    final l = raw.toLowerCase();
    if (l.contains('private video') || l.contains('video unavailable') || l.contains('has been removed')) return false;
    if (l.contains('sign in to confirm') || l.contains('age-restricted')) return false;
    if (l.contains('failed to resolve') || l.contains('network is unreachable') || l.contains('timed out')) return false;
    return const [
      'confirm you are on the latest version',
      'yt-dlp -u',
      'unable to extract',
      'nsig extraction failed',
      'signature extraction failed',
      'failed to extract any player response',
      'precondition check failed',
      'http error 403',
      'requested format is not available',
      'only images are available',
      'some formats may be missing',
      'page needs to be reloaded',
      'unsupported js',
      'n challenge',
    ].any(l.contains);
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

  /// Fila parou sem nada para contar: tira a notificação e deixa o Android fechar o app quando quiser.
  Future<void> notifyClear() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('notifyClear');
    } catch (e) {
      errorLog.info('YouTube', 'Não deu para tirar a notificação do download', e);
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
    if (r.exitCode != 0 || start < 0) throw YtDlpException.from(r.err.isNotEmpty ? r.err : r.out);
    return jsonDecode(r.out.substring(start)) as Map<String, dynamic>;
  }

  /// Fragmentos baixados ao mesmo tempo (mais que 4 não ajuda e pesa no celular).
  static const fragments = 4;

  /// Caminho rápido: pega o áudio AAC que o YouTube já entrega em .m4a e só copia (sem recodificar).
  /// `--audio-quality 0` com saída M4A não converte nada quando o áudio já é AAC.
  /// Sem capa embutida (a capa vem do Cover Art Archive): o arquivo fica pronto assim que o download termina.
  static List<String> aacArgs(String url, String outDir) => [
        '-f', 'ba[acodec^=aac][ext=m4a]/ba[ext=m4a]',
        '-x', '--audio-format', 'm4a', '--audio-quality', '0',
        ..._commonArgs(url, outDir),
      ];

  /// Plano B, só quando o vídeo não tem áudio AAC (o YouTube só oferece Opus): converte uma única vez para AAC.
  /// O `--audio-quality` com o mesmo valor em kbps é necessário: com `0` o yt-dlp passa `-q:a`, e aí o FFmpeg
  /// ignora o `-b:a` (testado: saía ~250 kbps em vez de 192). Os argumentos valem só para a conversão
  /// (`ExtractAudio`); com `ffmpeg:` eles iriam também para o passo que grava as tags e recodificariam de novo.
  /// Nunca `libfdk_aac`: o FFmpeg embarcado não tem esse encoder.
  static List<String> opusFallbackArgs(String url, String outDir, {String bitrate = '192k'}) => [
        '-f', 'ba',
        '-x', '--audio-format', 'm4a', '--audio-quality', bitrate.toUpperCase(),
        '--postprocessor-args', 'ExtractAudio:-c:a aac -b:a $bitrate -vn',
        ..._commonArgs(url, outDir),
      ];

  static List<String> _commonArgs(String url, String outDir) => [
        '--concurrent-fragments', '$fragments', // o mesmo que -N 4
        '--embed-metadata',
        // data do vídeo só com o ano: "20180724" em ©day quebra a leitura das tags no celular
        '--parse-metadata', r'upload_date:(?P<meta_date>\d{4})',
        '--no-playlist', '--no-mtime', '--no-warnings', '--newline',
        '-o', '$outDir${Platform.pathSeparator}%(id)s.%(ext)s',
        url,
      ];

  /// O vídeo não tem áudio .m4a/AAC (só Opus): hora do plano B.
  static bool noAacFormat(String raw) => raw.toLowerCase().contains('requested format is not available');

  /// Linha do log que mostra conversão de verdade (só no plano B do Opus).
  /// No caminho copiado aparece "[ExtractAudio] Not converting audio ...", que não é conversão.
  static bool isConvertingLine(String line) => line.contains('[ExtractAudio]') && !line.contains('Not converting');

  /// Baixa só o áudio. Devolve o caminho do .m4a gerado dentro de [outDir].
  /// Tenta primeiro copiar o AAC; se o vídeo não tiver, converte o Opus para AAC em [fallbackBitrate].
  Future<String> downloadAudio(String url, String outDir,
      {required String id, String fallbackBitrate = '192k', void Function(double, String)? onProgress}) async {
    await Directory(outDir).create(recursive: true);
    YtRun r;
    try {
      r = await run(aacArgs(url, outDir), id: id, download: true, onProgress: onProgress);
    } on YtDlpException catch (e) {
      // no Android o yt-dlp com erro vira exceção; no PC volta como código de saída
      if (!noAacFormat(e.message)) rethrow;
      r = YtRun(1, '', e.message);
    }
    if (r.exitCode != 0 && noAacFormat(r.err) && _audioIn(outDir) == null) {
      r = await run(opusFallbackArgs(url, outDir, bitrate: fallbackBitrate), id: id, download: true, onProgress: onProgress);
    }
    final file = _audioIn(outDir);
    if (file == null) throw YtDlpException.from(r.err.isNotEmpty ? r.err : 'O yt-dlp terminou sem gerar o áudio (código ${r.exitCode}).');
    return file;
  }

  /// O áudio pronto na pasta temporária (.m4a de preferência; nunca pedaços .part).
  static String? _audioIn(String dir) {
    final files = Directory(dir).listSync().whereType<File>().map((f) => f.path).where(isAudioFile).toList();
    if (files.isEmpty) return null;
    return files.firstWhere((f) => f.toLowerCase().endsWith('.m4a'), orElse: () => files.first);
  }

  /// Mensagens do yt-dlp em português, para os erros mais comuns.
  static String friendly(String raw) {
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
