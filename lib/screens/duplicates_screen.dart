import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../duplicates.dart';
import '../models.dart';
import '../theme.dart';

/// "Músicas repetidas": escolhe a cópia que fica e apaga as outras.
class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  List<List<Track>> _groups = const [];

  /// grupo (pela 1ª cópia) -> id da cópia que fica
  final Map<int, int> _keep = {};
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _groups = findDuplicateGroups(context.read<AppState>().tracks);
    _keep
      ..clear()
      ..addAll({for (var i = 0; i < _groups.length; i++) i: _groups[i].first.id!});
  }

  int get _extra => _groups.fold(0, (a, g) => a + g.length - 1);

  int get _extraBytes {
    var b = 0;
    for (var i = 0; i < _groups.length; i++) {
      for (final t in _groups[i]) {
        if (t.id == _keep[i]) continue;
        try {
          b += File(t.path).lengthSync();
        } catch (_) {}
      }
    }
    return b;
  }

  Future<void> _clean() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar cópias repetidas?'),
        content: Text('Vou apagar $_extra ${_extra == 1 ? 'arquivo' : 'arquivos'} do celular. '
            'Favoritas, playlists e histórico passam para a cópia que fica. Não dá para desfazer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar')),
        ],
      ),
    );
    if (ok != true) return;
    if (!await app.ensureStoragePermission()) {
      messenger.showSnackBar(const SnackBar(content: Text('Sem permissão de acesso aos arquivos.')));
      return;
    }
    setState(() => _working = true);
    final plan = <Track, List<Track>>{};
    for (var i = 0; i < _groups.length; i++) {
      final keep = _groups[i].firstWhere((t) => t.id == _keep[i]);
      plan[keep] = _groups[i].where((t) => t.id != keep.id).toList();
    }
    final n = await app.removeDuplicates(plan);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('$n ${n == 1 ? 'cópia apagada' : 'cópias apagadas'}.')));
    setState(() {
      _working = false;
      _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final root = context.read<AppState>().sourceRoot;
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: 'Músicas repetidas', actions: [
              if (!_working) XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
            ]),
            if (_working) const LinearProgressIndicator(minHeight: 3),
            Expanded(
              child: _groups.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Nenhuma música repetida. 🎉', style: TextStyle(fontSize: 16, color: Xp.navy)),
                      ),
                    )
                  : ListView(padding: const EdgeInsets.only(bottom: 12), children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                        child: Text(
                          '${_groups.length} ${_groups.length == 1 ? 'música com cópias' : 'músicas com cópias'} · '
                          '$_extra ${_extra == 1 ? 'arquivo sobrando' : 'arquivos sobrando'} '
                          '(${(_extraBytes / 1048576).toStringAsFixed(0)} MB)',
                          style: const TextStyle(color: Xp.blueText, fontSize: 13),
                        ),
                      ),
                      for (var i = 0; i < _groups.length; i++) _group(i, root),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(14, 4, 14, 0),
                        child: Text(
                          '"[Live]", "Remix" e "Acoustic" contam como versões diferentes e não entram aqui. '
                          'Favoritas e playlists passam para a cópia que fica.',
                          style: TextStyle(fontSize: 12, color: Xp.blueMuted),
                        ),
                      ),
                    ]),
            ),
            if (_groups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                child: SizedBox(
                  width: double.infinity,
                  child: XpButton(
                    label: 'Apagar $_extra ${_extra == 1 ? 'cópia' : 'cópias'}',
                    icon: Icons.delete_outline,
                    primary: true,
                    onTap: _working ? null : _clean,
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _group(int i, String? root) {
    final g = _groups[i];
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFF9FB3D9), width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF4F6FA), Color(0xFFC8CED9)]),
          ),
          child: Text('${g.first.title} · ${g.first.artist}',
              overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy)),
        ),
        for (final t in g)
          InkWell(
            onTap: _working ? null : () => setState(() => _keep[i] = t.id!),
            child: Container(
              padding: const EdgeInsets.fromLTRB(4, 2, 10, 2),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: Xp.listBorder))),
              child: Row(children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(t.id == _keep[i] ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: Xp.blue, size: 22),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      '${t.album}${_kbps(t)}${t.favorite ? ' · ♥' : ''}',
                      style: const TextStyle(fontSize: 13, color: Xp.blueText),
                    ),
                    Text(root == null ? p.basename(t.path) : p.relative(t.path, from: root),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Xp.blueMuted)),
                  ]),
                ),
                Text(t.id == _keep[i] ? 'Fica' : 'Apagar',
                    style: TextStyle(fontWeight: FontWeight.bold, color: t.id == _keep[i] ? const Color(0xFF2A7A2A) : Xp.red)),
              ]),
            ),
          ),
      ]),
    );
  }

  static String _kbps(Track t) {
    final k = estimatedKbps(t);
    return k <= 0 ? '' : ' · $k kbps';
  }
}
