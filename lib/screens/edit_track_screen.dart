import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../organizer.dart';
import '../theme.dart';

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

  @override
  void initState() {
    super.initState();
    context.read<AppState>().gifs.gifsFor(widget.track).then((g) {
      if (mounted && g.isNotEmpty) setState(() => _gif = g.first);
    });
  }

  Future<void> _fromMusicBrainz() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final mb = MusicBrainzClient();
      final info = await mb.lookup(_title.text.trim(), artist: _artist.text.trim().isEmpty ? null : _artist.text.trim());
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
    } catch (_) {
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
      builder: (ctx) => AlertDialog(
        title: const Text('Apagar música?'),
        content: Text('"${widget.track.title}" será apagada do celular. Não dá para desfazer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apagar', style: TextStyle(color: Xp.red))),
        ],
      ),
    );
    if (ok != true) return;
    await app.deleteTrack(widget.track);
    nav.pop();
  }

  Widget _field(String label, TextEditingController c, {TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Xp.navy)),
          const SizedBox(height: 3),
          TextField(
            controller: c,
            keyboardType: type,
            decoration: const InputDecoration(isDense: true, filled: true, fillColor: Colors.white, border: OutlineInputBorder()),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final root = context.read<AppState>().sourceRoot;
    final rel = root == null ? widget.track.path : p.relative(widget.track.path, from: root);
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: 'Editar música', actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))]),
            Expanded(
              child: ListView(padding: const EdgeInsets.all(12), children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFF7A96C9)), borderRadius: BorderRadius.circular(6)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(color: Colors.black, border: Border.all(color: const Color(0xFF0B2F7A), width: 2)),
                        child: _gif == null ? const Icon(Icons.music_note, color: Colors.white54) : Image.file(File(_gif!), fit: BoxFit.cover),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Arquivo: $rel', style: const TextStyle(fontSize: 11, color: Xp.blueMuted))),
                    ]),
                    _field('Título', _title),
                    _field('Artista', _artist),
                    _field('Álbum', _album),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 3, child: _field('Gênero', _genre)),
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: _field('Ano', _year, type: TextInputType.number)),
                    ]),
                    const SizedBox(height: 10),
                    XpButton(label: _busy ? 'Aguarde...' : 'Preencher pelo MusicBrainz', icon: Icons.search, onTap: _busy ? null : _fromMusicBrainz),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _writeTags,
                      onChanged: (v) => setState(() => _writeTags = v ?? true),
                      title: const Text('Gravar também nas tags do arquivo', style: TextStyle(color: Xp.navy)),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _move,
                      onChanged: (v) => setState(() => _move = v ?? true),
                      title: const Text('Mover para a pasta Artista/Álbum nova', style: TextStyle(color: Xp.navy)),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  XpButton(label: 'Cancelar', onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 8),
                  XpButton(label: 'Salvar', primary: true, onTap: _busy ? null : _save),
                ]),
                const SizedBox(height: 14),
                TextButton.icon(
                  onPressed: _busy ? null : _delete,
                  icon: const Icon(Icons.delete_outline, color: Xp.red),
                  label: const Text('Apagar música do celular', style: TextStyle(color: Xp.red, fontWeight: FontWeight.bold)),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
