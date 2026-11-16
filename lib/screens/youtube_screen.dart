import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../download_service.dart';
import '../theme.dart';

/// "Baixar do YouTube (MP3)": aba de um vídeo e aba de playlist.
class YoutubeScreen extends StatefulWidget {
  const YoutubeScreen({super.key});

  @override
  State<YoutubeScreen> createState() => _YoutubeScreenState();
}

class _YoutubeScreenState extends State<YoutubeScreen> {
  int _tab = 0;
  final _videoLink = TextEditingController();
  final _playlistLink = TextEditingController();
  final _artist = TextEditingController();
  final _title = TextEditingController();
  final _album = TextEditingController();
  YtEntry? _filled;
  Object? _filledNames;

  @override
  void initState() {
    super.initState();
    context.read<DownloadService>().warmUp();
  }

  @override
  void dispose() {
    for (final c in [_videoLink, _playlistLink, _artist, _title, _album]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _paste(TextEditingController c, {required bool playlist}) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    c.text = DownloadService.normalizeUrl(text);
    if (!mounted) return;
    _search(playlist: playlist);
  }

  void _search({required bool playlist}) {
    final ds = context.read<DownloadService>();
    FocusScope.of(context).unfocus();
    if (playlist) {
      ds.fetchPlaylist(_playlistLink.text);
    } else {
      _filled = null;
      ds.fetchSingle(_videoLink.text);
    }
  }

  Future<bool> _ready() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    if (app.sourceRoot == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Escolha primeiro a pasta de músicas na Biblioteca.')));
      return false;
    }
    if (!await app.ensureStoragePermission()) {
      messenger.showSnackBar(const SnackBar(content: Text('Sem permissão de acesso aos arquivos, não consigo salvar as músicas.')));
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.watch<DownloadService>();
    final showQueue = ds.queue.isNotEmpty;
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: 'Baixar do YouTube', actions: [
              XpTitleButton(icon: Icons.close, tooltip: 'Fechar (continua baixando)', onTap: () => Navigator.pop(context)),
            ]),
            _tabs(),
            Expanded(child: showQueue ? _queueView(ds) : (_tab == 0 ? _singleView(ds) : _playlistView(ds))),
          ]),
        ),
      ),
    );
  }

  Widget _tabs() => Container(
        margin: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        decoration: BoxDecoration(border: Border.all(color: Xp.blue, width: 1.5), borderRadius: BorderRadius.circular(5)),
        clipBehavior: Clip.antiAlias,
        child: Row(children: [
          for (final (i, label) in [(0, 'Um vídeo'), (1, 'Playlist')])
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _tab = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: i == _tab ? const [Color(0xFF5BA3F5), Color(0xFF1C5FD8)] : const [Colors.white, Color(0xFFDCE6F7)],
                    ),
                  ),
                  child: Text(label,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: i == _tab ? Colors.white : Xp.navy)),
                ),
              ),
            ),
        ]),
      );

  // ---------- caixas e campos ----------

  Widget _box({required List<Widget> children}) => Container(
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFE5DCA0), width: 2),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _label(String s) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy)));

  Widget _linkField(TextEditingController c, String hint, {required bool playlist}) => TextField(
        controller: c,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(playlist: playlist),
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: const Color(0xFFF7FAFF),
          hintText: hint,
          border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF7F9DB9))),
          suffixIcon: TextButton.icon(
            onPressed: () => _paste(c, playlist: playlist),
            icon: const Icon(Icons.content_paste, size: 16),
            label: const Text('Colar'),
          ),
        ),
      );

  Widget _nameField(String label, TextEditingController c, void Function(String) onChanged) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          SizedBox(width: 56, child: Text(label, style: const TextStyle(color: Xp.blueMuted))),
          Expanded(
            child: TextField(
              controller: c,
              onChanged: onChanged,
              style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF9FB3D9))),
              ),
            ),
          ),
        ]),
      );

  Widget _error(String msg) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(msg, style: const TextStyle(color: Xp.red)),
      );

  Widget _bigButton(String label, IconData icon, VoidCallback? onTap, {bool primary = true}) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Opacity(
          opacity: onTap == null ? .5 : 1,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(30),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: primary ? const Color(0xFF0A3A99) : const Color(0xFF8A9BB8)),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: primary ? const [Color(0xFF5B9BFF), Color(0xFF0F4FC4)] : const [Colors.white, Color(0xFFCFD6E2)],
                ),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: primary ? Colors.white : Xp.navy, size: 20),
                const SizedBox(width: 8),
                Text(label, style: TextStyle(color: primary ? Colors.white : Xp.navy, fontWeight: FontWeight.bold, fontSize: 16)),
              ]),
            ),
          ),
        ),
      );

  static String _dur(int? s) => s == null ? '' : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  Widget _old(String s) => Text(s,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: Color(0xFFAA3333), decoration: TextDecoration.lineThrough));

  // ---------- aba "Um vídeo" ----------

  Widget _singleView(DownloadService ds) {
    final e = ds.single;
    // preenche os campos (e de novo quando a busca de álbum termina), sem apagar o que o usuário digitou
    if (e != null && !e.edited && (!identical(e, _filled) || !identical(e.names, _filledNames))) {
      _artist.text = e.names.artist;
      _title.text = e.names.title;
      _album.text = e.names.album;
      _filled = e;
      _filledNames = e.names;
    }
    return ListView(padding: const EdgeInsets.only(bottom: 20), children: [
      _box(children: [
        _label('Link do vídeo'),
        _linkField(_videoLink, 'youtu.be/… ou youtube.com/watch?v=…', playlist: false),
        if (ds.loadingSingle) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator(minHeight: 3)),
        if (ds.singleError != null) _error(ds.singleError!),
        if (e == null && !ds.loadingSingle)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: XpButtonRow(onTap: () => _search(playlist: false)),
          ),
        if (e != null) ...[
          const SizedBox(height: 10),
          if (e.thumbnail != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(fit: StackFit.expand, children: [
                  Image.network(e.thumbnail!, fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: Xp.navyDeep)),
                  if (e.durationSec != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        color: Colors.black54,
                        child: Text(_dur(e.durationSec), style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ),
                ]),
              ),
            ),
          const SizedBox(height: 8),
          _old(e.originalTitle),
          const SizedBox(height: 6),
          Row(children: [
            _label('Nome corrigido'),
            const Spacer(),
            if (e.lookingUp) const Text('procurando álbum…', style: TextStyle(fontSize: 12, color: Xp.blueMuted)),
          ]),
          _nameField('Artista', _artist, (v) => ds.edit(e, artist: v.trim())),
          _nameField('Título', _title, (v) => ds.edit(e, title: v.trim())),
          _nameField('Álbum', _album, (v) => ds.edit(e, album: v.trim())),
          const SizedBox(height: 8),
          Text('Vai para: ${e.names.artist} / ${e.names.album} / ${e.names.title}.mp3',
              style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
        ],
      ]),
      if (e != null)
        _bigButton('Baixar MP3', Icons.download, () async {
          if (!await _ready()) return;
          ds.enqueue([e]);
        }),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Text(
          'Converte para .mp3 (192 kbps, a qualidade máxima que o YouTube entrega) com as tags e a capa gravadas no arquivo. '
          'Depois aparece na Biblioteca sozinha.',
          style: TextStyle(fontSize: 12, color: Xp.blueMuted),
        ),
      ),
    ]);
  }

  // ---------- aba "Playlist" ----------

  Widget _playlistView(DownloadService ds) {
    final items = ds.playlist;
    final selected = items.where((e) => e.selected).toList();
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.only(bottom: 10), children: [
          _box(children: [
            _label('Link da playlist'),
            _linkField(_playlistLink, 'youtube.com/playlist?list=…', playlist: true),
            if (ds.loadingPlaylist) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator(minHeight: 3)),
            if (ds.playlistError != null) _error(ds.playlistError!),
            if (items.isEmpty && !ds.loadingPlaylist)
              Padding(padding: const EdgeInsets.only(top: 8), child: XpButtonRow(onTap: () => _search(playlist: true))),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Text('"${ds.playlistTitle}" · ${items.length} vídeos',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Xp.blueText)),
                ),
                TextButton(
                  onPressed: () => ds.selectAll(selected.length != items.where((e) => !e.unavailable).length),
                  child: Text(selected.length == items.where((e) => !e.unavailable).length ? 'Desmarcar todos' : 'Marcar todos'),
                ),
              ]),
              for (final e in items) _playlistRow(ds, e),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: ds.makePlaylist,
                onChanged: (v) => ds.setMakePlaylist(v ?? false),
                title: Text('Criar playlist "${ds.playlistTitle}" no app', style: const TextStyle(fontSize: 13)),
              ),
            ],
          ]),
        ]),
      ),
      if (items.isNotEmpty)
        _bigButton('Baixar ${selected.length} ${selected.length == 1 ? 'selecionada' : 'selecionadas'}', Icons.download,
            selected.isEmpty
                ? null
                : () async {
                    if (!await _ready()) return;
                    ds.enqueue(selected, playlistName: ds.makePlaylist ? ds.playlistTitle : null);
                  }),
      const SizedBox(height: 8),
    ]);
  }

  Widget _playlistRow(DownloadService ds, YtEntry e) => InkWell(
        onTap: e.unavailable ? null : () => ds.toggle(e),
        onLongPress: e.unavailable ? null : () => _editDialog(ds, e),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Xp.listBorder))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Checkbox(value: e.selected, onChanged: e.unavailable ? null : (_) => ds.toggle(e), visualDensity: VisualDensity.compact),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _old(e.originalTitle),
                if (e.unavailable)
                  const Text('Indisponível', style: TextStyle(color: Xp.blueMuted))
                else ...[
                  Text(e.names.title, style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 15)),
                  Text('${e.names.artist} · ${e.lookingUp ? 'procurando álbum…' : e.names.album}',
                      style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
                ],
              ]),
            ),
            if (!e.unavailable)
              IconButton(
                tooltip: 'Corrigir nome',
                icon: const Icon(Icons.edit, size: 18, color: Xp.blue),
                onPressed: () => _editDialog(ds, e),
              ),
          ]),
        ),
      );

  Future<void> _editDialog(DownloadService ds, YtEntry e) async {
    final a = TextEditingController(text: e.names.artist);
    final t = TextEditingController(text: e.names.title);
    final al = TextEditingController(text: e.names.album);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Corrigir nome'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _old(e.originalTitle),
          TextField(controller: a, decoration: const InputDecoration(labelText: 'Artista')),
          TextField(controller: t, decoration: const InputDecoration(labelText: 'Título')),
          TextField(controller: al, decoration: const InputDecoration(labelText: 'Álbum')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok == true) {
      ds.edit(e, artist: a.text.trim(), title: t.text.trim(), album: al.text.trim());
      setState(() {});
    }
    a.dispose();
    t.dispose();
    al.dispose();
  }

  // ---------- baixando ----------

  Widget _queueView(DownloadService ds) {
    final q = ds.queue;
    final total = q.length;
    final done = ds.doneCount;
    final current = ds.running ? (done + 1).clamp(1, total) : done;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.only(bottom: 10), children: [
          _box(children: [
            _label(ds.running ? 'Baixando $current de $total' : 'Terminado'),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 10, color: Xp.blue, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 6),
            for (final e in q) _queueRow(e),
          ]),
          if (ds.lastSummary != null)
            Container(
              margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Xp.navy, borderRadius: BorderRadius.circular(6)),
              child: Text('✔ ${ds.lastSummary}', style: const TextStyle(color: Colors.white)),
            ),
        ]),
      ),
      if (ds.running)
        _bigButton('Cancelar', Icons.close, ds.cancelAll, primary: false)
      else
        _bigButton('Baixar mais', Icons.add, () {
          ds.queue.clear();
          setState(() {});
        }),
      const SizedBox(height: 8),
    ]);
  }

  Widget _queueRow(YtEntry e) {
    final (text, color) = switch (e.status) {
      YtStatus.queued => ('Na fila', Xp.blueMuted),
      YtStatus.downloading => ('Baixando… ${(e.progress * 100).round()}%', Xp.blueText),
      YtStatus.converting => ('Convertendo para MP3…', Xp.blueText),
      YtStatus.done => ('✔ Pronto (MP3${e.sizeBytes == null ? '' : ', ${(e.sizeBytes! / 1048576).toStringAsFixed(1).replaceAll('.', ',')} MB'})', const Color(0xFF2A7A2A)),
      YtStatus.failed => ('✖ ${e.error ?? 'Erro'}', Xp.red),
      YtStatus.canceled => ('Cancelado', Xp.blueMuted),
      YtStatus.ready => ('', Xp.blueMuted),
    };
    final active = e.status == YtStatus.downloading || e.status == YtStatus.converting;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Xp.listBorder))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(e.names.title, style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy, fontSize: 15)),
        Text('${e.names.artist} · ${e.names.album}', style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
        const SizedBox(height: 2),
        Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: e.status == YtStatus.done ? FontWeight.bold : FontWeight.normal)),
        if (active)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(
                value: e.status == YtStatus.converting ? null : e.progress, minHeight: 6, color: Xp.blue, backgroundColor: const Color(0xFFE3EAF6)),
          ),
      ]),
    );
  }
}

/// Botão "Buscar" debaixo do campo de link.
class XpButtonRow extends StatelessWidget {
  final VoidCallback onTap;
  const XpButtonRow({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: XpButton(label: 'Buscar', icon: Icons.search, onTap: onTap),
      );
}
