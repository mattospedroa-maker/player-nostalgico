import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../play_stats.dart';
import '../player_service.dart';
import '../smart_collections.dart';
import '../theme.dart';
import '../xp_icons.dart';
import 'track_list_screen.dart';

/// Caixa de seleção do XP ("Todos ▾"): rótulo em cima, campo branco com a setinha azul.
class XpCombo extends StatelessWidget {
  final String label;
  final String value;
  final bool set;
  final VoidCallback onTap;
  const XpCombo({super.key, required this.label, required this.value, required this.onTap, this.set = false});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFF333333))),
        const SizedBox(height: 2),
        GestureDetector(
          onTap: onTap,
          child: Container(
            height: 30,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFF7F9DB9))),
            child: Row(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: set ? FontWeight.bold : FontWeight.normal, color: Colors.black)),
                ),
              ),
              Container(
                width: 22,
                margin: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFC6D7FB), Color(0xFF9BB7EE)]),
                  border: Border.all(color: const Color(0xFFB9CDF6)),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Icon(Icons.arrow_drop_down, size: 20, color: Color(0xFF4D6185)),
              ),
            ]),
          ),
        ),
      ]);
}

/// Lista de escolha numa caixa do XP (para listas grandes, como artistas). Devolve o índice escolhido.
Future<int?> showXpChoice(BuildContext context, {required String title, required List<(String, String?)> options, int? selected, XpIcons icon = XpIcons.list}) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => XpAlertDialog(
      title: Text(title),
      icon: icon,
      content: SizedBox(
        width: 320,
        height: (options.length * 40.0).clamp(80, 380),
        child: Bevel(
          sunken: true,
          child: ListView.builder(
            itemCount: options.length,
            itemExtent: 40,
            itemBuilder: (_, i) {
              final on = i == selected;
              return Material(
                color: on ? Xp.select : Colors.white,
                child: InkWell(
                  onTap: () => Navigator.pop(ctx, i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      Expanded(
                        child: Text(options[i].$1,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, color: on ? Colors.white : Colors.black)),
                      ),
                      if (options[i].$2 != null) Text(options[i].$2!, style: TextStyle(fontSize: 12.5, color: on ? Colors.white70 : const Color(0xFF777777))),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar'))],
    ),
  );
}

/// Coleção automática aberta: se atualiza sozinha quando a biblioteca ou o histórico mudam.
class SmartCollectionScreen extends StatelessWidget {
  final String id;
  final String title;
  const SmartCollectionScreen({super.key, required this.id, required this.title});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final current = context.select<PlayerService, int?>((p) => p.current?.id);
    return ValueListenableBuilder<int>(
      valueListenable: app.statsVersion,
      builder: (context, _, _) => FutureBuilder<PlayStats>(
        future: app.playStats(),
        initialData: app.playStatsNow,
        builder: (context, snap) {
          final cols = buildSmartCollections(app.tracks, snap.data ?? PlayStats.empty, current: app.byId(current));
          final c = cols.where((c) => c.id == id).firstOrNull;
          return TrackListScreen(
            title: c?.title ?? title,
            tracks: c?.tracks ?? const [],
            path: 'Música\\Coleções automáticas\\${c?.title ?? title}',
          );
        },
      ),
    );
  }
}
