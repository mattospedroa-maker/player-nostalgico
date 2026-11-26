import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../audiobooks.dart';
import '../book_text.dart' show EpubException;
import '../library_search.dart' show normalizeText;
import '../main.dart' show HomeShell;
import '../models.dart';
import '../player_service.dart';
import '../podcasts.dart' show formatClock, formatDuration;
import '../skip_notice.dart' show appMessengerKey;
import '../theme.dart';
import '../widgets.dart';
import '../xp_icons.dart';
import 'track_list_screen.dart' show GroupThumb, ThumbFrame;
import 'youtube_screen.dart';

/// Capa do livro: miniatura do vídeo do YouTube > capa embutida > primeira ilustração > quadro com o nome.
GroupThumb bookThumb(AppState app, Track t) {
  final color = colorFor(t.album);
  final f = app.programArt.episodeThumb(t.path) ?? app.covers.fileFor(t);
  if (f != null) return GroupThumb(file: f, color: color);
  final art = app.bookService.allArt(t.path);
  return GroupThumb(file: art.isEmpty ? null : art.first, color: color);
}

void _say(String text) => appMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));

/// Toca o livro: do capítulo escolhido, ou de onde parou. Vai para o Tocando agora.
Future<void> playBookAt(BuildContext context, Track book, {Duration? at}) async {
  context.read<AppState>().ensureBook(book);
  await context.read<PlayerService>().playBook(book, at: at);
  if (context.mounted) HomeShell.goTo(context, 0);
}

// ---------------------------------------------------------------------------
// Início dos audiolivros (dentro da Biblioteca, quando o Endereço está em "Audiolivros")

class AudiobooksHome extends StatelessWidget {
  final String query;
  const AudiobooksHome({super.key, this.query = ''});

  void _push(BuildContext context, Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListenableBuilder(listenable: Listenable.merge([app.bookService, app.programArt]), builder: (context, _) => _build(context, app));
  }

  Widget _build(BuildContext context, AppState app) {
    context.select<PlayerService, int?>((p) => p.current?.id);
    var books = app.audiobookList();
    final resume = app.podcastProgress.lastInProgress(app.audiobooks);
    if (query.isNotEmpty) {
      final words = normalizeText(query).split(' ');
      books = [for (final b in books) if (words.every(normalizeText('${b.title} ${b.author}').contains)) b];
    }
    final groups = groupByAuthor(books);
    return ListView(padding: EdgeInsets.zero, children: [
      if (query.isEmpty)
        XpTaskPane(title: 'Tarefas de audiolivro', tasks: [
          if (resume != null) (XpIcons.play, 'Continuar de onde parei', () => playBookAt(context, resume)),
          (XpIcons.youtube, 'Baixar audiolivro do YouTube', () => _push(context, const YoutubeScreen())),
        ]),
      if (resume != null && query.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Text(_whereStopped(app, resume), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Xp.blueText)),
        ),
      if (books.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            query.isNotEmpty
                ? 'Nenhum livro com esse nome ou autor.'
                : 'Nenhum audiolivro ainda.\n\nBaixe pelo "Baixar do YouTube" marcando "Audiolivro", ou coloque os arquivos na pasta Audiolivros/Nome do autor/ dentro da sua pasta de músicas.',
            style: const TextStyle(color: Xp.blueText, fontSize: 13.5),
          ),
        )
      else
        for (final (author, list) in groups) ...[
          XpColumnHeader(author, right: '${list.length} ${list.length == 1 ? 'livro' : 'livros'}'),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisExtent: 190),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final b = list[i];
              final done = app.podcastProgress.listened(b.track.path);
              final ch = b.chapters.length;
              return GestureDetector(
                onTap: () => _push(context, BookScreen(trackId: b.track.id!)),
                child: Column(children: [
                  ThumbFrame(thumb: bookThumb(app, b.track), size: 104, name: b.title, badge: done ? 'LIDO' : 'LIVRO', placeholderIcon: XpIcons.book),
                  const SizedBox(height: 4),
                  Text(b.title, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, height: 1.15)),
                  Text(
                    [if (ch > 0) '$ch cap.', if (b.track.durationMs > 0) formatDuration(Duration(milliseconds: b.track.durationMs))].join(' · '),
                    maxLines: 1,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
                  ),
                ]),
              );
            },
          ),
        ],
      const SizedBox(height: 12),
    ]);
  }
}

/// "Parou no cap. 7, O delírio (32%)".
String _whereStopped(AppState app, Track t) {
  final at = app.podcastProgress.resumeAt(t.path);
  if (at == null) return '';
  final info = app.bookService.infoFor(t.path);
  final pct = t.durationMs > 0 ? ' (${(at.inMilliseconds * 100 / t.durationMs).round()}%)' : '';
  final i = info?.chapterIndexAt(at) ?? -1;
  if (i >= 0) return 'Parou no cap. ${i + 1}, ${info!.chapters[i].title}$pct';
  return 'Parou em ${formatClock(at)} de "${t.album}"$pct';
}

// ---------------------------------------------------------------------------
// Um livro: capa, onde parou e uma faixa por capítulo (todos no mesmo arquivo)

class BookScreen extends StatelessWidget {
  final int trackId;
  const BookScreen({super.key, required this.trackId});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = app.byId(trackId);
    if (t == null) {
      return Scaffold(
        backgroundColor: Xp.beige,
        body: SafeArea(child: Column(children: [
          XpTitleBar(title: 'Audiolivro', icon: XpIcons.book, actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))]),
          const Expanded(child: EmptyHint(Icons.menu_book, 'Esse livro não está mais na pasta.')),
        ])),
      );
    }
    app.ensureBook(t);
    return ListenableBuilder(listenable: Listenable.merge([app.bookService, app.programArt]), builder: (context, _) => _build(context, app, t));
  }

  Widget _build(BuildContext context, AppState app, Track t) {
    final info = app.bookInfoOf(t);
    final book = Audiobook(t, info);
    final ps = context.watch<PlayerService>();
    final playingThis = ps.current?.id == t.id;
    final at = app.podcastProgress.resumeAt(t.path);
    final done = app.podcastProgress.listened(t.path);
    final pos = playingThis ? ps.player.position : (at ?? Duration.zero);
    final curIndex = info.chapters.isEmpty ? -1 : info.chapterIndexAt(pos);
    final textLine = switch (info.textStatus) {
      TextStatus.ok => '📄 Texto da obra: ${info.textSource}',
      TextStatus.none => '📄 Texto da obra: ainda não procurado',
      final s => '📄 ${s.label}',
    };
    return Scaffold(
      backgroundColor: Xp.beige,
      body: SafeArea(
        child: Column(children: [
          XpTitleBar(title: book.title, icon: XpIcons.book, actions: [
            XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
          ]),
          XpAddressBar('Audiolivros\\${book.author}', icon: XpIcons.book),
          GestureDetector(
            onLongPressStart: (d) => showBookMenu(context, t, d.globalPosition),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Xp.bgTop, Xp.bgBottom]),
                border: Border(bottom: BorderSide(color: Color(0xFF9FB3D6))),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ThumbFrame(thumb: bookThumb(app, t), size: 84, name: book.title, padding: 3, badge: '', placeholderIcon: XpIcons.book),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold, color: Xp.navy)),
                    Text(
                      [book.author, if (info.chapters.isNotEmpty) '${info.chapters.length} cap.', if (t.durationMs > 0) formatDuration(Duration(milliseconds: t.durationMs))]
                          .join(' · '),
                      style: const TextStyle(fontSize: 12.5, color: Xp.blueText),
                    ),
                    if (done)
                      const Text('Lido até o fim ✓', style: TextStyle(fontSize: 12.5, color: Color(0xFF1D7A2A)))
                    else if (at != null)
                      Text(_whereStopped(app, t), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Xp.blueText)),
                    InkWell(
                      onTap: () => playBookAt(context, t),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const XpIcon(XpIcons.play, size: 14),
                          const SizedBox(width: 4),
                          Text(at != null ? 'Continuar de onde parou' : 'Tocar do começo', style: const TextStyle(fontSize: 13, color: Xp.linkBlue)),
                        ]),
                      ),
                    ),
                    Text(textLine,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: info.textStatus == TextStatus.ok ? const Color(0xFF1D7A2A) : Xp.blueMuted)),
                  ]),
                ),
              ]),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8)))),
            child: Row(children: [
              Expanded(child: BevelButton(icon: XpIcons.doc, label: 'Texto da obra', onTap: () => showBookTextMenu(context, t))),
              const SizedBox(width: 4),
              Expanded(
                child: BevelButton(
                  icon: XpIcons.check,
                  label: done ? 'Lido' : 'Marcar lido',
                  on: done,
                  onTap: () {
                    app.podcastProgress.setListened(t.path, !done);
                    app.touch();
                  },
                ),
              ),
              const SizedBox(width: 4),
              Expanded(child: BevelButton(icon: XpIcons.info, label: 'Detalhes', onTap: () => showBookDetails(context, t))),
            ]),
          ),
          Expanded(
            child: ColoredBox(
              color: Colors.white,
              child: info.chapters.isEmpty
                  ? ListView(padding: const EdgeInsets.all(14), children: const [
                      Text(
                        'Este livro não tem capítulos marcados (o vídeo não tinha capítulos nem "capítulo N" na legenda). '
                        'Ele toca inteiro, e o ⏮/⏭ volta e avança como numa faixa normal.',
                        style: TextStyle(fontSize: 13, color: Xp.blueText),
                      ),
                    ])
                  : ListView.builder(
                      itemCount: info.chapters.length,
                      itemBuilder: (context, i) {
                        final c = info.chapters[i];
                        final start = Duration(milliseconds: c.startMs);
                        final end = Duration(milliseconds: info.chapterEndMs(i, t.durationMs));
                        final heard = done || (curIndex >= 0 && i < curIndex);
                        final current = i == curIndex && (playingThis || at != null);
                        final fg = current && playingThis ? Colors.white : Colors.black;
                        final sub = current && playingThis ? const Color(0xFFDFE8FF) : const Color(0xFF666666);
                        final status = current
                            ? (playingThis ? 'tocando' : 'parou em ${formatClock(pos - start)}')
                            : (heard ? 'ouvido' : formatDuration(end - start));
                        return Material(
                          color: current ? (playingThis ? Xp.select : const Color(0xFFFFF4C2)) : Colors.white,
                          child: InkWell(
                            onTap: () => playBookAt(context, t, at: start),
                            onLongPress: () => _editChapter(context, app, t, i),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF0F0F0)))),
                              child: Row(children: [
                                SizedBox(
                                  width: 28,
                                  child: Text(current ? '▶' : (heard ? '✓' : '${i + 1}'),
                                      style: TextStyle(fontWeight: FontWeight.bold, color: current && playingThis ? Colors.white : Xp.linkBlue)),
                                ),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(c.title.isEmpty ? 'Capítulo ${i + 1}' : c.title,
                                        maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: fg, fontWeight: current ? FontWeight.bold : null)),
                                    Text('${formatClock(start)} · $status', style: TextStyle(fontSize: 11.5, color: sub)),
                                  ]),
                                ),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          XpStatusBar([
            info.chapters.isEmpty ? '1 arquivo · sem capítulos' : '1 arquivo · ${info.chapters.length} capítulos (${info.chapterSource.label})',
            'Audiolivros',
          ]),
        ]),
      ),
    );
  }

  /// Segurar um capítulo: ajustar o começo (para quando o app errou o corte).
  Future<void> _editChapter(BuildContext context, AppState app, Track t, int i) async {
    final info = app.bookInfoOf(t);
    final c = info.chapters[i];
    final title = TextEditingController(text: c.title);
    final start = TextEditingController(text: formatClock(Duration(milliseconds: c.startMs)));
    final ps = context.read<PlayerService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => XpAlertDialog(
        icon: XpIcons.edit,
        title: Text('Capítulo ${i + 1}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Título')),
          const SizedBox(height: 8),
          TextField(controller: start, decoration: const InputDecoration(labelText: 'Começa em (h:mm:ss)')),
          if (ps.current?.id == t.id)
            TextButton(
              onPressed: () => start.text = formatClock(ps.player.position),
              child: Text('Usar o ponto que está tocando (${formatClock(ps.player.position)})'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok == true) {
      final d = parseClock(start.text);
      await app.bookService.editChapter(t.path, i, start: d, title: title.text.trim());
    }
    title.dispose();
    start.dispose();
  }
}

/// "1:02:10" / "12:05" / "45" -> Duration. Null se não der para ler.
Duration? parseClock(String s) {
  final parts = s.trim().split(':').map(int.tryParse).toList();
  if (parts.isEmpty || parts.any((x) => x == null) || parts.length > 3) return null;
  var secs = 0;
  for (final x in parts) {
    secs = secs * 60 + x!;
  }
  return Duration(seconds: secs);
}

/// Menu do texto da obra: procurar de novo, anexar EPUB, tirar o texto.
Future<void> showBookTextMenu(BuildContext context, Track t, {Offset? at}) {
  final app = context.read<AppState>();
  final info = app.bookInfoOf(t);
  return showXpContextMenu(context, header: 'Texto da obra', at: at, items: [
    XpMenuEntry('Procurar no Gutenberg / Wikisource', () async {
      _say('Procurando "${info.title}"…');
      final r = await app.bookService.fetchText(t.path, manual: true);
      _say(switch (r) {
        TextStatus.ok => 'Texto da obra baixado.',
        TextStatus.notFound => 'Não achei esse livro em domínio público. Dá para anexar um EPUB.',
        _ => 'Não deu para baixar o texto agora. Tente mais tarde.',
      });
    }, icon: XpIcons.find),
    XpMenuEntry('Anexar EPUB…', () async {
      final res = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['epub']);
      final path = res.map((f) => f.path).whereType<String>().firstOrNull;
      if (path == null) return;
      try {
        await app.bookService.attachEpub(t.path, path);
        _say('Texto anexado.');
      } on EpubException catch (e) {
        _say(e.message);
      } catch (e) {
        _say('Não deu para ler esse EPUB.');
      }
    }, icon: XpIcons.folder),
    if (info.textStatus == TextStatus.ok) ...[
      XpMenuEntry('Buscar ilustrações de novo', () => unawaited(app.bookService.fetchArt(t.path, manual: true)), icon: XpIcons.refresh),
      XpMenuEntry('Tirar o texto', () => app.bookService.removeText(t.path), icon: XpIcons.bin),
    ],
  ]);
}

/// Segurar a capa do livro.
Future<void> showBookMenu(BuildContext context, Track t, Offset at) => showBookTextMenu(context, t, at: at);

/// Detalhes: de onde vieram os capítulos, o texto e os créditos das ilustrações.
Future<void> showBookDetails(BuildContext context, Track t) {
  final app = context.read<AppState>();
  final info = app.bookInfoOf(t);
  final credits = info.artCredit.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return showDialog<void>(
    context: context,
    builder: (ctx) => XpAlertDialog(
      icon: XpIcons.info,
      title: Text(info.title.isEmpty ? 'Audiolivro' : info.title),
      content: SizedBox(
        width: 360,
        child: ListView(shrinkWrap: true, children: [
          Text('Autor: ${info.author}', style: const TextStyle(fontSize: 13)),
          Text('Capítulos: ${info.chapters.length} · ${info.chapterSource.label}', style: const TextStyle(fontSize: 13)),
          Text('Texto: ${info.textStatus == TextStatus.ok ? info.textSource : (info.textStatus.label.isEmpty ? 'nenhum' : info.textStatus.label)}',
              style: const TextStyle(fontSize: 13)),
          Text('Ilustrações: ${info.art.length} (máximo 30 por livro)', style: const TextStyle(fontSize: 13)),
          if (info.url.isNotEmpty) Text('Vídeo: ${info.url}', style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
          if (credits.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Créditos das ilustrações (Wikimedia Commons):', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
            for (final c in credits) Text('Cap. ${c.key + 1}: ${c.value}', style: const TextStyle(fontSize: 11.5, color: Xp.blueText)),
          ],
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}
