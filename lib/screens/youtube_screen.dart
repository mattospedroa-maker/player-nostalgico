import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../copy_animation.dart';
import '../download_service.dart';
import '../theme.dart';
import '../xp_icons.dart';

/// "Baixar do YouTube (MP3)" no jeito da janela "Copiando…" do Windows XP: um campo só
/// (reconhece vídeo ou playlist pelo link), as notinhas indo do globo para a pasta e a fila no modo Detalhes.
class YoutubeScreen extends StatefulWidget {
  /// Link que veio do menu "Compartilhar": já entra no campo certo (vídeo ou playlist) e busca.
  final String? sharedLink;
  const YoutubeScreen({super.key, this.sharedLink});

  @override
  State<YoutubeScreen> createState() => _YoutubeScreenState();
}

enum _Mode { none, single, playlist }

class _YoutubeScreenState extends State<YoutubeScreen> {
  _Mode _mode = _Mode.none;
  final _videoLink = TextEditingController();
  final _playlistLink = TextEditingController();
  final _artist = TextEditingController();
  final _title = TextEditingController();
  final _album = TextEditingController();
  YtEntry? _filled;
  Object? _filledNames;

  static const _rowLine = Color(0xFFEEEEEE);

  @override
  void initState() {
    super.initState();
    context.read<DownloadService>().warmUp();
    final shared = widget.sharedLink;
    if (shared != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openShared(shared));
  }

  /// Playlist vai para o campo Playlist; vídeo (ou vídeo aberto dentro de uma playlist) vai para o campo Vídeo,
  /// e nesse caso a playlist também fica no campo de baixo, a um "Buscar" de distância.
  void _openShared(String text) {
    if (!mounted) return;
    final url = DownloadService.normalizeUrl(text);
    if (url.isEmpty) return;
    final kind = DownloadService.linkKind(url);
    if (kind == LinkKind.playlist) {
      _playlistLink.text = url;
      _search(playlist: true);
    } else {
      _videoLink.text = url;
      if (kind == LinkKind.both) _playlistLink.text = url;
      _search(playlist: false);
    }
  }

  @override
  void dispose() {
    for (final c in [_videoLink, _playlistLink, _artist, _title, _album]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _paste({required bool playlist}) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    (playlist ? _playlistLink : _videoLink).text = DownloadService.normalizeUrl(text);
    if (!mounted) return;
    _search(playlist: playlist);
  }

  /// Cada campo busca o seu tipo. Um link só de playlist colado no campo de vídeo vai para o de playlist.
  void _search({required bool playlist}) {
    final ds = context.read<DownloadService>();
    final field = playlist ? _playlistLink : _videoLink;
    final url = DownloadService.normalizeUrl(field.text);
    FocusScope.of(context).unfocus();
    if (url.isEmpty) return;
    field.text = url;
    if (!playlist && DownloadService.linkKind(url) == LinkKind.playlist) {
      _videoLink.clear();
      _playlistLink.text = url;
      playlist = true;
    }
    setState(() => _mode = playlist ? _Mode.playlist : _Mode.single);
    if (playlist) {
      ds.fetchPlaylist(url);
    } else {
      _filled = null;
      ds.fetchSingle(url);
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
    final copying = ds.queue.isNotEmpty;
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            XpTitleBar(title: 'Baixar do YouTube', icon: XpIcons.youtube, actions: [
              XpTitleButton(icon: Icons.close, tooltip: 'Fechar (continua baixando)', onTap: () => Navigator.pop(context)),
            ]),
            if (!copying) _linkBar(ds),
            Expanded(
              child: copying
                  ? _queueView(ds)
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Bevel(
                        sunken: true,
                        color: Colors.white,
                        child: Material(
                          type: MaterialType.transparency,
                          child: switch (_mode) {
                            _Mode.single => _singleView(ds),
                            _Mode.playlist => _playlistView(ds),
                            _Mode.none => _idle(),
                          },
                        ),
                      ),
                    ),
            ),
            _actionBar(ds),
            XpStatusBar(_status(ds)),
          ]),
        ),
      ),
    );
  }

  List<String> _status(DownloadService ds) {
    final q = ds.queue;
    if (q.isNotEmpty) {
      return [ds.running ? 'Baixando ${(ds.doneCount + 1).clamp(1, q.length)} de ${q.length}' : '${ds.okCount} de ${q.length} baixadas', 'MP3 192 kbps'];
    }
    return switch (_mode) {
      _Mode.playlist when ds.playlist.isNotEmpty => ['Playlist · ${ds.playlist.length} vídeos', 'MP3 192 kbps'],
      _Mode.single when ds.single != null => ['Vídeo · ${_dur(ds.single!.durationSec)}', 'MP3 192 kbps'],
      _ => ['Cole o link de um vídeo ou playlist', 'MP3 192 kbps'],
    };
  }

  // ---------- campo do link e botões ----------

  Widget _linkBar(DownloadService ds) {
    final busy = ds.loadingSingle || ds.loadingPlaylist;
    Widget row(String label, TextEditingController c, String hint, {required bool playlist}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            SizedBox(width: 62, child: Text('$label:', style: const TextStyle(fontSize: 14))),
            Expanded(
              child: TextField(
                controller: c,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(playlist: playlist),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(hintText: hint),
              ),
            ),
            const SizedBox(width: 5),
            XpButton(label: 'Colar', onTap: () => _paste(playlist: playlist)),
            const SizedBox(width: 4),
            XpButton(label: 'Buscar', primary: true, onTap: busy ? null : () => _search(playlist: playlist)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: XpGroupBox(
        title: 'Links do YouTube',
        background: Xp.beige,
        child: Column(children: [
          row('Vídeo', _videoLink, 'youtu.be/…', playlist: false),
          row('Playlist', _playlistLink, '…playlist?list=…', playlist: true),
        ]),
      ),
    );
  }

  /// Barra de baixo do painel: o botão principal muda conforme a etapa.
  Widget _actionBar(DownloadService ds) {
    final List<Widget> buttons;
    if (ds.queue.isNotEmpty) {
      buttons = ds.running
          ? [
              XpButton(label: 'Ocultar', onTap: () => Navigator.pop(context)),
              XpButton(label: 'Cancelar', primary: true, onTap: ds.cancelAll),
            ]
          : [
              XpButton(
                  label: 'Baixar mais',
                  icon: Icons.add,
                  primary: true,
                  onTap: () {
                    ds.queue.clear();
                    _videoLink.clear();
                    _playlistLink.clear();
                    setState(() => _mode = _Mode.none);
                  }),
            ];
    } else if (_mode == _Mode.single && ds.single != null) {
      final e = ds.single!;
      buttons = [
        XpButton(
          label: e.existingPath != null ? 'Baixar mesmo assim' : (e.podcast ? 'Baixar episódio' : 'Baixar MP3'),
          icon: Icons.download,
          primary: e.existingPath == null,
          onTap: () async {
            if (!await _ready()) return;
            ds.enqueue([e]);
          },
        ),
      ];
    } else if (_mode == _Mode.playlist && ds.playlist.isNotEmpty) {
      final sel = ds.playlist.where((e) => e.selected).toList();
      buttons = [
        XpButton(
          label: ds.playlistIsPodcast
              ? 'Baixar ${sel.length} ${sel.length == 1 ? 'episódio' : 'episódios'}'
              : 'Baixar ${sel.length} ${sel.length == 1 ? 'música' : 'músicas'}',
          icon: Icons.download,
          primary: true,
          onTap: sel.isEmpty
              ? null
              : () async {
                  if (!await _ready()) return;
                  ds.enqueue(sel, playlistName: ds.makePlaylist && !ds.playlistIsPodcast ? ds.playlistTitle : null);
                },
        ),
      ];
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        for (var i = 0; i < buttons.length; i++) ...[if (i > 0) const SizedBox(width: 6), buttons[i]],
      ]),
    );
  }

  Widget _idle() => ListView(padding: const EdgeInsets.all(14), children: const [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          XpIcon(XpIcons.youtube, size: 40),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Cole o link de um vídeo no campo Vídeo, ou o de uma playlist no campo Playlist, e toque em Buscar.\n\n'
              'A música vira .mp3 (192 kbps, a qualidade máxima que o YouTube entrega), com as tags e a capa gravadas, '
              'e aparece na Biblioteca sozinha. O que você já tem é pulado.',
              style: TextStyle(fontSize: 13.5, height: 1.4),
            ),
          ),
        ]),
      ]);

  Widget _loading(String? error, bool loading) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (loading) ...[
            Text(context.read<DownloadService>().updatingYtDlp ? 'O YouTube mudou: atualizando o yt-dlp e tentando de novo…' : 'Lendo o link…',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 6),
            const XpProgress(height: 14),
          ],
          if (error != null) _error(error),
        ]),
      );

  // ---------- campos ----------

  Widget _label(String s) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)));

  Widget _nameField(String label, TextEditingController c, void Function(String) onChanged) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          SizedBox(width: 56, child: Text('$label:', style: const TextStyle(fontSize: 14))),
          Expanded(child: TextField(controller: c, onChanged: onChanged, style: const TextStyle(fontSize: 14))),
        ]),
      );

  Widget _error(String msg) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(msg, style: const TextStyle(color: Xp.red)),
      );

  static String _dur(int? s) => s == null ? '' : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  Widget _old(String s) => Text(s,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: Color(0xFFAA3333), decoration: TextDecoration.lineThrough));

  Widget _check(bool on, {VoidCallback? onTap}) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 16,
          height: 16,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: onTap == null ? const Color(0xFFE6E6E0) : Colors.white, border: Border.all(color: const Color(0xFF1C5180))),
          child: on ? const Icon(Icons.check, size: 14, color: Color(0xFF21A121)) : null,
        ),
      );

  // ---------- um vídeo ----------

  Widget _singleView(DownloadService ds) {
    final e = ds.single;
    if (e == null) return _loading(ds.singleError, ds.loadingSingle);
    // preenche os campos (e de novo quando a busca de álbum termina), sem apagar o que o usuário digitou
    if (!e.edited && (!identical(e, _filled) || !identical(e.names, _filledNames))) {
      _artist.text = e.names.artist;
      _title.text = e.names.title;
      _album.text = e.names.album;
      _filled = e;
      _filledNames = e.names;
    }
    return ListView(padding: const EdgeInsets.all(10), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 128,
          height: 72,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: Colors.black, border: Border.all(color: const Color(0xFF888888))),
          child: Stack(fit: StackFit.expand, children: [
            if (e.thumbnail != null) Image.network(e.thumbnail!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
            if (e.durationSec != null)
              Positioned(
                right: 2,
                bottom: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  color: Colors.black54,
                  child: Text(_dur(e.durationSec), style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Vídeo encontrado', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 3),
            _old(e.originalTitle),
          ]),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        _label('Nome corrigido'),
        const Spacer(),
        if (e.lookingUp) const Text('procurando álbum…', style: TextStyle(fontSize: 12, color: Xp.blueMuted)),
      ]),
      _kindSwitch(e.podcast, (v) => ds.setPodcast(e, v)),
      if (e.podcast) ...[
        _nameField('Programa', _artist, (v) => ds.edit(e, artist: v.trim(), album: v.trim())),
        _nameField('Episódio', _title, (v) => ds.edit(e, title: v.trim())),
        const SizedBox(height: 8),
        Text('Vai para: Podcasts\\${e.names.artist}\\${e.names.title}.mp3', style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
        const Text('Podcast nunca entra em Músicas, Tocar tudo nem na fila das músicas.', style: TextStyle(fontSize: 11.5, color: Xp.blueMuted)),
      ] else ...[
        _nameField('Artista', _artist, (v) => ds.edit(e, artist: v.trim())),
        _nameField('Título', _title, (v) => ds.edit(e, title: v.trim())),
        _nameField('Álbum', _album, (v) => ds.edit(e, album: v.trim())),
        const SizedBox(height: 8),
        Text('Vai para: ${e.names.artist}\\${e.names.album}\\${e.names.title}.mp3', style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
      ],
      if (e.existingPath != null) _alreadyHave(e.existingPath!),
    ]);
  }

  /// "Salvar como: (•) Música ( ) Podcast", com os botões de opção do XP.
  Widget _kindSwitch(bool podcast, void Function(bool) onChanged) {
    Widget opt(String label, bool value) {
      final on = podcast == value;
      return InkWell(
        onTap: () => onChanged(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: const Color(0xFF1C5180))),
              alignment: Alignment.center,
              child: on ? Container(width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF21A121))) : null,
            ),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.bold : FontWeight.normal)),
          ]),
        ),
      );
    }

    return Row(children: [
      const Text('Salvar como:', style: TextStyle(fontSize: 14)),
      const SizedBox(width: 6),
      opt('Música', false),
      const SizedBox(width: 10),
      opt('Podcast', true),
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
            const TextSpan(text: 'Você já tem isto na Biblioteca\n', style: TextStyle(fontWeight: FontWeight.bold)),
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

  // ---------- playlist ----------

  Widget _playlistView(DownloadService ds) {
    final items = ds.playlist;
    if (items.isEmpty) return _loading(ds.playlistError, ds.loadingPlaylist);
    final available = items.where((e) => !e.unavailable).length;
    final selected = items.where((e) => e.selected).length;
    final all = selected == available;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Text.rich(
          TextSpan(text: '"${ds.playlistTitle}" · ${items.length} vídeos', children: [
            if (ds.playlistExistingCount > 0)
              TextSpan(
                text: ' · ${ds.playlistExistingCount} já ${ds.playlistExistingCount == 1 ? 'está' : 'estão'} na Biblioteca (desmarcadas)',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF8A6200)),
              ),
          ]),
          style: const TextStyle(fontSize: 12.5, color: Xp.blueText),
        ),
      ),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: _kindSwitch(ds.playlistIsPodcast, ds.setPlaylistPodcast)),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: const BoxDecoration(color: Color(0xFFEBEADB), border: Border(bottom: BorderSide(color: Color(0xFFC7C5B2)))),
        child: Row(children: [
          _check(all, onTap: () => ds.selectAll(!all)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Título', style: TextStyle(fontSize: 12, color: Color(0xFF333333)))),
          const SizedBox(width: 40, child: Text('Dur.', style: TextStyle(fontSize: 12, color: Color(0xFF333333)))),
          const SizedBox(width: 30),
        ]),
      ),
      Expanded(
        child: ListView(padding: EdgeInsets.zero, children: [
          for (final e in items) _playlistRow(ds, e),
          if (!ds.playlistIsPodcast)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: ds.makePlaylist,
            onChanged: (v) => ds.setMakePlaylist(v ?? false),
            title: Text('Criar a playlist "${ds.playlistTitle}" no app', style: const TextStyle(fontSize: 13)),
          ),
        ]),
      ),
    ]);
  }

  Widget _playlistRow(DownloadService ds, YtEntry e) {
    final dim = e.unavailable || e.existingPath != null && !e.selected;
    return InkWell(
      onTap: e.unavailable ? null : () => ds.toggle(e),
      onLongPress: e.unavailable ? null : () => _editDialog(ds, e),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 0, 6),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _rowLine))),
        child: Row(children: [
          _check(e.selected, onTap: e.unavailable ? null : () => ds.toggle(e)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.unavailable ? e.originalTitle : '${e.names.title} · ${e.names.artist}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: dim ? const Color(0xFF8A93A6) : Colors.black)),
              Text(
                e.unavailable ? 'Indisponível' : (e.podcast ? 'Podcast · ${e.names.artist}' : (e.lookingUp ? 'procurando álbum…' : e.names.album)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Xp.blueMuted),
              ),
              if (e.existingPath != null) _haveBadge(),
            ]),
          ),
          SizedBox(width: 40, child: Text(_dur(e.durationSec), style: const TextStyle(fontSize: 12, color: Color(0xFF666666)))),
          SizedBox(
            width: 30,
            child: e.unavailable
                ? null
                : IconButton(
                    tooltip: 'Corrigir nome',
                    padding: EdgeInsets.zero,
                    icon: const XpIcon(XpIcons.edit, size: 18),
                    onPressed: () => _editDialog(ds, e),
                  ),
          ),
        ]),
      ),
    );
  }

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
          TextField(controller: a, decoration: InputDecoration(labelText: e.podcast ? 'Programa' : 'Artista')),
          const SizedBox(height: 8),
          TextField(controller: t, decoration: InputDecoration(labelText: e.podcast ? 'Episódio' : 'Título')),
          if (!e.podcast) ...[
            const SizedBox(height: 8),
            TextField(controller: al, decoration: const InputDecoration(labelText: 'Álbum')),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok == true) {
      ds.edit(e, artist: a.text.trim(), title: t.text.trim(), album: e.podcast ? a.text.trim() : al.text.trim());
      setState(() {});
    }
    a.dispose();
    t.dispose();
    al.dispose();
  }

  // ---------- baixando (janela "Copiando…") ----------

  Widget _queueView(DownloadService ds) {
    final q = ds.queue;
    final cur = q.where((e) => e.status == YtStatus.downloading || e.status == YtStatus.converting || e.status == YtStatus.updating).firstOrNull;
    final waiting = q.where((e) => e.status == YtStatus.queued).length;
    final root = context.read<AppState>().sourceRoot;
    final folder = root == null ? 'Música' : p.basename(root);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        decoration: BoxDecoration(color: Xp.beige, border: Border.all(color: Xp.beigeBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CopyAnimation(running: cur != null),
          const SizedBox(height: 6),
          if (cur != null) ...[
            Text('${cur.names.title}.mp3', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            Text("De 'youtube.com' para '$folder\\${cur.names.artist}'", maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            if (cur.status == YtStatus.updating) ...[
              // plano B: o YouTube mudou, o app atualiza o yt-dlp e tenta de novo sozinho
              const Text('O YouTube mudou e o yt-dlp ficou velho.', style: TextStyle(fontSize: 13)),
              const Text('Atualizando o yt-dlp e tentando de novo…', style: TextStyle(fontSize: 13, color: Color(0xFF1C3F94))),
              const SizedBox(height: 6),
              const XpProgress(value: null),
              if ((ds.versionBefore ?? '').isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Versão atual: ${ds.versionBefore}', style: const TextStyle(fontSize: 12, color: Color(0xFF555555))),
              ],
            ] else ...[
              const SizedBox(height: 6),
              XpProgress(value: cur.status == YtStatus.converting ? null : cur.progress),
              const SizedBox(height: 4),
              Text(
                cur.status == YtStatus.converting ? 'Convertendo para MP3…' : 'Baixando… ${(cur.progress * 100).round()}%',
                style: const TextStyle(fontSize: 13, color: Color(0xFF333333)),
              ),
            ],
          ] else ...[
            Text(ds.running ? 'Preparando…' : 'Pronto!', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 6),
            XpProgress(value: ds.running ? null : 1),
          ],
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Text('Na fila ($waiting)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1C3F94))),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Bevel(
            sunken: true,
            color: Colors.white,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _queueRow(YtEntry e) {
    final active = e.status == YtStatus.downloading || e.status == YtStatus.converting || e.status == YtStatus.updating;
    final (text, color) = switch (e.status) {
      YtStatus.queued => ('Aguardando', const Color(0xFF777777)),
      YtStatus.downloading => ('Baixando ${(e.progress * 100).round()}%', Colors.white),
      YtStatus.converting => ('Convertendo', Colors.white),
      YtStatus.updating => ('Atualizando yt-dlp', Colors.white),
      YtStatus.done => ('Concluído', const Color(0xFF1D7A2A)),
      YtStatus.failed => (e.error ?? 'Erro', Xp.red),
      YtStatus.canceled => ('Cancelado', const Color(0xFF888888)),
      YtStatus.ready => ('', const Color(0xFF888888)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
      decoration: BoxDecoration(color: active ? Xp.select : null, border: const Border(bottom: BorderSide(color: _rowLine))),
      child: Row(children: [
        XpIcon(
          switch (e.status) {
            YtStatus.done => XpIcons.check,
            YtStatus.failed => XpIcons.warning,
            _ => XpIcons.note,
          },
          size: 22,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.names.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: active ? Colors.white : Colors.black)),
            Text(e.names.artist,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: active ? const Color(0xFFDFE8FF) : const Color(0xFF666666))),
          ]),
        ),
        SizedBox(width: 104, child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color))),
      ]),
    );
  }
}
