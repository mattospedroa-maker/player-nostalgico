import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../download_service.dart';
import '../theme.dart';
import '../xp_icons.dart';

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
            if (!showQueue) XpTabs(labels: const ['Um vídeo', 'Playlist'], current: _tab, onTap: (i) => setState(() => _tab = i)),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: showQueue ? 8 : 0),
                child: XpTabPage(
                  padding: EdgeInsets.zero,
                  child: showQueue ? _queueView(ds) : (_tab == 0 ? _singleView(ds) : _playlistView(ds)),
                ),
              ),
            ),
            const SizedBox(height: 6),
            XpStatusBar(showQueue
                ? ['${ds.doneCount} prontas · ${ds.queue.length - ds.doneCount} na fila', 'MP3 192 kbps']
                : [_tab == 0 ? 'Cole o link de um vídeo' : 'Cole o link de uma playlist', 'MP3 192 kbps']),
          ]),
        ),
      ),
    );
  }

  // ---------- caixas e campos ----------

  Widget _box({required List<Widget> children}) => Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _label(String s) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)));

  Widget _linkField(TextEditingController c, String hint, {required bool playlist}) => TextField(
        controller: c,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(playlist: playlist),
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          suffixIconConstraints: const BoxConstraints(minHeight: 30),
          suffixIcon: Padding(
            padding: const EdgeInsets.all(4),
            child: XpButton(label: 'Colar', icon: Icons.content_paste, onTap: () => _paste(c, playlist: playlist)),
          ),
        ),
      );

  Widget _nameField(String label, TextEditingController c, void Function(String) onChanged) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          SizedBox(width: 56, child: Text('$label:', style: const TextStyle(fontSize: 14))),
          Expanded(
            child: TextField(
              controller: c,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ]),
      );

  Widget _error(String msg) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(msg, style: const TextStyle(color: Xp.red)),
      );

  Widget _bigButton(String label, IconData icon, VoidCallback? onTap, {bool primary = true, Widget? extra}) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (extra != null) ...[extra, const SizedBox(width: 7)],
          XpButton(label: label, icon: icon, primary: primary, onTap: onTap),
        ]),
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
        if (ds.loadingSingle) const Padding(padding: EdgeInsets.only(top: 10), child: XpProgress(height: 14)),
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
          if (e.existingPath != null) _alreadyHave(e.existingPath!),
        ],
      ]),
      if (e != null)
        _bigButton(e.existingPath != null ? 'Baixar mesmo assim' : 'Baixar MP3', Icons.download, () async {
          if (!await _ready()) return;
          ds.enqueue([e]);
        }, primary: e.existingPath == null),
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

  Widget _alreadyHave(String path) {
    final root = context.read<AppState>().sourceRoot;
    final rel = root == null ? path : p.relative(path, from: root);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFFFFFFE1), border: Border.all(color: Colors.black)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const XpIcon(XpIcons.warning, size: 24),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(TextSpan(children: [
            const TextSpan(text: 'Você já tem esta música\n', style: TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: rel.replaceAll(p.separator, '\\')),
          ]), style: const TextStyle(color: Colors.black, fontSize: 13)),
        ),
      ]),
    );
  }

  Widget _haveBadge() => Container(
        margin: const EdgeInsets.only(top: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFFFFFFE1), border: Border.all(color: const Color(0xFFB8A76A))),
        child: const Text('✔ Já está na Biblioteca', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF8A6200))),
      );

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
            if (ds.loadingPlaylist) const Padding(padding: EdgeInsets.only(top: 10), child: XpProgress(height: 14)),
            if (ds.playlistError != null) _error(ds.playlistError!),
            if (items.isEmpty && !ds.loadingPlaylist)
              Padding(padding: const EdgeInsets.only(top: 8), child: XpButtonRow(onTap: () => _search(playlist: true))),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(text: '"${ds.playlistTitle}" · ${items.length} vídeos', children: [
                      if (ds.playlistExistingCount > 0)
                        TextSpan(
                          text: ' · ${ds.playlistExistingCount} já ${ds.playlistExistingCount == 1 ? 'está' : 'estão'} na Biblioteca',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF8A6200)),
                        ),
                    ]),
                    style: const TextStyle(fontSize: 13, color: Xp.blueText),
                  ),
                ),
                TextButton(
                  onPressed: () => ds.selectAll(selected.length != items.where((e) => !e.unavailable).length),
                  child: Text(selected.length == items.where((e) => !e.unavailable).length ? 'Desmarcar todos' : 'Marcar todos'),
                ),
              ]),
              for (final e in items) _playlistRow(ds, e),
              if (ds.playlistExistingCount > 0)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('Quer baixar uma repetida mesmo assim? É só marcar de novo.', style: TextStyle(fontSize: 12, color: Xp.blueMuted)),
                ),
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
                  Text(e.names.title,
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: e.existingPath != null && !e.selected ? const Color(0xFF7A869C) : Xp.navy, fontSize: 15)),
                  Text('${e.names.artist} · ${e.lookingUp ? 'procurando álbum…' : e.names.album}',
                      style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
                  if (e.existingPath != null) _haveBadge(),
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
      builder: (ctx) => XpAlertDialog(
        icon: XpIcons.edit,
        title: const Text('Corrigir nome'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _old(e.originalTitle),
          const SizedBox(height: 8),
          TextField(controller: a, decoration: const InputDecoration(labelText: 'Artista')),
          const SizedBox(height: 8),
          TextField(controller: t, decoration: const InputDecoration(labelText: 'Título')),
          const SizedBox(height: 8),
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
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          const XpIcon(XpIcons.youtube, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(ds.running ? 'Baixando $current de $total' : 'Terminado', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
              const SizedBox(height: 5),
              XpProgress(value: total == 0 ? 0 : done / total),
            ]),
          ),
        ]),
      ),
      const XpColumnHeader('Nome', right: 'Situação'),
      Expanded(
        child: ListView(padding: EdgeInsets.zero, children: [
          for (final e in q) _queueRow(e),
          if (ds.lastSummary != null)
            Container(
              margin: const EdgeInsets.all(10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFFFFFE1), border: Border.all(color: Colors.black)),
              child: Row(children: [
                const XpIcon(XpIcons.check, size: 22),
                const SizedBox(width: 8),
                Expanded(child: Text(ds.lastSummary!, style: const TextStyle(fontSize: 13.5))),
              ]),
            ),
        ]),
      ),
      if (ds.running)
        _bigButton('Cancelar', Icons.close, ds.cancelAll, primary: true, extra: XpButton(label: 'Ocultar', onTap: () => Navigator.pop(context)))
      else
        _bigButton('Baixar mais', Icons.add, () {
          ds.queue.clear();
          setState(() {});
        }),
    ]);
  }

  Widget _queueRow(YtEntry e) {
    final active = e.status == YtStatus.downloading || e.status == YtStatus.converting;
    final (text, color) = switch (e.status) {
      YtStatus.queued => ('Na fila', const Color(0xFF888888)),
      YtStatus.downloading => ('Baixando… ${(e.progress * 100).round()}%', Colors.white),
      YtStatus.converting => ('Convertendo para MP3…', Colors.white),
      YtStatus.done => ('Pronto · MP3${e.sizeBytes == null ? '' : ', ${(e.sizeBytes! / 1048576).toStringAsFixed(1).replaceAll('.', ',')} MB'}', const Color(0xFF1D7A2A)),
      YtStatus.failed => ('✖ ${e.error ?? 'Erro'}', Xp.red),
      YtStatus.canceled => ('Cancelado', const Color(0xFF888888)),
      YtStatus.ready => ('', const Color(0xFF888888)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
      decoration: BoxDecoration(color: active ? Xp.select : null, border: const Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(e.names.title, style: TextStyle(fontWeight: FontWeight.bold, color: active ? Colors.white : Colors.black, fontSize: 14.5)),
        Text('${e.names.artist} · ${e.names.album}', style: TextStyle(fontSize: 12, color: active ? const Color(0xFFDFE8FF) : const Color(0xFF666666))),
        const SizedBox(height: 3),
        Row(children: [
          if (e.status == YtStatus.done) ...[const XpIcon(XpIcons.note, size: 14), const SizedBox(width: 4)],
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
        ]),
        if (active)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: XpProgress(value: e.status == YtStatus.converting ? null : e.progress, height: 14),
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
