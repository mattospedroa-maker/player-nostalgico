import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../player_service.dart';
import '../theme.dart';
import '../xp_icons.dart';
import '../widgets.dart';
import '../duplicates.dart';
import 'duplicates_screen.dart';
import 'organizer_screen.dart';
import 'youtube_screen.dart';
import 'track_list_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _query = '';

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final root = app.sourceRoot;
    return Column(
      children: [
        XpTitleBar(
          title: 'Biblioteca',
          icon: XpIcons.folder,
          actions: [
            if (root != null) XpTitleButton(icon: Icons.refresh, tooltip: 'Reler pasta', onTap: app.rescan),
            XpTitleButton(icon: Icons.folder_open, tooltip: 'Trocar pasta', onTap: () => chooseMusicFolder(context)),
          ],
        ),
        XpMenuBar([
          ('Arquivo', [XpMenuItem('Trocar pasta de músicas…', () => chooseMusicFolder(context)), XpMenuItem('Reler pasta', root == null ? null : app.rescan)]),
          (
            'Ferramentas',
            [
              XpMenuItem('Buscar novas músicas', () => _push(const OrganizerScreen())),
              XpMenuItem('Baixar do YouTube (MP3)', () => _push(const YoutubeScreen())),
              XpMenuItem('Músicas repetidas', () => _push(const DuplicatesScreen())),
              XpMenuItem('Acervo de GIFs', () => showGifLibraryInfo(context)),
            ],
          ),
        ]),
        XpAddressBar(_query.isEmpty ? 'Música' : 'Música\\Busca: "$_query"'),
        if (app.scanning) LinearProgressIndicator(value: app.scanProgress, minHeight: 3, color: Xp.navy),
        Expanded(
          child: ColoredBox(color: Colors.white, child: root == null ? _welcome() : _library(app, root)),
        ),
        XpStatusBar([app.scanning ? 'Lendo a pasta…' : '${app.tracks.length} músicas', if (root != null) p.basename(root), 'Meu computador']),
      ],
    );
  }

  Widget _welcome() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 40),
      const Center(child: XpIcon(XpIcons.computer, size: 80)),
      const SizedBox(height: 16),
      const Text(
        'Bem-vindo!',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Xp.navy),
      ),
      const SizedBox(height: 8),
      const Text(
        'Escolha a pasta onde ficam suas músicas. O app lê essa pasta e as subpastas, e tudo funciona sem internet.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Xp.blueText),
      ),
      const SizedBox(height: 24),
      XpButton(label: 'Escolher pasta de músicas', xpIcon: XpIcons.folder, primary: true, onTap: () => chooseMusicFolder(context)),
    ],
  );

  Widget _library(AppState app, String root) {
    final ps = context.read<PlayerService>();
    final tracks = app.tracks;
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      final hits = tracks.where((t) => t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q) || t.album.toLowerCase().contains(q)).toList();
      return Column(
        children: [
          _searchField(),
          const XpColumnHeader('Nome', right: 'Artista'),
          Expanded(
            child: hits.isEmpty
                ? const EmptyHint(Icons.search_off, 'Nada encontrado.')
                : ListView.builder(
                    itemCount: hits.length,
                    itemBuilder: (_, i) => TrackTile(
                      track: hits[i],
                      onTap: () => playTracks(context, hits, start: i),
                    ),
                  ),
          ),
        ],
      );
    }
    final recent = [...tracks]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    Set<String> distinct(String Function(Track) f) => tracks.map(f).toSet();
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _searchField(),
        XpTaskPane(
          title: 'Tarefas de música',
          tasks: [
            (XpIcons.play, 'Tocar tudo', tracks.isEmpty ? null : () => playTracks(context, tracks, shuffle: false)),
            (XpIcons.shuffle, 'Tocar em ordem aleatória', tracks.isEmpty ? null : () => playTracks(context, tracks, shuffle: true)),
            (XpIcons.find, 'Buscar novas músicas', () => _push(const OrganizerScreen())),
            (XpIcons.youtube, 'Baixar do YouTube (MP3)', () => _push(const YoutubeScreen())),
          ],
        ),
        IpodBox(
          title: 'Nome',
          trailing: 'Itens',
          children: [
            IpodRow(
              icon: XpIcons.note,
              label: 'Todas as músicas',
              detail: '${tracks.length}',
              onTap: () => _push(TrackListScreen(title: 'Todas as músicas', tracks: tracks, path: 'Música\\Todas')),
            ),
            IpodRow(
              icon: XpIcons.person,
              label: 'Artistas',
              detail: '${distinct((t) => t.artist).length}',
              onTap: () => _push(const GroupListScreen(kind: GroupKind.artist)),
            ),
            IpodRow(
              icon: XpIcons.disc,
              label: 'Álbuns',
              detail: '${distinct((t) => t.album).length}',
              onTap: () => _push(const GroupListScreen(kind: GroupKind.album)),
            ),
            IpodRow(
              icon: XpIcons.star,
              label: 'Gêneros',
              detail: '${distinct((t) => t.genre).where((g) => g.isNotEmpty).length}',
              onTap: () => _push(const GroupListScreen(kind: GroupKind.genre)),
            ),
            if (duplicateExtraCount(tracks) case final extra when extra > 0)
              IpodRow(icon: XpIcons.duplicate, label: 'Músicas repetidas', detail: '$extra sobrando', onTap: () => _push(const DuplicatesScreen())),
            IpodRow(
              icon: XpIcons.folder,
              label: 'Pastas',
              detail: p.basename(root),
              onTap: () => _push(const GroupListScreen(kind: GroupKind.folder)),
            ),
            IpodRow(icon: XpIcons.film, label: 'Acervo de GIFs', detail: '${app.gifs.count}', onTap: () => showGifLibraryInfo(context)),
          ],
        ),
        if (recent.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Bevel(
              sunken: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const XpColumnHeader('Adicionadas recentemente'),
                  for (final t in recent.take(8))
                    TrackTile(
                      track: t,
                      onTap: () {
                        playTracks(context, [t]);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Tocando "${t.title}". Depois dela: mix ${ps.mixMode == MixMode.artist ? 'do mesmo artista' : 'da mesma vibe'} (troque no Tocando agora).',
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ] else if (!app.scanning)
          const EmptyHint(Icons.music_off, 'Nenhuma música encontrada nessa pasta.'),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
    child: Bevel(
      sunken: true,
      child: TextField(
        onChanged: (v) => setState(() => _query = v.trim()),
        style: const TextStyle(fontSize: 14),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          prefixIcon: Padding(padding: EdgeInsets.all(8), child: XpIcon(XpIcons.find, size: 18)),
          prefixIconConstraints: BoxConstraints(minWidth: 34, minHeight: 34),
          hintText: 'Buscar música, artista, álbum…',
          contentPadding: EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    ),
  );
}
