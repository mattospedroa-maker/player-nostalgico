import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Gravidade de um evento, como no Visualizador de eventos do XP.
enum LogLevel { info, warning, error }

class LogEntry {
  DateTime time;
  final LogLevel level;

  /// De onde veio: "Repetidas", "Editar música", "GIFs"…
  final String source;

  /// Frase curta em português, para a lista.
  final String message;

  /// Motivo em português ("permissão negada"), quando dá para saber.
  String? reason;

  /// Motivo técnico (mensagem da exceção, caminho, pedaço da pilha).
  String? detail;

  /// Quantas vezes o mesmo evento aconteceu seguido ("GIFs · 3×").
  int count;

  LogEntry({required this.time, required this.level, required this.source, required this.message, this.reason, this.detail, this.count = 1});

  Map<String, Object?> toJson() => {'t': time.toIso8601String(), 'l': level.name, 's': source, 'm': message, if (reason != null) 'r': reason, if (detail != null) 'd': detail, if (count > 1) 'n': count};

  static LogEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final time = DateTime.tryParse('${j['t']}');
    final level = LogLevel.values.asNameMap()['${j['l']}'];
    if (time == null || level == null) return null;
    return LogEntry(time: time, level: level, source: '${j['s'] ?? ''}', message: '${j['m'] ?? ''}', reason: j['r'] as String?, detail: j['d'] as String?, count: (j['n'] as num?)?.toInt() ?? 1);
  }

  bool sameAs(LogEntry o) => level == o.level && source == o.source && message == o.message;
}

/// Registro de erros do app: tudo que antes era engolido calado vem parar aqui.
///
/// - [info]: coisas esperadas (sem internet numa busca opcional). Só ficam no registro.
/// - [warn]: algo não saiu como devia. Acende o ⚠ da bandeja; com `balloon: true` (uma ação
///   que a pessoa pediu) também mostra o balão amarelo.
/// - [fail]: erro de verdade. Com `severe: true` (o app quebrou) mostra a caixa vermelha do XP.
class ErrorLog extends ChangeNotifier {
  static const maxEntries = 200;

  /// Mesmo evento dentro deste tempo vira "3×" em vez de outra linha.
  static const mergeWindow = Duration(hours: 6);

  /// Mais novos primeiro.
  final List<LogEntry> entries = [];

  /// Avisos e erros que chegaram desde a última vez que o registro foi aberto (número do ⚠).
  int unseen = 0;

  /// Balão do relógio (opção A).
  void Function(LogEntry e)? onBalloon;

  /// Caixa "encontrou um problema" (opção C).
  void Function(LogEntry e)? onSevere;

  File? _file;
  Timer? _saveTimer;

  /// Carrega o registro salvo no celular (os últimos [maxEntries]).
  Future<void> open(String dir) async {
    _file = File('$dir${Platform.pathSeparator}registro_de_erros.json');
    try {
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString());
        if (j is Map) {
          final loaded = [for (final e in (j['entries'] as List? ?? const [])) ?LogEntry.fromJson(e)];
          // o que chegou antes de abrir (ex.: erro na inicialização) fica por cima
          entries.addAll(loaded.take(maxEntries - entries.length));
          unseen += (j['unseen'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (e) {
      // registro corrompido: começa de novo, mas conta que isso aconteceu
      add(LogLevel.info, 'Registro', 'O registro antigo estava ilegível e foi recomeçado', error: e);
    }
    notifyListeners();
  }

  LogEntry info(String source, String message, [Object? error]) => add(LogLevel.info, source, message, error: error);

  LogEntry warn(String source, String message, {Object? error, bool balloon = false}) =>
      add(LogLevel.warning, source, message, error: error, balloon: balloon);

  LogEntry fail(String source, String message, {Object? error, StackTrace? stack, bool balloon = false, bool severe = false}) =>
      add(LogLevel.error, source, message, error: error, stack: stack, balloon: balloon, severe: severe);

  LogEntry add(LogLevel level, String source, String message, {Object? error, StackTrace? stack, bool balloon = false, bool severe = false}) {
    final now = DateTime.now();
    final e = LogEntry(time: now, level: level, source: source, message: message, reason: reasonOf(error), detail: describe(error, stack));
    LogEntry shown = e;
    final i = entries.indexWhere((o) => o.sameAs(e) && now.difference(o.time) < mergeWindow);
    if (i >= 0) {
      shown = entries.removeAt(i)
        ..count += 1
        ..time = now;
      if (e.detail != null) shown.detail = e.detail;
      if (e.reason != null) shown.reason = e.reason;
      entries.insert(0, shown);
    } else {
      entries.insert(0, e);
      if (entries.length > maxEntries) entries.removeRange(maxEntries, entries.length);
    }
    if (level != LogLevel.info) unseen++;
    if (kDebugMode && level != LogLevel.info) debugPrint('[$source] $message${shown.detail == null ? '' : ' — ${shown.detail}'}');
    _notifySoon();
    _scheduleSave();
    // fora da hora: um erro anotado no meio de um build não pode mexer na tela na mesma hora
    if (severe) {
      final cb = onSevere;
      if (cb != null) scheduleMicrotask(() => cb(shown));
    } else if (balloon) {
      final cb = onBalloon;
      if (cb != null) scheduleMicrotask(() => cb(shown));
    }
    return shown;
  }

  bool _notifyQueued = false;
  void _notifySoon() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      notifyListeners();
    });
  }

  /// A pessoa abriu o registro: o ⚠ da bandeja some.
  void markSeen() {
    if (unseen == 0) return;
    unseen = 0;
    notifyListeners();
    _scheduleSave();
  }

  void clear() {
    entries.clear();
    unseen = 0;
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_file == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    final f = _file;
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode({'unseen': unseen, 'entries': [for (final e in entries) e.toJson()]}));
    } catch (_) {
      // sem onde escrever o próprio registro: não há a quem avisar, segue só na memória
    }
  }

  /// Texto para o botão "Copiar" (uma linha por evento, ou o evento inteiro com detalhes).
  static String asText(Iterable<LogEntry> list) => [
        for (final e in list)
          '${_stamp(e.time)} [${levelName(e.level)}] ${e.source}: ${e.message}${e.count > 1 ? ' (${e.count}×)' : ''}'
              '${e.detail == null ? '' : '\n    ${e.detail!.replaceAll('\n', '\n    ')}'}',
      ].join('\n');

  static String levelName(LogLevel l) => switch (l) {
        LogLevel.info => 'Informação',
        LogLevel.warning => 'Aviso',
        LogLevel.error => 'Erro',
      };

  static String _stamp(DateTime t) =>
      '${t.day.toString().padLeft(2, '0')}/${t.month.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Motivo técnico curto, sem a pilha inteira (só as primeiras linhas, para erros de verdade).
  static String? describe(Object? error, [StackTrace? stack]) {
    if (error == null) return null;
    var s = '$error';
    if (s.length > 600) s = '${s.substring(0, 600)}…';
    if (stack != null) {
      final lines = '$stack'.split('\n').where((l) => l.trim().isNotEmpty).take(6).join('\n');
      if (lines.isNotEmpty) s = '$s\n$lines';
    }
    return s;
  }

  /// Motivo em português para os erros mais comuns (para o balão e a lista).
  static String? reasonOf(Object? error) {
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      return switch (code) {
        1 || 13 => 'permissão negada',
        2 => 'arquivo não existe mais',
        16 => 'arquivo em uso',
        28 => 'sem espaço no celular',
        30 => 'pasta só de leitura',
        _ => 'erro de arquivo',
      };
    }
    if (isNetwork(error)) return 'sem internet ou serviço fora do ar';
    if (error is FormatException) return 'resposta em formato inesperado';
    return null;
  }

  /// Erros de rede são esperados no celular (metrô, modo avião): nunca viram aviso.
  static bool isNetwork(Object? error) =>
      error is SocketException || error is HttpException || error is TimeoutException || error is HandshakeException || '${error.runtimeType}' == 'ClientException';
}

/// O registro do app (um só, para qualquer parte do código poder anotar).
final errorLog = ErrorLog();
