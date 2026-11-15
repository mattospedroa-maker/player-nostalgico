import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gif_fetcher.dart';
import '../gif_providers.dart';
import '../lastfm.dart';
import '../models.dart';
import '../mood.dart';
import '../theme.dart';
import '../visual_search.dart';
import '../visual_tags.dart';

/// "GIFs pela vibe": tags do Last.fm -> termos visuais -> miniaturas do GIPHY agrupadas por clima.
/// Anime sempre primeiro; ⬇ baixa só aquele GIF para a música.
class GifVibeScreen extends StatefulWidget {
  final Track track;
  const GifVibeScreen({super.key, required this.track});

  @override
  State<GifVibeScreen> createState() => _GifVibeScreenState();
}

/// Um grupo (clima visual) com os termos dele e os resultados já carregados.
class _Group {
  final String name;
  final List<VisualQuery> terms;
  int termIndex = 0;
  TermPager? pager;
  final List<VisualResult> results = [];
  bool loading = false;
  _Group(this.name, this.terms);
  VisualQuery get term => terms[termIndex % terms.length];
}

class _GifVibeScreenState extends State<GifVibeScreen> {
  static const perPage = 6;
  static const groupsShown = 4;

  VisualPlan? _plan;
  TagResult? _tags;
  List<_Group> _groups = [];
  String? _filter; // null = todos
  int _groupStart = 0;
  String? _error;
  bool _loading = true;
  final Set<String> _downloaded = {};
  final Set<String> _downloading = {};

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    final tags = await app.gifFetcher.tagsFor(widget.track);
    final plan = await app.gifFetcher.visualPlanFor(widget.track);
    if (!mounted) return;
    setState(() {
      _tags = tags;
      _plan = plan;
      _groups = [for (final e in plan.byGroup.entries) _Group(e.key, e.value)];
      _groupStart = 0;
      _filter = null;
      _loading = false;
    });
    await _loadVisible(reset: true);
  }

  List<_Group> get _visible {
    if (_filter != null) return _groups.where((g) => g.name == _filter).toList();
    if (_groups.isEmpty) return const [];
    return [for (var k = 0; k < groupsShown && k < _groups.length; k++) _groups[(_groupStart + k) % _groups.length]];
  }

  /// Carrega a próxima página de cada grupo visível (um grupo por vez, para respeitar o limite do GIPHY).
  Future<void> _loadVisible({bool reset = false}) async {
    final giphy = context.read<AppState>().giphy;
    if (giphy.apiKey == null || giphy.apiKey!.isEmpty) {
      setState(() => _error = GiphyError.noKey.name);
      return;
    }
    setState(() => _error = null);
    for (final g in _visible) {
      if (!mounted) return;
      if (reset) {
        g.results.clear();
        g.pager = null;
      }
      if (g.loading) continue;
      setState(() => g.loading = true);
      try {
        // termo acabou: passa para o próximo do grupo
        for (var tries = 0; tries < g.terms.length; tries++) {
          g.pager ??= TermPager(giphy, g.term);
          final page = await g.pager!.next(count: perPage);
          g.results.addAll(page.where((r) => !g.results.any((x) => x.gif.id == r.gif.id)));
          if (page.isNotEmpty || !g.pager!.done) break;
          g.termIndex++;
          g.pager = null;
        }
      } on GiphyException catch (e) {
        if (mounted) setState(() => _error = e.error.name);
        if (e.error == GiphyError.noKey || e.error == GiphyError.invalidKey) {
          if (mounted) setState(() => g.loading = false);
          return;
        }
      } finally {
        if (mounted) setState(() => g.loading = false);
      }
    }
  }

  /// "Outros termos": cada grupo passa para o próximo termo do dicionário; sem filtro, mostra outros grupos também.
  Future<void> _otherTerms() async {
    for (final g in _visible) {
      g.termIndex++;
    }
    if (_filter == null && _groups.length > groupsShown) _groupStart = (_groupStart + groupsShown) % _groups.length;
    await _loadVisible(reset: true);
  }

  Future<void> _download(VisualResult r) async {
    final id = r.gif.id;
    if (_downloaded.contains(id) || _downloading.contains(id)) return;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _downloading.add(id));
    try {
      final res = await http.get(Uri.parse(r.gif.url)).timeout(const Duration(seconds: 30));
      String? path;
      if (res.statusCode == 200 && res.bodyBytes.length <= 8 * 1024 * 1024) {
        final (artistDir, titleDir) = GifFetcher.dirsFor(widget.track);
        path = await app.gifs.saveForTrack(widget.track, res.bodyBytes,
            artistDir: artistDir, titleDir: titleDir, credit: 'GIPHY · ${r.gif.pageUrl.isEmpty ? r.gif.url : r.gif.pageUrl}');
      }
      if (path == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Não deu para salvar esse GIF.')));
      } else {
        setState(() => _downloaded.add(id));
        messenger.showSnackBar(const SnackBar(content: Text('GIF salvo na música. Ele já entra na roda do Tocando agora.')));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Falhou ao baixar. Confira a internet.')));
    } finally {
      if (mounted) setState(() => _downloading.remove(id));
    }
  }

  void _preview(VisualResult r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: const BorderSide(color: Xp.navy)),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          XpTitleBar(title: r.query),
          Container(
            margin: const EdgeInsets.all(8),
            height: 260,
            decoration: BoxDecoration(color: Colors.black, border: Border.all(color: Xp.navy, width: 2)),
            child: Image.network(r.gif.url, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Center(child: Text('Não carregou', style: TextStyle(color: Colors.white)))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(children: [
              Expanded(
                child: XpButton(
                  label: _downloaded.contains(r.gif.id) ? 'Já salvo' : 'Baixar para a música',
                  icon: Icons.download,
                  primary: true,
                  onTap: _downloaded.contains(r.gif.id)
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _download(r);
                        },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(child: XpButton(label: 'Fechar', onTap: () => Navigator.pop(ctx))),
            ]),
          ),
          const _Powered(),
        ]),
      ),
    );
  }

  Future<void> _keys() async {
    final changed = await showVibeKeysDialog(context, widget.track);
    if (changed && mounted) await _start();
  }

  String? get _errorText => switch (_error) {
        'noKey' => 'Falta a chave do GIPHY. Toque em ⚙ para colar.',
        'invalidKey' => 'A chave do GIPHY não funcionou. Confira em ⚙.',
        'network' => 'GIPHY fora do ar ou sem internet. Tente de novo daqui a pouco.',
        'badResponse' => 'O GIPHY respondeu algo estranho. Tente de novo.',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final tags = _tags;
    final plan = _plan;
    final visible = _visible;
    final nothing = !_loading && _error == null && visible.isNotEmpty && visible.every((g) => !g.loading && g.results.isEmpty);
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: 'GIFs pela vibe', actions: [
              XpTitleButton(icon: Icons.settings, tooltip: 'Chaves e fonte dos GIFs', onTap: _keys),
              XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
            ]),
            Expanded(
              child: _loading
                  ? const Center(child: Text('Lendo as tags da música...', style: TextStyle(color: Xp.blueText)))
                  : ListView(padding: const EdgeInsets.only(bottom: 10), children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                        child: Text('${t.title} · ${t.artist}', style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 14)),
                      ),
                      if (tags != null && tags.status == TagStatus.ok)
                        _info('Tags do Last.fm: ${tags.tags.take(6).map((x) => x.name).join(', ')}')
                      else if (tags != null)
                        _warn('${tags.status.message}: usando nome, artista e gênero da música.'),
                      if (plan != null && plan.clipScenes.isNotEmpty) _info('Do clipe (Wikipédia): ${plan.clipScenes.take(5).join(', ')}'),
                      if (t.chosenMood != null) _info('Clima escolhido: ${t.chosenMood!.emoji} ${t.chosenMood!.label} (vale mais que as tags)'),
                      if (_errorText != null) _warn(_errorText!),
                      if (_groups.length > 1)
                        SizedBox(
                          height: 36,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            children: [
                              _XpChip(label: 'Todos', on: _filter == null, onTap: () => _setFilter(null)),
                              for (final g in _groups) _XpChip(label: g.name, on: _filter == g.name, onTap: () => _setFilter(g.name)),
                            ],
                          ),
                        ),
                      for (final g in visible) ..._groupView(g),
                      if (nothing) _warn('Nada encontrado para estes termos. Toque em "Outros termos".'),
                      if (plan != null && plan.all.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
                          child: Row(children: [
                            Expanded(child: XpButton(label: 'Mais resultados', icon: Icons.add, primary: true, onTap: _loadVisible)),
                            const SizedBox(width: 6),
                            Expanded(child: XpButton(label: 'Outros termos', icon: Icons.refresh, onTap: _otherTerms)),
                          ]),
                        ),
                      const _Powered(),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }

  void _setFilter(String? f) {
    setState(() => _filter = f);
    if (_visible.any((g) => g.results.isEmpty)) _loadVisible();
  }

  Widget _info(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
        child: Text(s, style: const TextStyle(fontSize: 12, color: Xp.blueText)),
      );

  Widget _warn(String s) => Container(
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFFFFF3B0), border: Border.all(color: Xp.gold), borderRadius: BorderRadius.circular(4)),
        child: Text(s, style: const TextStyle(fontSize: 12, color: Color(0xFF5A4600))),
      );

  List<Widget> _groupView(_Group g) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(children: [
            Text(g.name, style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 13)),
            const Spacer(),
            Flexible(
              child: Text(g.loading ? 'buscando "${g.term.text}"...' : g.term.text,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Xp.blueMuted)),
            ),
          ]),
        ),
        if (g.results.isEmpty && !g.loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text('Nada por aqui ainda.', style: TextStyle(fontSize: 11, color: Xp.blueMuted)),
          ),
        if (g.results.isNotEmpty)
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            mainAxisSpacing: 5,
            crossAxisSpacing: 5,
            children: [for (final r in g.results) _cell(r)],
          ),
      ];

  Widget _cell(VisualResult r) {
    final done = _downloaded.contains(r.gif.id);
    final busy = _downloading.contains(r.gif.id);
    return GestureDetector(
      onTap: () => _preview(r),
      child: Container(
        decoration: BoxDecoration(color: Colors.black, border: Border.all(color: const Color(0xFF7A96C9))),
        child: Stack(fit: StackFit.expand, children: [
          Image.network(r.gif.previewUrl, fit: BoxFit.cover, cacheWidth: 200, errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26)),
          if (!r.anime)
            Positioned(
              left: 3,
              top: 3,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: const Text('geral', style: TextStyle(color: Colors.white, fontSize: 9)),
              ),
            ),
          Positioned(
            right: 3,
            bottom: 3,
            child: GestureDetector(
              onTap: () => _download(r),
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: done ? const Color(0xFF1D7A2A) : Xp.navy),
                  gradient: RadialGradient(
                    center: const Alignment(-.2, -.4),
                    colors: done ? const [Color(0xFFC9FFD0), Color(0xFF3BB54A)] : const [Colors.white, Color(0xFFC9D4E6)],
                  ),
                ),
                child: busy
                    ? const Padding(padding: EdgeInsets.all(5), child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(done ? Icons.check : Icons.download, size: 15, color: done ? Colors.white : Xp.navy),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Botão-pílula no estilo XP (azul quando selecionado).
class _XpChip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _XpChip({required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 5),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2B4F9E)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: on ? const [Xp.blueLight, Xp.blue] : const [Colors.white, Color(0xFFD7E2F5)],
              ),
            ),
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: on ? Colors.white : Xp.navy)),
          ),
        ),
      );
}

class _Powered extends StatelessWidget {
  const _Powered();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(4),
        child: Text('Powered by GIPHY', textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: Xp.blueMuted)),
      );
}

/// Janela ⚙: chaves do Last.fm e do GIPHY (ficam só no celular) e de onde vêm os GIFs do player.
/// Retorna true se algo mudou.
Future<bool> showVibeKeysDialog(BuildContext context, Track track) async {
  final app = context.read<AppState>();
  final lfm = TextEditingController(text: app.lastFmKey);
  final gph = TextEditingController(text: app.giphyKey);
  var source = app.gifSource;
  String? lfmStatus, gphStatus;
  var lfmOk = false, gphOk = false, testing = false, saved = false;
  final changed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
      Future<void> test() async {
        setSt(() => testing = true);
        final client = app.gifFetcher.client;
        if (lfm.text.trim().isEmpty) {
          lfmStatus = 'sem chave: GIFs pelo gênero';
          lfmOk = false;
        } else {
          final r = await LastFmClient(client, lfm.text).topTags(track.artist, track.title);
          lfmOk = r.status == TagStatus.ok || r.status == TagStatus.notFound || r.status == TagStatus.noTags;
          lfmStatus = lfmOk ? 'funcionando' : r.status.message;
        }
        if (gph.text.trim().isEmpty) {
          gphStatus = 'sem chave: só GIFs de anime';
          gphOk = false;
        } else {
          try {
            await GiphyProvider(client, gph.text).search('anime', limit: 1);
            gphOk = true;
            gphStatus = 'funcionando';
          } on GiphyException catch (e) {
            gphOk = false;
            gphStatus = e.message;
          }
        }
        await app.setLastFmKey(lfm.text);
        await app.setGiphyKey(gph.text);
        await app.setGifSource(source);
        saved = true;
        setSt(() => testing = false);
      }

      Widget status(String? s, bool ok) => s == null
          ? const SizedBox(height: 4)
          : Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text('${ok ? '✓' : '✗'} $s', style: TextStyle(fontSize: 11.5, color: ok ? const Color(0xFF1D7A2A) : Xp.red)),
            );

      InputDecoration deco(String hint) => InputDecoration(isDense: true, filled: true, fillColor: const Color(0xFFF7F9FD), border: const OutlineInputBorder(), hintText: hint);

      return Dialog(
        insetPadding: const EdgeInsets.all(18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: const BorderSide(color: Xp.navy)),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const XpTitleBar(title: 'Chaves e fonte dos GIFs'),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Last.fm (tags da música)', style: TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 13)),
                const SizedBox(height: 4),
                TextField(controller: lfm, obscureText: true, decoration: deco('cole a API key do Last.fm')),
                status(lfmStatus, lfmOk),
                const Text('GIPHY (miniaturas e GIFs gerais)', style: TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 13)),
                const SizedBox(height: 4),
                TextField(controller: gph, obscureText: true, decoration: deco('cole a API key do GIPHY')),
                status(gphStatus, gphOk),
                const SizedBox(height: 4),
                const Text('GIFs no Tocando agora', style: TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 13)),
                RadioGroup<GifSource>(
                  groupValue: source,
                  onChanged: (v) => setSt(() => source = v ?? source),
                  child: Column(children: [
                    for (final s in GifSource.values)
                      RadioListTile<GifSource>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: s,
                        title: Text(s.label, style: const TextStyle(fontSize: 13, color: Xp.navy)),
                        subtitle: Text(s.hint, style: const TextStyle(fontSize: 11, color: Xp.blueMuted)),
                      ),
                  ]),
                ),
                const Text('As chaves ficam só neste celular. Sem elas o app funciona normal: GIFs de anime pelo gênero e "Buscar na web".',
                    style: TextStyle(fontSize: 11, color: Xp.blueMuted)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Expanded(child: XpButton(label: testing ? 'Testando...' : 'Testar e salvar', primary: true, onTap: testing ? null : test)),
                const SizedBox(width: 6),
                Expanded(child: XpButton(label: saved ? 'Fechar' : 'Cancelar', onTap: () => Navigator.pop(ctx, saved))),
              ]),
            ),
          ]),
        ),
      );
    }),
  );
  return changed ?? false;
}
