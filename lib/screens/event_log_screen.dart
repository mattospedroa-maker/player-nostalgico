import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../error_log.dart';
import '../theme.dart';
import '../xp_icons.dart';

/// Hora do evento: hoje = "21:31", ontem = "ontem 21:31", antes = "16/11".
String eventTime(DateTime t, [DateTime? now]) {
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(n.year, n.month, n.day);
  if (day == today) return hm;
  if (day == DateTime(n.year, n.month, n.day - 1)) return 'ontem $hm';
  return '${two(t.day)}/${two(t.month)}';
}

/// Registro de erros no estilo do Visualizador de eventos do Windows XP:
/// ⓧ erro, ⚠ aviso, ⓘ informação. Tocar numa linha mostra o caminho e o motivo técnico.
class EventLogScreen extends StatefulWidget {
  final LogEntry? select;
  final ErrorLog? log;
  const EventLogScreen({super.key, this.select, this.log});

  @override
  State<EventLogScreen> createState() => _EventLogScreenState();
}

class _EventLogScreenState extends State<EventLogScreen> {
  late final ErrorLog _log = widget.log ?? errorLog;
  LogLevel? _filter;
  late LogEntry? _selected = widget.select;

  @override
  void initState() {
    super.initState();
    // abriu o registro: o ⚠ da bandeja some
    WidgetsBinding.instance.addPostFrameCallback((_) => _log.markSeen());
  }

  static XpIcons iconFor(LogLevel l) => switch (l) {
        LogLevel.info => XpIcons.info,
        LogLevel.warning => XpIcons.warning,
        LogLevel.error => XpIcons.error,
      };

  Future<void> _copy(List<LogEntry> list) async {
    final messenger = ScaffoldMessenger.of(context);
    final sel = _selected;
    await Clipboard.setData(ClipboardData(text: ErrorLog.asText(sel != null && list.contains(sel) ? [sel] : list)));
    messenger.showSnackBar(SnackBar(content: Text(sel != null ? 'Evento copiado.' : '${list.length} eventos copiados.')));
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => XpAlertDialog(
        icon: XpIcons.question,
        title: const Text('Limpar registro'),
        content: const Text('Apagar todos os eventos do registro de erros?'),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Limpar')),
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
        ],
      ),
    );
    if (ok != true) return;
    _log.clear();
    setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: XpBackground(
          child: SafeArea(
            child: ListenableBuilder(
              listenable: _log,
              builder: (context, _) {
                final list = [for (final e in _log.entries) if (_filter == null || e.level == _filter) e];
                final sel = _selected != null && list.contains(_selected) ? _selected : null;
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  XpTitleBar(title: 'Visualizador de eventos', icon: XpIcons.list, actions: [
                    XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
                  ]),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                    child: Row(children: [
                      for (final (level, label) in const [(null, 'Todos'), (LogLevel.error, 'Erros'), (LogLevel.warning, 'Avisos'), (LogLevel.info, 'Info')])
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: _FilterButton(
                            label: label,
                            icon: level == null ? null : iconFor(level),
                            on: _filter == level,
                            onTap: () => setState(() => _filter = level),
                          ),
                        ),
                      const Spacer(),
                      Text('${list.length} ${list.length == 1 ? 'evento' : 'eventos'}', style: const TextStyle(fontSize: 12.5, color: Xp.blueText)),
                    ]),
                  ),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFF7F9DB9))),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const _Header(),
                        Expanded(
                          child: list.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Text(_log.entries.isEmpty ? 'Nenhum evento registrado. 🎉' : 'Nada deste tipo.',
                                        textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: Xp.navy)),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: list.length,
                                  itemBuilder: (_, i) => _Row(
                                    entry: list[i],
                                    selected: identical(list[i], sel),
                                    onTap: () => setState(() => _selected = identical(list[i], sel) ? null : list[i]),
                                  ),
                                ),
                        ),
                      ]),
                    ),
                  ),
                  if (sel != null) _Details(sel),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
                    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      XpButton(label: 'Copiar', onTap: list.isEmpty ? null : () => _copy(list)),
                      const SizedBox(width: 6),
                      XpButton(label: 'Limpar', onTap: _log.entries.isEmpty ? null : _clear),
                      const SizedBox(width: 6),
                      XpButton(label: 'Fechar', primary: true, onTap: () => Navigator.pop(context)),
                    ]),
                  ),
                ]);
              },
            ),
          ),
        ),
      );
}

class _FilterButton extends StatelessWidget {
  final String label;
  final XpIcons? icon;
  final bool on;
  final VoidCallback onTap;
  const _FilterButton({required this.label, required this.icon, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFE3E1D4) : null,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: on ? const Color(0xFF8C8A7E) : Colors.transparent),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[XpIcon(icon!, size: 14), const SizedBox(width: 4)],
            Text(label, style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.bold : FontWeight.normal)),
          ]),
        ),
      );
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    Widget cell(String t, {double? width}) {
      final c = Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: const BoxDecoration(
          color: Color(0xFFEBEADB),
          border: Border(right: BorderSide(color: Color(0xFFC7C5B2)), bottom: BorderSide(color: Color(0xFFD6D4C3), width: 3)),
        ),
        child: Text(t, maxLines: 1, style: const TextStyle(fontSize: 12.5)),
      );
      return width == null ? Expanded(child: c) : c;
    }

    return Row(children: [cell('', width: 30), cell('Quando', width: 82), cell('Origem / Descrição')]);
  }
}

class _Row extends StatelessWidget {
  final LogEntry entry;
  final bool selected;
  final VoidCallback onTap;
  const _Row({required this.entry, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : Colors.black;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? Xp.select : null,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 30, child: Center(child: XpIcon(_EventLogScreenState.iconFor(entry.level), size: 16))),
          SizedBox(
            width: 82,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(eventTime(entry.time), style: TextStyle(fontSize: 12.5, color: fg)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 6, right: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${entry.source}${entry.count > 1 ? ' · ${entry.count}×' : ''}',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: fg)),
                Text(entry.message, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: fg)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  final LogEntry e;
  const _Details(this.e);

  @override
  Widget build(BuildContext context) {
    final t = e.time;
    String two(int v) => v.toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 8, 6, 0),
      constraints: const BoxConstraints(maxHeight: 170),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFF7F9DB9))),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: SelectableText.rich(
          TextSpan(style: const TextStyle(fontSize: 12.5, height: 1.45, color: Colors.black), children: [
            const TextSpan(text: 'Detalhes\n', style: TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)} · ${ErrorLog.levelName(e.level)} · ${e.source}\n'),
            TextSpan(text: e.message),
            if (e.count > 1) TextSpan(text: ' (${e.count} vezes)'),
            if (e.reason != null) TextSpan(text: '\nMotivo: ${e.reason}'),
            if (e.detail != null) TextSpan(text: '\n${e.detail}', style: const TextStyle(fontSize: 11.5, color: Color(0xFF555555))),
          ]),
        ),
      ),
    );
  }
}
