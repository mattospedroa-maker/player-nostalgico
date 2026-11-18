import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../error_log.dart';
import '../models.dart';
import '../organizer.dart';
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';
import 'now_playing_screen.dart' show showGifManager;

/// "Editar música": título, artista, álbum, gênero e ano; grava nas tags, move de pasta ou apaga.
class EditTrackScreen extends StatefulWidget {
  final Track track;
  const EditTrackScreen({super.key, required this.track});

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
  int _tab = 0;

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

  Future<void> _fromMusicBrainz() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final mb = MusicBrainzClient();
      final info = await mb.lookupSmart(_title.text.trim(), artist: _artist.text.trim().isEmpty ? null : _artist.text.trim());
      if (info == null) {
        messenger.showSnackBar(const SnackBar(content: Text('O MusicBrainz não achou esta música. Confira o título e o artista.')));
      } else {
        _title.text = info.title;
        _artist.text = info.artist;
        _album.text = info.album;
        final genre = await mb.artistGenre(info.artist);
        if (genre != null && _genre.text.trim().isEmpty) _genre.text = genre;
        messenger.showSnackBar(SnackBar(content: Text('Preenchido pelo MusicBrainz (${info.score}% de certeza). Confira e salve.')));
      }
    } catch (e) {
      errorLog.info('Editar música', 'MusicBrainz não respondeu', e);
      messenger.showSnackBar(const SnackBar(content: Text('Sem resposta do MusicBrainz. Confira a internet.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final app = context.read<AppState>();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final title = _title.text.trim();
    if (title.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('O título não pode ficar vazio.')));
      return;
    }
    setState(() => _busy = true);
    final warning = await app.editTrack(
      widget.track,
      title: title,
      artist: _artist.text.trim().isEmpty ? unknownArtist : _artist.text.trim(),
      album: _album.text.trim().isEmpty ? unknownAlbum : _album.text.trim(),
      genre: _genre.text.trim(),
      year: int.tryParse(_year.text.trim()),
      writeTags: _writeTags,
      move: _move,
    );
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(warning ?? 'Música atualizada.')));
    nav.pop();
  }

  Future<void> _delete() async {
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
    if (!await app.deleteTrack(widget.track)) return; // o balão já explicou o motivo
    nav.pop();
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
            XpTabs(labels: const ['Geral', 'Arquivo', 'GIFs'], current: _tab, onTap: (i) => setState(() => _tab = i)),
            Expanded(
              child: XpTabPage(
                padding: EdgeInsets.zero,
                child: ListView(padding: const EdgeInsets.all(10), children: switch (_tab) {
                  0 => _general(name, rel),
                  1 => _file(name, rel),
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
