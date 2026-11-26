import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../error_log.dart';
import '../artist_names.dart';
import '../models.dart';
import '../mood.dart';
import '../organizer.dart';
import '../style_learning.dart';
import '../styles.dart';
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';
import 'now_playing_screen.dart' show showGifManager;

/// "Editar música": título, artista, álbum, gênero e ano; grava nas tags, move de pasta ou apaga.
class EditTrackScreen extends StatefulWidget {
  final Track track;

  /// Aba que abre primeiro (0 Geral, 1 Estilo, 2 Arquivo, 3 GIFs).
  final int initialTab;
  const EditTrackScreen({super.key, required this.track, this.initialTab = 0});

  @override
  State<EditTrackScreen> createState() => _EditTrackScreenState();
}

class _EditTrackScreenState extends State<EditTrackScreen> {
  late final _title = TextEditingController(text: widget.track.title);
  late final _artist = TextEditingController(text: widget.track.artist == unknownArtist ? '' : widget.track.artist);
  late final _album = TextEditingController(text: widget.track.album == unknownAlbum ? '' : widget.track.album);
  late final _genre = TextEditingController(text: widget.track.genre);
  late final _year = TextEditingController(text: widget.track.year?.toString() ?? '');
  bool _writeTags = true;
  bool _move = true;
  bool _busy = false;
  String? _gif;
  List<String> _gifs = const [];
  late int _tab = widget.initialTab;

  @override
  void dispose() {
    for (final c in [_title, _artist, _album, _genre, _year]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    context.read<AppState>().gifs.gifsFor(widget.track).then((g) {
      if (mounted) {
        setState(() {
          _gifs = g;
          _gif = g.firstOrNull;
        });
      }
    });
  }

  String? _artistHintBefore;

  Future<void> _fromMusicBrainz() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final mb = MusicBrainzClient();
      final folder = folderArtistHint(widget.track.path);
      final info = await mb.lookupSmart(_title.text.trim(),
          artist: _artist.text.trim().isEmpty ? null : _artist.text.trim(), moreHints: [?folder]);
      if (info == null) {
        messenger.showSnackBar(const SnackBar(content: Text('O MusicBrainz não achou esta música. Confira o título e o artista.')));
      } else {
        _artistHintBefore = [_artist.text.trim(), folder ?? ''].firstWhere((h) => h.isNotEmpty && h != unknownArtist, orElse: () => '');
        if (_artistHintBefore!.isEmpty) _artistHintBefore = null;
        _title.text = info.title;
        _artist.text = info.artist;
        _album.text = info.album;
        final genre = await mb.artistGenre(info.artist);
        if (genre != null && _genre.text.trim().isEmpty) _genre.text = genre;
        final hint = _artistHintBefore;
        messenger.showSnackBar(SnackBar(
            content: Text(info.score <= 60 && hint != null
                ? 'O MusicBrainz só achou outro artista (${info.artist}), não $hint. Confira antes de salvar.'
                : 'Preenchido pelo MusicBrainz (${info.score}% de certeza). Confira e salve.')));
      }
    } catch (e) {
      errorLog.info('Editar música', 'MusicBrainz não respondeu', e);
      messenger.showSnackBar(const SnackBar(content: Text('Sem resposta do MusicBrainz. Confira a internet.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fecha só esta janela, e só se ela ainda estiver aberta. Antes, tocar duas vezes em OK
  /// (ou voltar enquanto salvava) fechava também a tela de baixo e o "Tocando agora" sumia.
  void _close(NavigatorState nav) {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      nav.pop();
    } else {
      nav.removeRoute(route);
    }
  }

  Future<void> _save() async {
    if (_busy) return; // já está salvando (dois toques em OK)
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final title = _title.text.trim();
    if (title.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('O título não pode ficar vazio.')));
      return;
    }
    setState(() => _busy = true);
    final String? warning;
    try {
      warning = await app.editTrack(
        widget.track,
        title: title,
        artist: _artist.text.trim().isEmpty ? unknownArtist : _artist.text.trim(),
        album: _album.text.trim().isEmpty ? unknownAlbum : _album.text.trim(),
        genre: _genre.text.trim(),
        year: int.tryParse(_year.text.trim()),
        writeTags: _writeTags,
        move: _move,
      );
    } catch (e) {
      errorLog.warn('Editar música', 'Não deu para salvar "${widget.track.title}"', error: e, balloon: true);
      if (mounted) setState(() => _busy = false);
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(warning ?? 'Música atualizada.')));
    if (!mounted) return;
    _close(nav);
  }

  Future<void> _delete() async {
    if (_busy) return;
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => XpAlertDialog(
        icon: XpIcons.warning,
        title: const Text('Apagar música?'),
        content: Text('"${widget.track.title}" será apagada do celular. Não dá para desfazer.'),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final deleted = await app.deleteTrack(widget.track);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!deleted) return; // o balão já explicou o motivo
    _close(nav);
  }

  Widget _field(String label, TextEditingController c, {TextInputType? type, double labelWidth = 62}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          SizedBox(width: labelWidth, child: Text('$label:', style: const TextStyle(fontSize: 14))),
          Expanded(child: TextField(controller: c, keyboardType: type, style: const TextStyle(fontSize: 14))),
        ]),
      );

  Widget _info(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 78, child: Text('$k:', style: const TextStyle(fontSize: 14))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 14))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final root = context.read<AppState>().sourceRoot;
    final rel = root == null ? widget.track.path : p.relative(widget.track.path, from: root);
    final name = p.basename(widget.track.path);
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            XpTitleBar(title: 'Propriedades de $name', icon: XpIcons.doc, actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))]),
            XpTabs(labels: const ['Geral', 'Estilo', 'Arquivo', 'GIFs'], current: _tab, onTap: (i) => setState(() => _tab = i)),
            Expanded(
              child: XpTabPage(
                padding: EdgeInsets.zero,
                child: ListView(padding: const EdgeInsets.all(10), children: switch (_tab) {
                  0 => _general(name, rel),
                  1 => _styleTab(),
                  2 => _file(name, rel),
                  _ => _gifTab(),
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                XpButton(label: 'OK', primary: true, onTap: _busy ? null : _save),
                const SizedBox(width: 7),
                XpButton(label: 'Cancelar', onTap: () => Navigator.pop(context)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _general(String name, String rel) => [
        Container(
          padding: const EdgeInsets.only(bottom: 9),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8)))),
          child: Row(children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: Colors.black, border: Border.all(color: const Color(0xFF888888))),
              child: _gif != null
                  ? Image.file(File(_gif!), fit: BoxFit.cover, errorBuilder: (_, _, _) => CoverSquare(widget.track, size: 58))
                  : Padding(padding: const EdgeInsets.all(2), child: CoverSquare(widget.track, size: 58)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                Text(p.dirname(rel).replaceAll(p.separator, '\\'), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Color(0xFF666666))),
              ]),
            ),
          ]),
        ),
        _field('Título', _title),
        _field('Artista', _artist),
        _field('Álbum', _album),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            const SizedBox(width: 62, child: Text('Gênero:', style: TextStyle(fontSize: 14))),
            Expanded(child: TextField(controller: _genre, style: const TextStyle(fontSize: 14))),
            const SizedBox(width: 8),
            const Text('Ano:', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            SizedBox(width: 64, child: TextField(controller: _year, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 14))),
          ]),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: XpButton(label: _busy ? 'Aguarde...' : 'Preencher pelo MusicBrainz', xpIcon: XpIcons.find, onTap: _busy ? null : _fromMusicBrainz),
        ),
        const SizedBox(height: 6),
        XpGroupBox(
          title: 'Ao salvar',
          child: Column(children: [
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _writeTags,
              onChanged: (v) => setState(() => _writeTags = v ?? true),
              title: const Text('Gravar também nas tags do arquivo', style: TextStyle(fontSize: 14)),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _move,
              onChanged: (v) => setState(() => _move = v ?? true),
              title: const Text('Mover para a pasta Artista\\Álbum nova', style: TextStyle(fontSize: 14)),
            ),
          ]),
        ),
      ];

  // ---------- aba "Estilo" ----------

  /// Réguas enquanto o dedo arrasta (salva ao soltar).
  double? _dragEnergy, _dragHumor;

  Future<void> _editStyles(Track t, {String? add, String? remove}) async {
    final e = StyleEdits.parse(t.stylesEdit);
    final added = {...e.added}, removed = {...e.removed};
    if (add != null) {
      added.add(add);
      removed.remove(add);
    }
    if (remove != null) {
      if (!added.remove(remove)) removed.add(remove);
    }
    await context.read<AppState>().setStyleEdits(t, StyleEdits(added, removed));
    if (mounted) setState(() {});
  }

  Future<void> _pickStyle(Track t) async {
    final have = Styles.of(t).toSet();
    final options = [for (final s in styleCatalog) if (!have.contains(s.name)) s.name]..sort();
    var filter = '';
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final shown = [for (final o in options) if (o.toLowerCase().contains(filter.toLowerCase())) o];
          return XpAlertDialog(
            icon: XpIcons.note,
            title: const Text('Adicionar estilo'),
            content: SizedBox(
              width: 300,
              height: 360,
              child: Column(children: [
                TextField(
                  decoration: const InputDecoration(hintText: 'Procurar estilo…', isDense: true),
                  onChanged: (v) => setD(() => filter = v),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: ListView(children: [
                    for (final o in shown)
                      ListTile(dense: true, title: Text(o, style: const TextStyle(fontSize: 14)), onTap: () => Navigator.pop(ctx, o)),
                  ]),
                ),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar'))],
          );
        },
      ),
    );
    if (chosen != null && mounted) await _editStyles(t, add: chosen);
  }

  Widget _chip(String text, {VoidCallback? onRemove, VoidCallback? onTap, bool dashed = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(right: 5, bottom: 5),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: dashed ? Colors.white : const Color(0xFFE4ECFB),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: dashed ? const Color(0xFF999999) : const Color(0xFFB9CBEE)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(text, style: TextStyle(fontSize: 13, color: dashed ? const Color(0xFF555555) : const Color(0xFF1C3F8A))),
            if (onRemove != null) ...[
              const SizedBox(width: 4),
              GestureDetector(onTap: onRemove, child: const Icon(Icons.close, size: 14, color: Color(0xFF7A8BB0))),
            ],
          ]),
        ),
      );

  Widget _ruler(String left, String title, String right, double value, List<Color> colors, ValueChanged<double> onChanged,
          ValueChanged<double> onEnd) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 6),
        Row(children: [
          Text(left, style: const TextStyle(fontSize: 12.5)),
          Expanded(child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold))),
          Text(right, style: const TextStyle(fontSize: 12.5)),
        ]),
        SizedBox(
          height: 30,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              height: 10,
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFF8A99B5)),
                gradient: LinearGradient(colors: colors),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 0,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                thumbColor: const Color(0xFFD9DCE2),
                overlayColor: const Color(0x221C5FD8),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10, elevation: 2),
              ),
              child: Slider(value: value, min: 0, max: 100, onChanged: onChanged, onChangeEnd: onEnd),
            ),
          ]),
        ),
      ]);

  List<Widget> _styleTab() {
    final app = context.watch<AppState>();
    final t = app.byId(widget.track.id) ?? widget.track;
    final styles = Styles.of(t);
    final vibe = Styles.vibeOf(t);
    final mood = t.effectiveMood;
    final learn = StyleLearning.current;
    final names = ArtistNames.current;
    final artistKey = names.key(t.artist);
    final displayArtist = <String, String>{for (final x in app.tracks) names.key(x.artist): names.main(x.artist)};
    final together = [
      for (final (k, n) in learn.artistCompanions(artistKey).take(4))
        if (k != artistKey && displayArtist[k] != null) (displayArtist[k]!, n)
    ];
    final added = <Track>[
      for (final e in learn.addedFromSuggestions.entries)
        if (e.key != t.id && t.id != null && learn.together(t.id!, e.key) > 0) ?app.byId(e.key)
    ].take(4).toList();
    final neighbors = Styles.neighborsOf(styles).take(5).toList();
    void saveVibe() {
      final e = (_dragEnergy ?? vibe.energy.toDouble()).round(), h = (_dragHumor ?? vibe.humor.toDouble()).round();
      _dragEnergy = _dragHumor = null;
      app.setVibe(t, e, h);
    }

    return [
      Container(
        padding: const EdgeInsets.only(bottom: 9),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8)))),
        child: Row(children: [
          CoverSquare(t, size: 52),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
              Text('${t.artist} · ${t.album}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Color(0xFF666666))),
            ]),
          ),
        ]),
      ),
      XpGroupBox(
        title: 'Estilos',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(children: [
            for (final s in styles) _chip(s, onRemove: () => _editStyles(t, remove: s)),
            if (styles.length < Styles.maxPerTrack) _chip('＋ estilo', dashed: true, onTap: () => _pickStyle(t)),
          ]),
          Text(
            styles.isEmpty
                ? 'Ainda sem estilos: chegam sozinhos com as tags do Last.fm. Você também pode pôr à mão.'
                : 'Automáticos pelas tags do Last.fm e do gênero. Os que você tira não voltam.',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF666666)),
          ),
        ]),
      ),
      XpGroupBox(
        title: 'Clima',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('Selo: ', style: TextStyle(fontSize: 13)),
            _chip(mood == null
                ? 'neutro · automático'
                : '${mood.emoji} ${mood.label} · ${t.chosenMood != null ? 'escolhido' : (vibe.manual ? 'pelas réguas' : 'automático')}'),
          ]),
          _ruler('🌙 Calma', 'Energia', 'Agitada 🔥', _dragEnergy ?? vibe.energy.toDouble(),
              const [Color(0xFF9CC3FF), Color(0xFFFFD17A), Color(0xFFFF7A5A)], (v) => setState(() => _dragEnergy = v), (_) => saveVibe()),
          _ruler('🌧 Sombrio', 'Humor', 'Alegre ☀️', _dragHumor ?? vibe.humor.toDouble(),
              const [Color(0xFF5A5A8A), Color(0xFFBFC6D6), Color(0xFFFFE36A)], (v) => setState(() => _dragHumor = v), (_) => saveVibe()),
          Text(
            vibe.manual
                ? 'Ajustado à mão.${t.chosenMood == null ? ' O selo segue as réguas.' : ' O selo escolhido continua valendo.'}'
                : 'Automático pelos estilos, tags${t.bpm != null ? ' e BPM (${t.bpm})' : ''}. Arraste para corrigir.',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF666666)),
          ),
          if (vibe.manual)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: XpButton(label: '↺ Automático', onTap: () => app.setVibe(t, null, null)),
              ),
            ),
        ]),
      ),
      XpGroupBox(
        title: 'Combina com',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (neighbors.isNotEmpty) _because('🧭', 'Estilos vizinhos', neighbors.join(', ')),
          if (together.isNotEmpty)
            _because('📋', 'Junto nas suas playlists', [for (final (a, n) in together) '$a ($n)'].join(', ')),
          if (added.isNotEmpty) _because('👍', 'Você adicionou pelas sugestões', [for (final x in added) '${x.artist} – ${x.title}'].join(', ')),
          if (neighbors.isEmpty && together.isEmpty && added.isEmpty)
            const Text('Ainda não há o que mostrar. Coloque a música em playlists para o app aprender.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF666666))),
        ]),
      ),
    ];
  }

  Widget _because(String icon, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text.rich(TextSpan(style: const TextStyle(fontSize: 13, height: 1.35), children: [
          TextSpan(text: '$icon $label: '),
          TextSpan(text: value, style: const TextStyle(color: Xp.linkBlue)),
        ])),
      );

  List<Widget> _file(String name, String rel) {
    final f = File(widget.track.path);
    final size = f.existsSync() ? f.lengthSync() : 0;
    final d = Duration(milliseconds: widget.track.durationMs);
    return [
      Row(children: [
        const XpIcon(XpIcons.doc, size: 40),
        const SizedBox(width: 10),
        Expanded(child: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold))),
      ]),
      const Divider(height: 18, color: Color(0xFFD4D0C8)),
      _info('Tipo', 'Arquivo ${p.extension(name).replaceFirst('.', '').toUpperCase()}'),
      _info('Local', p.dirname(rel).replaceAll(p.separator, '\\')),
      _info('Tamanho', '${(size / 1048576).toStringAsFixed(1).replaceAll('.', ',')} MB'),
      _info('Duração', fmtDuration(d)),
      const Divider(height: 18, color: Color(0xFFD4D0C8)),
      Align(
        alignment: Alignment.centerLeft,
        child: XpButton(label: 'Apagar música do celular…', xpIcon: XpIcons.bin, onTap: _busy ? null : _delete),
      ),
    ];
  }

  List<Widget> _gifTab() => [
        Text(_gifs.isEmpty ? 'Esta música ainda não tem GIFs.' : '${_gifs.length} GIFs nesta música', style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final g in _gifs)
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFB8C4D8))),
                child: Image.file(File(g), fit: BoxFit.cover, cacheWidth: 240, errorBuilder: (_, _, _) => const SizedBox()),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: XpButton(
            label: 'Gerenciar GIFs…',
            xpIcon: XpIcons.film,
            onTap: () async {
              await showGifManager(context, widget.track);
              if (!mounted) return;
              final g = await context.read<AppState>().gifs.gifsFor(widget.track);
              if (mounted) setState(() => _gifs = g);
            },
          ),
        ),
      ];
}
