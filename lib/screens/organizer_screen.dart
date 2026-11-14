import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../organizer.dart';
import '../theme.dart';

/// "Buscar novas músicas": identifica artista/álbum e organiza em Fonte/Artista/Álbum.
class OrganizerScreen extends StatefulWidget {
  const OrganizerScreen({super.key});

  @override
  State<OrganizerScreen> createState() => _OrganizerScreenState();
}

enum _Step { intro, analyzing, review, moving, done }

class _OrganizerScreenState extends State<OrganizerScreen> {
  _Step _step = _Step.intro;
  int _done = 0, _total = 0;
  String _current = '';
  bool _cancel = false;
  List<PlanItem> _plan = const [];
  List<MoveRecord> _moved = const [];
  String? _error;

  Future<void> _analyze() async {
    final app = context.read<AppState>();
    if (!await app.ensureStoragePermission()) {
      setState(() => _error = 'Sem permissão para acessar os arquivos.');
      return;
    }
    setState(() {
      _step = _Step.analyzing;
      _cancel = false;
      _error = null;
    });
    try {
      final plan = await app.organizer().buildPlan(
        cancelled: () => _cancel,
        onProgress: (d, t, c) {
          if (mounted) {
            setState(() {
              _done = d;
              _total = t;
              _current = c;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _step = _Step.review;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.intro;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _execute() async {
    final app = context.read<AppState>();
    setState(() => _step = _Step.moving);
    try {
      final moved = await app.organizer().execute(_plan, undoLogPath: app.undoLogPath);
      await app.applyMoves(moved);
      if (mounted) {
        setState(() {
          _moved = moved;
          _step = _Step.done;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.review;
          _error = 'Erro ao mover: $e';
        });
      }
    }
  }

  Future<void> _undo() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final undone = await Organizer.undo(app.undoLogPath, app.sourceRoot!);
    await app.applyMoves(undone, undo: true);
    messenger.showSnackBar(SnackBar(content: Text('${undone.length} músicas voltaram para onde estavam.')));
    if (mounted) setState(() => _step = _Step.intro);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step != _Step.moving,
      child: Scaffold(
        body: XpBackground(
          child: SafeArea(
            child: Column(children: [
              XpTitleBar(title: 'Buscar novas músicas', actions: [
                if (_step != _Step.moving)
                  XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () {
                    _cancel = true;
                    Navigator.pop(context);
                  }),
              ]),
              if (_error != null)
                Container(
                  width: double.infinity,
                  color: const Color(0xFFFFE6E0),
                  padding: const EdgeInsets.all(10),
                  child: Text(_error!, style: const TextStyle(color: Xp.red)),
                ),
              Expanded(child: _body()),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final app = context.watch<AppState>();
    switch (_step) {
      case _Step.intro:
        return ListView(padding: const EdgeInsets.all(18), children: [
          const Icon(Icons.travel_explore, size: 56, color: Xp.blue),
          const SizedBox(height: 12),
          const Text('Organizar a pasta de músicas',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Xp.navy)),
          const SizedBox(height: 10),
          Text(
            'Vou ler cada música de "${p.basename(app.sourceRoot ?? '')}", descobrir o artista e o álbum '
            '(pelas tags do arquivo ou pesquisando o título no MusicBrainz) e mover para '
            'Artista/Álbum/ dentro dessa pasta.\n\n'
            'Antes de mover qualquer coisa eu mostro a lista para você conferir. Precisa de internet só nesta etapa.',
            style: const TextStyle(color: Xp.blueText),
          ),
          const SizedBox(height: 20),
          XpButton(label: 'Analisar músicas', icon: Icons.search, primary: true, onTap: _analyze),
          if (app.canUndoOrganize) ...[
            const SizedBox(height: 10),
            XpButton(label: 'Desfazer a última organização', icon: Icons.undo, onTap: _undo),
          ],
        ]);
      case _Step.analyzing:
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total, color: Xp.navy, minHeight: 8),
            const SizedBox(height: 12),
            Text('Analisando $_done de $_total', style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy)),
            const SizedBox(height: 4),
            Text(_current, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
            const SizedBox(height: 8),
            const Text('O MusicBrainz aceita uma pesquisa por segundo, então pode demorar um pouco.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Xp.blueMuted)),
            const SizedBox(height: 20),
            XpButton(label: 'Parar', icon: Icons.stop, onTap: () => setState(() => _cancel = true)),
          ]),
        );
      case _Step.review:
        return _review();
      case _Step.moving:
        return const Center(child: CircularProgressIndicator());
      case _Step.done:
        return ListView(padding: const EdgeInsets.all(18), children: [
          const Icon(Icons.check_circle, size: 56, color: Xp.blue),
          const SizedBox(height: 10),
          Text('${_moved.length} músicas organizadas',
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Xp.navy)),
          const SizedBox(height: 6),
          const Text('Favoritas, playlists e histórico foram mantidos.', textAlign: TextAlign.center, style: TextStyle(color: Xp.blueText)),
          const SizedBox(height: 20),
          XpButton(label: 'Concluir', primary: true, onTap: () => Navigator.pop(context)),
          const SizedBox(height: 10),
          XpButton(label: 'Desfazer', icon: Icons.undo, onTap: _undo),
        ]);
    }
  }

  Widget _review() {
    final toMove = _plan.where((i) => i.status == PlanStatus.move).toList();
    final ok = _plan.where((i) => i.status == PlanStatus.alreadyOrganized).length;
    final problems = _plan.where((i) => i.status == PlanStatus.notFound || i.status == PlanStatus.error).toList();
    final selected = toMove.where((i) => i.selected).length;
    final root = context.read<AppState>().sourceRoot!;
    return Column(children: [
      Container(
        width: double.infinity,
        color: Xp.beige,
        padding: const EdgeInsets.all(10),
        child: Text('${toMove.length} para mover · $ok já organizadas · ${problems.length} não identificadas',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ),
      Expanded(
        child: ListView(children: [
          if (toMove.isNotEmpty) const _Header('Serão movidas'),
          for (final i in toMove)
            Material(
              color: Colors.white,
              child: CheckboxListTile(
                dense: true,
                value: i.selected,
                onChanged: (v) => setState(() => i.selected = v ?? false),
                title: Text(p.basename(i.sourcePath), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  '→ ${p.relative(p.dirname(i.targetPath!), from: root)}\n'
                  '${i.info!.source == 'musicbrainz' ? 'MusicBrainz (${i.info!.score}%)' : i.info!.source}',
                  style: TextStyle(fontSize: 11, color: (i.info!.score < 85) ? Xp.red : Xp.blueMuted),
                ),
              ),
            ),
          if (problems.isNotEmpty) const _Header('Não identificadas (ficam onde estão)'),
          for (final i in problems)
            Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('${p.basename(i.sourcePath)}\n${i.message ?? ''}', style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Expanded(child: XpButton(label: 'Voltar', onTap: () => setState(() => _step = _Step.intro))),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: XpButton(label: 'Organizar $selected músicas', icon: Icons.drive_file_move, primary: true, onTap: selected == 0 ? null : _execute),
          ),
        ]),
      ),
    ]);
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => SectionLabel(text);
}
