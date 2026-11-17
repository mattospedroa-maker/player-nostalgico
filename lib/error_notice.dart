import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'error_log.dart';
import 'screens/event_log_screen.dart';
import 'skip_notice.dart';
import 'theme.dart';
import 'xp_icons.dart';

/// Como o registro de erros aparece na tela (escolha de Cuseko: A + B, C só no grave):
/// - A: balão amarelo do relógio quando algo que a pessoa pediu falhou;
/// - B: ⚠ com número na bandeja do relógio (ver [TrayErrorIcon]);
/// - C: caixa vermelha "encontrou um problema" só quando o app quebra.
class ErrorNotice {
  static const shownFor = Duration(seconds: 5);

  /// Caixas vermelhas: no máximo uma a cada este tempo (um erro em loop não vira enxurrada).
  static const severeGap = Duration(seconds: 30);

  static final List<LogEntry> _recent = [];
  static Timer? _clear;
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _open;
  static bool _severeOpen = false;
  static DateTime? _lastSevere;

  static void attach(ErrorLog log) {
    log
      ..onBalloon = balloon
      ..onSevere = severe;
  }

  /// Texto do balão (separado para testar). Vários avisos em 5 s viram um balão só.
  static (String title, String body) balloonText(List<LogEntry> recent) {
    if (recent.length == 1) {
      final e = recent.single;
      return (e.message, e.reason == null ? 'Toque em "Detalhes" para ver o motivo.' : 'Motivo: ${e.reason}.');
    }
    final sources = recent.map((e) => e.source).toSet();
    final first = recent.first;
    final more = recent.length - 1;
    return (
      '${recent.length} avisos${sources.length == 1 ? ' · ${sources.single}' : ''}',
      '${first.message}${first.reason == null ? '' : ' (${first.reason})'} e mais $more.',
    );
  }

  static void balloon(LogEntry e) {
    final m = appMessengerKey.currentState;
    if (m == null) return;
    // o mesmo evento repetido (count++) não entra duas vezes na lista do balão
    _recent
      ..remove(e)
      ..add(e);
    _clear?.cancel();
    _clear = Timer(shownFor, _recent.clear);
    final (title, body) = balloonText(_recent);
    final select = _recent.first;
    _open?.close();
    _open = m.showSnackBar(SnackBar(
      duration: shownFor,
      action: SnackBarAction(label: 'Detalhes', onPressed: () => openLog(select: select)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          XpIcon(e.level == LogLevel.error ? XpIcons.error : XpIcons.warning, size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(fontSize: 13.5)),
      ]),
    ));
    _open!.closed.then((_) => _open = null);
  }

  static void severe(LogEntry e) {
    final ctx = appNavigatorKey.currentContext;
    final now = DateTime.now();
    if (ctx == null || _severeOpen || (_lastSevere != null && now.difference(_lastSevere!) < severeGap)) return;
    _severeOpen = true;
    _lastSevere = now;
    _open?.close();
    showDialog<void>(
      context: ctx,
      builder: (c) => XpAlertDialog(
        icon: XpIcons.error,
        title: const Text('Nostalgic MPlayer'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('O Nostalgic MPlayer encontrou um problema.', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('${e.message}${e.reason == null ? '' : ' (${e.reason})'}.\n'
              'A música continua. Os detalhes técnicos ficaram no registro de erros.'),
        ]),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.pop(c);
                openLog(select: e);
              },
              child: const Text('Ver registro')),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
        ],
      ),
    ).whenComplete(() => _severeOpen = false);
  }

  /// Abre o Visualizador de eventos (de qualquer tela).
  static void openLog({LogEntry? select}) {
    _open?.close();
    appNavigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => EventLogScreen(select: select)));
  }
}

/// Opção B: ⚠ com o número de avisos novos, ao lado do relógio da barra de tarefas.
class TrayErrorIcon extends StatelessWidget {
  final ErrorLog log;
  const TrayErrorIcon({super.key, required this.log});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final n = log.unseen;
          if (n == 0) return const SizedBox.shrink();
          final worst = log.entries.take(n).any((e) => e.level == LogLevel.error) ? XpIcons.error : XpIcons.warning;
          return Semantics(
            button: true,
            label: '$n ${n == 1 ? 'aviso novo' : 'avisos novos'}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _menu(context, d.globalPosition),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 9, 8),
                child: Stack(clipBehavior: Clip.none, children: [
                  XpIcon(worst, size: 16),
                  Positioned(
                    right: -7,
                    top: -7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3.5),
                      constraints: const BoxConstraints(minWidth: 15),
                      decoration: BoxDecoration(color: const Color(0xFFD8341A), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white, width: 1)),
                      child: Text(n > 9 ? '9+' : '$n',
                          textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold, height: 1.25)),
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      );

  void _menu(BuildContext context, Offset at) {
    final n = log.unseen;
    showXpTrayMenu(context, at: at, items: [
      ('Ver registro de erros ($n ${n == 1 ? 'novo' : 'novos'})', XpIcons.list, ErrorNotice.openLog),
      ('Limpar avisos', XpIcons.check, log.markSeen),
    ]);
  }
}

/// Menu branco do XP que abre para cima, a partir da bandeja.
void showXpTrayMenu(BuildContext context, {required Offset at, required List<(String, XpIcons, VoidCallback)> items}) {
  showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Fechar menu',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 90),
    pageBuilder: (ctx, _, _) {
      final size = MediaQuery.sizeOf(ctx);
      const w = 270.0;
      return Stack(children: [
        Positioned(
          right: 6,
          bottom: (size.height - at.dy + 22).clamp(0.0, size.height),
          width: w,
          child: Material(
            color: Colors.white,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border.fromBorderSide(BorderSide(color: Color(0xFF808080))),
                boxShadow: [BoxShadow(color: Color(0x59000000), offset: Offset(2, 2), blurRadius: 2)],
              ),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (label, icon, onTap) in items)
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      onTap();
                    },
                    hoverColor: Xp.select,
                    highlightColor: Xp.select,
                    child: SizedBox(
                      height: 42,
                      child: Row(children: [
                        SizedBox(width: 40, child: Center(child: XpIcon(icon, size: 18))),
                        Expanded(child: Text(label, style: const TextStyle(fontSize: 14.5, color: Colors.black))),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ]);
    },
  );
}
