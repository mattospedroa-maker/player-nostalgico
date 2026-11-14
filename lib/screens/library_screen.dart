import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gif_fetcher.dart' show maxGifsPerTrack;
import '../main.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets.dart';
import 'organizer_screen.dart';
import 'track_list_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _query = '';

  Future<void> _chooseFolder() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await app.ensureStoragePermission()) {
      messenger.showSnackBar(const SnackBar(content: Text('Sem permissão de acesso aos arquivos, não consigo ler as músicas.')));
      return;
    }
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Escolha a pasta das suas músicas');
    if (dir == null) return;
    await app.setSourceRoot(dir);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final root = app.sourceRoot;
    return Column(children: [
      XpTitleBar(title: 'Biblioteca', actions: [
        if (root != null) XpTitleButton(icon: Icons.refresh, tooltip: 'Reler pasta', onTap: app.rescan),
        XpTitleButton(icon: Icons.folder_open, tooltip: 'Trocar pasta', onTap: _chooseFolder),
      ]),
      if (app.scanning) LinearProgressIndicator(value: app.scanProgress, minHeight: 3, color: Xp.navy),
      Expanded(child: root == null ? _welcome() : _library(app, root)),
    ]);
  }

  Widget _welcome() => ListView(padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 40),
        const Icon(Icons.library_music, size: 72, color: Xp.blue),
        const SizedBox(height: 16),
        const Text('Bem-vindo!',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Xp.navy)),
        const SizedBox(height: 8),
        const Text('Escolha a pasta onde ficam suas músicas. O app lê essa pasta e as subpastas, e tudo funciona sem internet.',
            textAlign: TextAlign.center, style: TextStyle(color: Xp.blueText)),
        const SizedBox(height: 24),
        XpButton(label: 'Escolher pasta de músicas', icon: Icons.folder_open, primary: true, onTap: _chooseFolder),
      ]);

  Widget _library(AppState app, String root) {
    final ps = context.read<PlayerService>();
    final tracks = app.tracks;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      final hits = tracks
          .where((t) => t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q) || t.album.toLowerCase().contains(q))
          .toList();
      return Column(children: [
        _searchField(),
        Expanded(
          child: hits.isEmpty
              ? const EmptyHint(Icons.search_off, 'Nada encontrado.')
              : ListView.builder(
                  itemCount: hits.length,
                  itemBuilder: (_, i) => TrackTile(track: hits[i], onTap: () {
                    ps.playQueue(hits, start: i);
                    HomeShell.goTo(context, 0);
                  }),
                ),
        ),
      ]);
    }
    final recent = [...tracks]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    Set<String> distinct(String Function(Track) f) => tracks.map(f).toSet();
    return ListView(padding: EdgeInsets.zero, children: [
      _searchField(),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
        child: XpButton(
          label: 'Buscar novas músicas',
          icon: Icons.travel_explore,
          primary: true,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OrganizerScreen())),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        child: Text('Pasta: ${p.basename(root)} · organiza em Artista/Álbum',
            style: const TextStyle(fontSize: 11, color: Xp.blueMuted)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        child: Builder(builder: (context) {
          final prog = app.bulkGifProgress;
          return XpButton(
            label: prog == null ? 'Baixar GIFs para todas' : 'Baixando GIFs ${prog.$1} de ${prog.$2} · toque para parar',
            icon: Icons.gif_box_outlined,
            onTap: () async {
              if (prog != null) return app.cancelBulkGifs();
              final messenger = ScaffoldMessenger.of(context);
              final n = await app.fetchGifsForAll();
              messenger.showSnackBar(SnackBar(content: Text('$n GIFs novos baixados (até $maxGifsPerTrack por música).')));
            },
          );
        }),
      ),
      IpodBox(title: 'Música', trailing: '${tracks.length} faixas', children: [
        IpodRow(label: 'Todas as músicas', selected: true, onTap: () => _open('Todas as músicas', tracks)),
        IpodRow(label: 'Artistas', detail: '${distinct((t) => t.artist).length}', onTap: () => _openGroups('Artistas', (t) => t.artist)),
        IpodRow(label: 'Álbuns', detail: '${distinct((t) => t.album).length}', onTap: () => _openGroups('Álbuns', (t) => t.album, sub: (t) => t.artist)),
        IpodRow(
            label: 'Gêneros',
            detail: '${distinct((t) => t.genre).where((g) => g.isNotEmpty).length}',
            onTap: () => _openGroups('Gêneros', (t) => t.genre.isEmpty ? 'Sem gênero' : t.genre)),
        IpodRow(label: 'Pastas', detail: p.basename(root), onTap: () => _openGroups('Pastas', (t) => p.relative(p.dirname(t.path), from: root))),
        IpodRow(label: 'Acervo de GIFs', detail: '${app.gifs.count}', onTap: () => _gifInfo(app)),
      ]),
      if (recent.isNotEmpty) ...[
        const SectionLabel('Adicionadas recentemente'),
        for (final t in recent.take(8))
          TrackTile(track: t, onTap: () {
            ps.playQueue([t]);
            HomeShell.goTo(context, 0);
          }),
      ] else if (!app.scanning)
        const EmptyHint(Icons.music_off, 'Nenhuma música encontrada nessa pasta.'),
      const SizedBox(height: 20),
    ]);
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
        child: TextField(
          onChanged: (v) => setState(() => _query = v.trim()),
          decoration: const InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            prefixIcon: Icon(Icons.search, size: 20),
            hintText: 'Buscar música, artista, álbum…',
            border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: Color(0xFF7F9DB9))),
          ),
        ),
      );

  void _open(String title, List<Track> tracks) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrackListScreen(title: title, tracks: tracks)));

  void _openGroups(String title, String Function(Track) key, {String Function(Track)? sub}) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupListScreen(title: title, keyOf: key, subOf: sub)));
  }

  void _gifInfo(AppState app) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Acervo de GIFs'),
          content: Text('${app.gifs.count} GIFs em\n${app.gifs.gifRoot}\n\n'
              'Crie subpastas com o nome do artista, álbum ou gênero (ex.: GIFs/Hatsune Miku) e os GIFs aparecem nas músicas que combinam. '
              'GIFs soltos direto na pasta GIFs aparecem em qualquer música.'),
          actions: [
            TextButton(
                onPressed: () {
                  app.reload();
                  Navigator.pop(ctx);
                },
                child: const Text('Recarregar')),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
}
