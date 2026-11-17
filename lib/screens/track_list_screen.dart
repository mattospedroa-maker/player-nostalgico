import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../artist_names.dart';
import '../models.dart';
import '../theme.dart';
import '../thumbnails.dart';
import '../widgets.dart';
import '../xp_icons.dart';

/// Lista de músicas com "Tocar tudo" e "Aleatório".
class TrackListScreen extends StatelessWidget {
  final String title;
  final List<Track> tracks;
  final String? path;
  final GroupThumb? thumb;
  final String? subtitle;
  const TrackListScreen({super.key, required this.title, required this.tracks, this.path, this.thumb, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // usa a versão mais recente (favorita, caminho) de cada faixa
    final list = [for (final t in tracks) app.byId(t.id) ?? t];
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(
            children: [
              XpTitleBar(
                title: title,
                icon: thumb == null ? XpIcons.note : XpIcons.disc,
                actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))],
              ),
              XpAddressBar(path ?? 'Música\\$title'),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    if (thumb != null) ...[ThumbFrame(thumb: thumb!, size: 96, name: title), const SizedBox(width: 10)],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (thumb != null) ...[
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Xp.navy),
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, color: Color(0xFF555555)),
                              ),
                            const SizedBox(height: 6),
                          ],
                          Row(
                            children: [
                              Expanded(
                                child: XpButton(
                                  label: 'Tocar tudo',
                                  xpIcon: XpIcons.play,
                                  primary: true,
                                  onTap: list.isEmpty ? null : () => playTracks(context, list, shuffle: false),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: XpButton(
                                  label: 'Aleatório',
                                  xpIcon: XpIcons.shuffle,
                                  onTap: list.isEmpty ? null : () => playTracks(context, list, shuffle: true),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Bevel(
                    sunken: true,
                    child: Column(
                      children: [
                        const XpColumnHeader('Nome', right: 'Duração'),
                        Expanded(
                          child: ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (_, i) => TrackTile(
                              track: list[i],
                              onTap: () => playTracks(context, list, start: i),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              XpStatusBar(['${list.length} faixas', fmtTotal(list)]),
            ],
          ),
        ),
      ),
    );
  }
}

enum GroupKind { artist, album, genre, folder }

/// Miniatura de um álbum/artista: a capa, ou (sem capa) o GIF que mais aparece nas músicas dele.
class GroupThumb {
  final File? file;
  final bool isGif;
  final Color color;
  const GroupThumb({this.file, this.isGif = false, required this.color});
}

/// Artistas / Álbuns / Gêneros / Pastas. Álbuns e Artistas abrem em miniaturas, com índice A–Z.
class GroupListScreen extends StatefulWidget {
  final GroupKind kind;
  const GroupListScreen({super.key, required this.kind});

  @override
  State<GroupListScreen> createState() => _GroupListScreenState();
}

class _GroupListScreenState extends State<GroupListScreen> {
  final _scroll = ScrollController();
  Map<int, List<String>>? _pinned;
  final _thumbs = <String, GroupThumb>{};
  final _gifLookups = <String>{};
  String? _lastOpened;
  String? _letter;

  static const _cols = 3;
  static const _tileHeight = 178.0;
  static const _rowHeight = 54.0;

  GroupKind get kind => widget.kind;
  bool get _hasThumbs => kind == GroupKind.album || kind == GroupKind.artist;
  String get _title => switch (kind) {
    GroupKind.artist => 'Artistas',
    GroupKind.album => 'Álbuns',
    GroupKind.genre => 'Gêneros',
    GroupKind.folder => 'Pastas',
  };
  String get _prefKey => 'groupView_${kind.name}';

  bool _grid(AppState app) => _hasThumbs && (app.prefs.getString(_prefKey) ?? 'grid') == 'grid';

  @override
  void initState() {
    super.initState();
    if (_hasThumbs) {
      context.read<AppState>().db.allPinnedGifs().then((m) {
        if (mounted) setState(() => _pinned = m);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _keyOf(Track t, String root) => switch (kind) {
    GroupKind.artist => ArtistNames.current.main(t.artist),
    GroupKind.album => t.album,
    GroupKind.genre => t.genre.isEmpty ? 'Sem gênero' : t.genre,
    GroupKind.folder => p.relative(p.dirname(t.path), from: root),
  };

  GroupThumb _thumbFor(AppState app, String key, List<Track> group) {
    final known = _thumbs[key];
    if (known != null && known.file != null) return known;
    final color = colorFor(key);
    final ordered = kind == GroupKind.artist ? byMainAlbum(group) : group;
    for (final t in ordered) {
      final f = app.covers.fileFor(t);
      if (f != null) return _thumbs[key] = GroupThumb(file: f, color: color);
    }
    final pinned = _pinned;
    if (pinned != null) {
      final g = mostFrequentGif(group, pinned, exists: (path) => File(path).existsSync());
      if (g != null) return _thumbs[key] = GroupThumb(file: File(g), isGif: true, color: color);
      // nenhum GIF fixado: usa um GIF da pasta do artista/álbum no acervo, se houver
      if (_gifLookups.add(key)) {
        app.gifs.gifsFor(group.first, max: 1).then((l) {
          if (l.isNotEmpty && mounted) setState(() => _thumbs[key] = GroupThumb(file: File(l.first), isGif: true, color: color));
        });
      }
    }
    return known ?? GroupThumb(color: color);
  }

  void _open(AppState app, String key, List<Track> group) {
    setState(() => _lastOpened = key);
    final label = key == '.' ? '(raiz)' : key;
    final thumb = _hasThumbs ? _thumbFor(app, key, group) : null;
    final sub = switch (kind) {
      GroupKind.album => '${group.first.artist} · ${group.length} faixas',
      GroupKind.artist => '${group.map((t) => t.album).toSet().length} álbuns · ${group.length} faixas',
      _ => null,
    };
    final sorted = kind == GroupKind.album ? group : ([...group]..sort((a, b) => a.album.compareTo(b.album)));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrackListScreen(title: label, tracks: sorted, path: 'Música\\$_title\\$label', thumb: thumb, subtitle: sub),
      ),
    );
  }

  void _jump(String letter, List<String> keys, bool grid) {
    setState(() => _letter = letter);
    final i = firstIndexForLetter(keys, letter);
    final offset = grid ? (i ~/ _cols) * _tileHeight : i * _rowHeight;
    if (_scroll.hasClients) _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final root = app.sourceRoot ?? '';
    final groups = <String, List<Track>>{};
    for (final t in app.tracks) {
      groups.putIfAbsent(_keyOf(t, root), () => []).add(t);
    }
    final keys = groups.keys.toList()..sort(compareForIndex);
    final grid = _grid(app);
    final letters = keys.map(indexLetter).toSet();
    final gifCount = _hasThumbs ? keys.where((k) => _thumbs[k]?.isGif ?? false).length : 0;
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(
            children: [
              XpTitleBar(
                title: _title,
                icon: switch (kind) {
                  GroupKind.artist => XpIcons.person,
                  GroupKind.album => XpIcons.disc,
                  GroupKind.genre => XpIcons.star,
                  GroupKind.folder => XpIcons.folder,
                },
                actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))],
              ),
              XpAddressBar('Música\\$_title'),
              if (_hasThumbs)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8))),
                  ),
                  child: Row(
                    children: [
                      const Text('Exibir:', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 6),
                      _viewToggle(app, 'Miniaturas', 'grid', grid),
                      const SizedBox(width: 4),
                      _viewToggle(app, 'Detalhes', 'list', !grid),
                    ],
                  ),
                ),
              Expanded(
                child: ColoredBox(
                  color: Colors.white,
                  child: Row(
                    children: [
                      Expanded(child: grid ? _gridView(app, keys, groups) : _listView(app, keys, groups)),
                      _azRail(letters, keys, grid),
                    ],
                  ),
                ),
              ),
              XpStatusBar(['${keys.length} ${_title.toLowerCase()}', if (gifCount > 0) '$gifCount com GIF no lugar da capa']),
            ],
          ),
        ),
      ),
    );
  }

  Widget _viewToggle(AppState app, String label, String value, bool on) => GestureDetector(
    onTap: () async {
      await app.prefs.setString(_prefKey, value);
      if (_scroll.hasClients) _scroll.jumpTo(0);
      setState(() {});
    },
    child: Bevel(
      sunken: on,
      color: on ? const Color(0xFFE3E1D4) : Xp.beige,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.bold : FontWeight.normal)),
    ),
  );

  Widget _gridView(AppState app, List<String> keys, Map<String, List<Track>> groups) => GridView.builder(
    controller: _scroll,
    padding: const EdgeInsets.fromLTRB(6, 8, 2, 8),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: _cols, mainAxisExtent: _tileHeight),
    itemCount: keys.length,
    itemBuilder: (_, i) {
      final k = keys[i];
      final g = groups[k]!;
      final sel = k == _lastOpened;
      return GestureDetector(
        onTap: () => _open(app, k, g),
        child: Column(
          children: [
            ThumbFrame(thumb: _thumbFor(app, k, g), size: 104, name: k, selected: sel),
            const SizedBox(height: 4),
            Container(
              color: sel ? Xp.select : null,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                k,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, height: 1.15, color: sel ? Colors.white : Colors.black),
              ),
            ),
            Text(
              kind == GroupKind.album ? g.first.artist : '${g.length} faixas',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
            ),
          ],
        ),
      );
    },
  );

  Widget _listView(AppState app, List<String> keys, Map<String, List<Track>> groups) => Column(
    children: [
      XpColumnHeader('Nome', right: kind == GroupKind.album ? 'Artista' : 'Faixas'),
      Expanded(
        child: ListView.builder(
          controller: _scroll,
          itemExtent: _rowHeight,
          itemCount: keys.length,
          itemBuilder: (_, i) {
            final k = keys[i];
            final g = groups[k]!;
            final sel = k == _lastOpened;
            return InkWell(
              onTap: () => _open(app, k, g),
              child: Container(
                color: sel ? Xp.select : null,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    if (_hasThumbs)
                      ThumbFrame(thumb: _thumbFor(app, k, g), size: 40, name: k, padding: 2)
                    else
                      XpIcon(kind == GroupKind.genre ? XpIcons.star : XpIcons.folder, size: 26),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        k == '.' ? '(raiz)' : k,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, color: sel ? Colors.white : Colors.black),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        kind == GroupKind.album ? g.first.artist : '${g.length}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: sel ? Colors.white70 : const Color(0xFF666666)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ],
  );

  /// Índice A–Z na lateral: toque ou arraste para pular direto para a letra.
  Widget _azRail(Set<String> present, List<String> keys, bool grid) {
    const all = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    return LayoutBuilder(
      builder: (context, c) {
        void at(double y) {
          final i = (y / c.maxHeight * all.length).floor().clamp(0, all.length - 1);
          if (all[i] != _letter) _jump(all[i], keys, grid);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => at(d.localPosition.dy),
          onVerticalDragUpdate: (d) => at(d.localPosition.dy),
          child: Container(
            width: 22,
            color: const Color(0xFFF1F4FB),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final l in all.split(''))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(color: l == _letter ? Xp.select : null, borderRadius: BorderRadius.circular(2)),
                    child: Text(
                      l,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: l == _letter ? Colors.white : (present.contains(l) ? const Color(0xFF1C3F94) : const Color(0xFFB5BDCF)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Moldura de miniatura do Explorer (borda fina, fundo branco). Sem imagem: quadro colorido com o nome.
class ThumbFrame extends StatelessWidget {
  final GroupThumb thumb;
  final double size;
  final String name;
  final bool selected;
  final double padding;
  const ThumbFrame({super.key, required this.thumb, required this.size, required this.name, this.selected = false, this.padding = 4});

  @override
  Widget build(BuildContext context) {
    final f = thumb.file;
    final inner = f != null
        ? Image.file(f, fit: BoxFit.cover, cacheWidth: (size * 2.5).round(), gaplessPlayback: true, errorBuilder: (_, _, _) => _placeholder())
        : _placeholder();
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: selected ? Xp.select : const Color(0xFFB8C4D8), width: selected ? 2 : 1),
        boxShadow: const [BoxShadow(color: Color(0xFFD6DBE5), offset: Offset(1, 1))],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          inner,
          if (thumb.isGif && size >= 60)
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Xp.navy,
                  border: Border.all(color: const Color(0xFF9CB8FF)),
                ),
                child: const Text(
                  'GIF',
                  style: TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _placeholder() => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [thumb.color, Color.lerp(thumb.color, Colors.black, .5)!]),
    ),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(4),
    child: size < 60
        ? Text(
            indexLetter(name),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          )
        : Text(
            name,
            maxLines: 3,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
  );
}
