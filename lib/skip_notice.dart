import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'player_service.dart';
import 'skip_guard.dart';
import 'theme.dart';
import 'xp_icons.dart';

/// Chaves globais do app, para avisar de qualquer tela (o player avisa mesmo sem tela aberta).
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Avisos de música que não abriu: o balão amarelo do relógio (some sozinho em 5 s) e, se a fila
/// inteira falhar, uma caixa de mensagem do XP uma vez só.
class SkipNotice {
  static const shownFor = Duration(seconds: 5);

  /// Falhas que ainda estão no balão aberto (várias seguidas viram "3 músicas puladas").
  static final List<(Track, PlaybackFailure)> _recent = [];
  static Timer? _clear;
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _open;

  static void attach(PlayerService ps) {
    ps
      ..onTrackFailed = trackFailed
      ..onAllFailed = allFailed;
  }

  /// Texto do balão (separado para testar).
  static (String title, String body) balloonText(List<(Track, PlaybackFailure)> recent) {
    if (recent.length == 1) {
      final (t, f) = recent.single;
      return ('Música pulada', '"${t.title}" não abriu (${f.reasonText}).\nPulei para a próxima.');
    }
    final names = recent.map((r) => r.$1.title).take(3).join(', ');
    final more = recent.length > 3 ? ' e mais ${recent.length - 3}' : '';
    return ('${recent.length} músicas puladas', '$names$more não abriram.\nVeja na Lista de reprodução.');
  }

  static void trackFailed(Track t, PlaybackFailure f) {
    final m = appMessengerKey.currentState;
    if (m == null) return;
    _recent.add((t, f));
    _clear?.cancel();
    _clear = Timer(shownFor, _recent.clear);
    final (title, body) = balloonText(_recent);
    _open?.close();
    _open = m.showSnackBar(SnackBar(
      duration: shownFor,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const XpIcon(XpIcons.warning, size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(fontSize: 13.5)),
      ]),
    ));
    _open!.closed.then((_) => _open = null);
  }

  static void allFailed(List<Track> failed) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    _open?.close();
    _recent.clear();
    final n = failed.length;
    showDialog<void>(
      context: ctx,
      builder: (c) => XpAlertDialog(
        icon: XpIcons.warning,
        title: const Text('Não foi possível tocar'),
        content: Text(n <= 1
            ? 'O Nostalgic MPlayer não conseguiu abrir "${failed.isEmpty ? 'a música' : failed.first.title}".\n'
                'O arquivo pode estar com defeito ou ter sido apagado.'
            : 'Nenhuma das próximas músicas abriu ($n arquivos).\n'
                'Elas podem estar com defeito ou ter sido apagadas. Estão riscadas na Lista de reprodução.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }
}
