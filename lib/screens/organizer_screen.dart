import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../error_log.dart';
import '../organizer.dart';
import '../theme.dart';
import '../xp_icons.dart';

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
    } catch (e, st) {
      errorLog.fail('Organizador', 'A busca de músicas novas parou no meio', error: e, stack: st);
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
    } catch (e, st) {
      // o que não deu para devolver ao lugar: o banco passa a apontar para onde o arquivo está
      if (e is OrganizeException && e.stillMoved.isNotEmpty) await app.applyMoves(e.stillMoved);
      errorLog.fail('Organizador', 'Erro ao mover as músicas', error: e, stack: st);
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

  int get _stepNumber => switch (_step) { _Step.intro => 1, _Step.analyzing => 2, _ => 3 };

  void _close() {
    _cancel = true;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _step == _Step.moving;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        body: XpBackground(
          child: SafeArea(
            child: Column(children: [
              XpTitleBar(title: 'Assistente para buscar novas músicas', icon: XpIcons.find, actions: [
                if (!busy) XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: _close),
              ]),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // faixa azul do assistente, com a etapa
                  Container(
                    width: 96,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF5A7EDC), Color(0xFF3D5FC8), Color(0xFF1C3C9E)], stops: [0, .4, 1]),
                    ),
                    padding: const EdgeInsets.only(top: 28),
                    child: Column(children: [
                      XpIcon(_step == _Step.done ? XpIcons.check : XpIcons.find, size: 58),
                      const SizedBox(height: 10),
                      Text(_step == _Step.done ? 'Concluído' : 'Etapa $_stepNumber de 3', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                    ]),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: Colors.white,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (_error != null)
                          Container(
                            margin: const EdgeInsets.all(10),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: const Color(0xFFFFFFE1), border: Border.all(color: Colors.black)),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const XpIcon(XpIcons.warning, size: 22),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13))),
                            ]),
                          ),
                        Expanded(child: _body()),
                      ]),
                    ),
                  ),
                ]),
              ),
              _buttons(),
            ]),
          ),
        ),
      ),
    );
  }

  /// < Voltar · Avançar > · Cancelar, como nos assistentes do Windows.
  Widget _buttons() {
    final selected = _plan.where((i) => i.status == PlanStatus.move && i.selected).length;
    final (back, next, nextLabel, cancel, cancelLabel) = switch (_step) {
      _Step.intro => (null, _analyze, 'Avançar >', _close, 'Cancelar'),
      _Step.analyzing => (null, null, 'Avançar >', () => setState(() => _cancel = true), 'Parar'),
      _Step.review => (() => setState(() => _step = _Step.intro), selected == 0 ? null : _execute, 'Organizar $selected >', _close, 'Cancelar'),
      _Step.moving => (null, null, 'Avançar >', null, 'Cancelar'),
      _Step.done => (null, () => Navigator.pop(context), 'Concluir', null, 'Cancelar'),
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(color: Xp.beige, border: Border(top: BorderSide(color: Xp.beigeBorder))),
      child: Row(children: [
        if (_step == _Step.done) XpButton(label: 'Desfazer', icon: Icons.undo, onTap: _undo),
        const Spacer(),
        if (_step != _Step.done) ...[XpButton(label: '< Voltar', onTap: back), const SizedBox(width: 6)],
        XpButton(label: nextLabel, primary: true, onTap: next),
        if (_step != _Step.done) ...[const SizedBox(width: 6), XpButton(label: cancelLabel, onTap: cancel)],
      ]),
    );
  }

  Widget _body() {
    final app = context.watch<AppState>();
    const h3 = TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.black);
    const body = TextStyle(fontSize: 14, height: 1.45, color: Colors.black);
    switch (_step) {
      case _Step.intro:
        return ListView(padding: const EdgeInsets.all(14), children: [
          const Text('Bem-vindo ao Assistente para organizar músicas', style: h3),
          const SizedBox(height: 10),
          Text(
            'Este assistente lê cada música de "${p.basename(app.sourceRoot ?? '')}", descobre o artista e o álbum '
            '(pelas tags do arquivo ou pesquisando o título no MusicBrainz) e move para Artista\\Álbum dentro dessa pasta.\n\n'
            'Antes de mover qualquer arquivo, mostro a lista para você conferir. Precisa de internet só nesta etapa.',
            style: body,
          ),
          if (app.canUndoOrganize) ...[
            const SizedBox(height: 14),
            Align(alignment: Alignment.centerLeft, child: XpButton(label: 'Desfazer a última organização', icon: Icons.undo, onTap: _undo)),
          ],
          const SizedBox(height: 18),
          const Text('Para continuar, toque em Avançar.', style: TextStyle(fontSize: 13, color: Color(0xFF555555))),
        ]);
      case _Step.analyzing:
        return ListView(padding: const EdgeInsets.all(14), children: [
          const Text('Analisando as músicas', style: h3),
          const SizedBox(height: 14),
          XpProgress(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 8),
          Text('$_done de $_total', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          Text(_current, style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
          const SizedBox(height: 12),
          const Text('O MusicBrainz aceita uma pesquisa por segundo, então pode demorar um pouco.', style: TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
        ]);
      case _Step.review:
        return _review();
      case _Step.moving:
        return ListView(padding: const EdgeInsets.all(14), children: const [
          Text('Movendo os arquivos…', style: h3),
          SizedBox(height: 14),
          XpProgress(),
          SizedBox(height: 8),
          Text('Não feche o app até terminar.', style: TextStyle(fontSize: 13, color: Color(0xFF555555))),
        ]);
      case _Step.done:
        return ListView(padding: const EdgeInsets.all(14), children: [
          const Text('Concluindo o Assistente', style: h3),
          const SizedBox(height: 10),
          Text('${_moved.length} músicas foram organizadas.', style: body.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text('Favoritas, playlists e histórico foram mantidos.\n\nPara fechar o assistente, toque em Concluir.', style: body),
        ]);
    }
  }

  Widget _review() {
    final toMove = _plan.where((i) => i.status == PlanStatus.move).toList();
    final ok = _plan.where((i) => i.status == PlanStatus.alreadyOrganized).length;
    final problems = _plan.where((i) => i.status == PlanStatus.notFound || i.status == PlanStatus.error).toList();
    final root = context.read<AppState>().sourceRoot!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Text('${toMove.length} para mover · $ok já organizadas · ${problems.length} não identificadas',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
          child: Bevel(
            sunken: true,
            child: ListView(children: [
              if (toMove.isNotEmpty) const XpColumnHeader('Serão movidas'),
              for (final i in toMove)
                Material(
                  color: Colors.white,
                  child: CheckboxListTile(
                    dense: true,
                    value: i.selected,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    onChanged: (v) => setState(() => i.selected = v ?? false),
                    title: Text(p.basename(i.sourcePath), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '→ ${p.relative(i.targetPath!, from: root).replaceAll(p.separator, '\\')}\n'
                      '${i.info!.source == 'musicbrainz' ? 'MusicBrainz (${i.info!.score}%)' : i.info!.source}',
                      style: TextStyle(fontSize: 11.5, color: (i.info!.score < 85) ? Xp.red : const Color(0xFF666666)),
                    ),
                  ),
                ),
              if (problems.isNotEmpty) const XpColumnHeader('Não identificadas (ficam onde estão)'),
              for (final i in problems)
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text('${p.basename(i.sourcePath)}\n${i.message ?? ''}', style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
                ),
            ]),
          ),
        ),
      ),
    ]);
  }
}
