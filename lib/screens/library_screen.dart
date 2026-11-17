import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../artist_names.dart';
import '../library_search.dart';
import '../models.dart';
import '../mood.dart';
import '../play_stats.dart';
import '../smart_collections.dart';
import '../player_service.dart';
import '../theme.dart';
import '../xp_icons.dart';
import '../widgets.dart';
import '../duplicates.dart';
import 'duplicates_screen.dart';
import 'organizer_screen.dart';
import 'youtube_screen.dart';
import 'smart_library_widgets.dart';
import 'track_list_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String _query = '';
  final _search = TextEditingController();
  Timer? _debounce;
  TrackFilter _filter = const TrackFilter();
  TrackSort _sort = TrackSort.relevance;

  /// "Filtros e ordem" aberto mesmo sem nada digitado.
  bool _browsing = false;

  // último resultado (só refaz quando a busca, o filtro, a ordem, a biblioteca ou o histórico mudam)
  Object? _resultKey;
  List<Track> _results = const [];

  bool get _searching => _query.isNotEmpty || !_filter.isEmpty || _browsing;

  AppState? _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>()..statsVersion.addListener(_onStats);
  }

  void _onStats() {
    if (mounted && _searching) setState(() {});
  }

  @override
  void dispose() {
    _app?.statsVersion.removeListener(_onStats);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Espera parar de digitar um instante antes de buscar.
  void _onType(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  void _clearAll() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _query = '';
      _filter = const TrackFilter();
      _sort = TrackSort.relevance;
      _browsing = false;
    });
  }

  void _push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final root = app.sourceRoot;
    if (_searching) _updateResults(app);
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
        XpAddressBar(_query.isEmpty ? (_searching ? 'Música\\Filtrar' : 'Música') : 'Música\\Busca: "$_query"'),
        if (app.scanning) Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: XpProgress(value: app.scanProgress, height: 14)),
        Expanded(
          child: ColoredBox(color: Colors.white, child: root == null ? _welcome() : _library(app, root)),
        ),
        XpStatusBar([app.scanning ? 'Lendo a pasta…' : (_searching ? '${_results.length} de ${app.tracks.length} músicas' : '${app.tracks.length} músicas'), if (root != null) p.basename(root), 'Meu computador']),
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
    if (_searching) return _resultsView(app);
    final sum = _summaryOf(tracks);
    final recent = sum.recent;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _searchField(),
        _filterLink(),
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
              detail: '${sum.artists}',
              onTap: () => _push(const GroupListScreen(kind: GroupKind.artist)),
            ),
            IpodRow(
              icon: XpIcons.disc,
              label: 'Álbuns',
              detail: '${sum.albums}',
              onTap: () => _push(const GroupListScreen(kind: GroupKind.album)),
            ),
            IpodRow(
              icon: XpIcons.star,
              label: 'Gêneros',
              detail: '${sum.genres}',
              onTap: () => _push(const GroupListScreen(kind: GroupKind.genre)),
            ),
            if (sum.duplicates case final extra when extra > 0)
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
        _smartBox(app),
        if (recent.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Bevel(
              sunken: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const XpColumnHeader('Adicionadas recentemente'),
                  for (final t in recent)
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
        controller: _search,
        onChanged: _onType,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          prefixIcon: const Padding(padding: EdgeInsets.all(8), child: XpIcon(XpIcons.find, size: 18)),
          prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          suffixIcon: _searching ? IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Limpar busca', onPressed: _clearAll) : null,
          hintText: 'Buscar música, artista, álbum, gênero, clima…',
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    ),
  );

  /// Link "Filtros e ordem" embaixo da busca (abre a lista com filtros sem precisar digitar).
  Widget _filterLink() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: () => setState(() => _browsing = true),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text('▸ Filtrar e organizar (artista, gênero, clima…)', style: TextStyle(fontSize: 13.5, color: Xp.linkBlue, decoration: TextDecoration.underline)),
        ),
      ),
    ),
  );

  /// Refaz a lista só quando a busca, o filtro, a ordem, a biblioteca ou o histórico mudam.
  void _updateResults(AppState app) {
    final needsStats = _sort == TrackSort.plays || _sort == TrackSort.recent;
    final stats = needsStats ? app.playStatsNow : PlayStats.empty;
    if (needsStats) {
      // o resumo do histórico chega uma vez; depois só muda quando uma música entra no histórico
      app.playStats().then((s) {
        if (mounted && !identical(s, stats)) setState(() {});
      });
    }
    final key = (identityHashCode(app.tracks), _query, _filter.artist, _filter.album, _filter.genre, _filter.mood, _filter.favoritesOnly, _sort, identityHashCode(stats));
    if (key == _resultKey) return;
    _resultKey = key;
    _stats = stats;
    _results = queryLibrary(app.tracks, query: _query, filter: _filter, sort: _sort, stats: stats);
  }

  PlayStats _stats = PlayStats.empty;

  Widget _resultsView(AppState app) {
    final hits = _results;
    return Column(
      children: [
        _searchField(),
        _filtersBox(app),
        XpColumnHeader('Nome', right: '${hits.length} itens'),
        Expanded(
          child: hits.isEmpty
              ? const EmptyHint(Icons.search_off, 'Nada encontrado.\nTente menos palavras ou tire um filtro.')
              : ListView.builder(
                  itemCount: hits.length,
                  itemBuilder: (_, i) => TrackTile(
                    track: hits[i],
                    subtitle: _details(hits[i], _stats),
                    onTap: () => playTracks(context, hits, start: i),
                  ),
                ),
        ),
      ],
    );
  }

  String _details(Track t, PlayStats stats) {
    final parts = <String>[t.artist];
    if (t.album != unknownAlbum && t.album.isNotEmpty) parts.add(t.album);
    if (_sort == TrackSort.plays || _sort == TrackSort.recent) parts.add('${stats.count(t.id)} plays');
    return parts.join(' · ');
  }

  Widget _filtersBox(AppState app) {
    String countOf(int n) => '$n';
    Future<void> pick<T>(String title, List<(T?, String, int)> opts, T? current, void Function(T?) set) async {
      final i = await showXpChoice(context, title: title, options: [for (final o in opts) (o.$2, o.$3 < 0 ? null : countOf(o.$3))], selected: opts.indexWhere((o) => o.$1 == current));
      if (i != null && mounted) setState(() => set(opts[i].$1));
    }

    // opções contam só as músicas que passam pelos outros filtros (assim nunca dá lista vazia)
    List<(String?, String, int)> group(String Function(Track) key, TrackFilter others, {bool skipEmpty = false}) {
      final m = <String, int>{};
      for (final t in app.tracks) {
        if (!others.matches(t)) continue;
        final k = key(t);
        if (skipEmpty && k.isEmpty) continue;
        m[k] = (m[k] ?? 0) + 1;
      }
      final keys = m.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return [(null, 'Todos', -1), for (final k in keys) (k, k, m[k]!)];
    }

    final f = _filter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: XpGroupBox(
        title: 'Filtrar e organizar',
        background: Colors.white,
        child: Column(children: [
          Row(children: [
            Expanded(
              child: XpCombo(
                label: 'Artista:',
                value: f.artist ?? 'Todos',
                set: f.artist != null,
                onTap: () => pick('Artista', group((t) => ArtistNames.current.main(t.artist), f.copyWith(artist: () => null)), f.artist, (v) => _filter = _filter.copyWith(artist: () => v)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: XpCombo(
                label: 'Gênero:',
                value: f.genre ?? 'Todos',
                set: f.genre != null,
                onTap: () => pick('Gênero', group((t) => t.genre, f.copyWith(genre: () => null), skipEmpty: true), f.genre, (v) => _filter = _filter.copyWith(genre: () => v)),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: XpCombo(
                label: 'Clima:',
                value: f.mood == null ? 'Todos' : '${f.mood!.emoji} ${f.mood!.label}',
                set: f.mood != null,
                onTap: () {
                  final others = f.copyWith(mood: () => null);
                  final n = <Mood, int>{};
                  for (final t in app.tracks) {
                    final m = t.effectiveMood;
                    if (m != null && others.matches(t)) n[m] = (n[m] ?? 0) + 1;
                  }
                  pick<Mood>('Clima', [(null, 'Todos', -1), for (final m in Mood.values) if (n[m] != null) (m, '${m.emoji} ${m.label}', n[m]!)], f.mood,
                      (v) => _filter = _filter.copyWith(mood: () => v));
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: XpCombo(
                label: 'Organizar por:',
                value: _query.isEmpty && _sort == TrackSort.relevance ? TrackSort.artist.label : _sort.label,
                onTap: () => pick<TrackSort>('Organizar por', [for (final s in TrackSort.values) if (s != TrackSort.relevance || _query.isNotEmpty) (s, s.label, -1)], _sort,
                    (v) => _sort = v ?? TrackSort.relevance),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            XpToggle(label: '♥ Só favoritas', on: f.favoritesOnly, onTap: () => setState(() => _filter = f.copyWith(favoritesOnly: !f.favoritesOnly))),
            const Spacer(),
            if (!f.isEmpty)
              InkWell(
                onTap: () => setState(() => _filter = const TrackFilter()),
                child: const Padding(padding: EdgeInsets.all(4), child: Text('Limpar filtros', style: TextStyle(fontSize: 13.5, color: Xp.linkBlue, decoration: TextDecoration.underline))),
              ),
          ]),
        ]),
      ),
    );
  }

  /// Contas da página inicial (recentes, artistas, álbuns, gêneros, repetidas), refeitas só quando a lista
  /// de músicas muda. Antes eram refeitas a cada redesenho da tela (inclusive a cada arquivo lido na releitura).
  _LibrarySummary? _summary;
  _LibrarySummary _summaryOf(List<Track> tracks) {
    final s = _summary;
    if (s != null && identical(s.tracks, tracks)) return s;
    return _summary = _LibrarySummary(tracks);
  }

  // coleções automáticas da última vez (refeitas quando a biblioteca, o histórico ou a música atual mudam)
  (List<Track>, PlayStats, int?)? _colsKey;
  List<SmartCollection> _cols = const [];
  List<SmartCollection> _collections(AppState app, PlayStats stats, int? current) {
    final k = _colsKey;
    if (k != null && identical(k.$1, app.tracks) && identical(k.$2, stats) && k.$3 == current) return _cols;
    _colsKey = (app.tracks, stats, current);
    return _cols = buildSmartCollections(app.tracks, stats, current: app.byId(current));
  }

  /// Coleções automáticas: recalculadas quando a biblioteca ou o histórico mudam (não são playlists).
  Widget _smartBox(AppState app) {
    final current = context.select<PlayerService, int?>((p) => p.current?.id);
    return ValueListenableBuilder<int>(
      valueListenable: app.statsVersion,
      builder: (context, _, _) => FutureBuilder<PlayStats>(
        future: app.playStats(),
        initialData: app.playStatsNow,
        builder: (context, snap) {
          final cols = _collections(app, snap.data ?? PlayStats.empty, current);
          final moods = cols.where((c) => c.id.startsWith('mood:')).toList();
          void open(SmartCollection c) => _push(SmartCollectionScreen(id: c.id, title: c.title));
          return IpodBox(
            title: 'Coleções automáticas',
            trailing: 'Itens',
            children: [
              for (final c in cols.where((c) => !c.id.startsWith('mood:'))) IpodRow(icon: c.icon, label: c.title, detail: '${c.tracks.length}', onTap: () => open(c)),
              if (moods.isNotEmpty)
                Builder(
                  builder: (ctx) => IpodRow(
                    icon: XpIcons.cassette,
                    label: 'Por clima',
                    detail: '${moods.length} climas',
                    onTap: () => showXpContextMenu(ctx, header: 'Por clima', items: [
                      for (final c in moods) XpMenuEntry('${c.title.replaceFirst('Clima ', '')}  (${c.tracks.length})', () => open(c)),
                    ]),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Resumo da biblioteca para a página inicial.
class _LibrarySummary {
  final List<Track> tracks;
  late final List<Track> recent = ([...tracks]..sort((a, b) => b.addedAt.compareTo(a.addedAt))).take(8).toList();
  late final int artists = tracks.map((t) => ArtistNames.current.key(t.artist)).toSet().length;
  late final int albums = tracks.map((t) => t.album).toSet().length;
  late final int genres = tracks.map((t) => t.genre).where((g) => g.isNotEmpty).toSet().length;
  late final int duplicates = duplicateExtraCount(tracks);
  _LibrarySummary(this.tracks);
}
