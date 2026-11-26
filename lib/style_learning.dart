import 'dart:convert';
import 'dart:io';

import 'artist_names.dart';
import 'lastfm.dart' show MusicTag;
import 'models.dart';
import 'mood.dart';
import 'styles.dart';

/// O que o app aprende com as suas playlists: músicas e artistas que você junta, e estilos que andam juntos.
/// Tudo em memória, refeito quando as playlists mudam. Playlists de clima ("Triste", "Calmo"...) ficam de fora:
/// elas juntam músicas pelo clima, não pelo som.
class StyleLearning {
  /// Em quantas playlists cada par de músicas aparece junto.
  final Map<int, Map<int, int>> _trackCo;

  /// Em quantas playlists cada par de artistas aparece junto (chave do artista).
  final Map<String, Map<String, int>> _artistCo;

  /// Estilos que andam juntos nas playlists (0..1).
  final Map<String, double> _stylePairs;

  /// Músicas que você pôs numa playlist pelo ＋ das sugestões: trackId -> playlists.
  final Map<int, Set<int>> addedFromSuggestions;

  StyleLearning._(this._trackCo, this._artistCo, this._stylePairs, this.addedFromSuggestions);

  static StyleLearning current = StyleLearning._({}, {}, {}, {});

  /// Playlists maiores que isto não contam par a par (seriam milhões de pares e pouco significado).
  static const maxPairPlaylist = 150;

  static String _pairKey(String a, String b) => a.compareTo(b) < 0 ? '$a\u0000$b' : '$b\u0000$a';

  /// Monta o aprendizado. [membership]: playlistId -> ids das músicas; [names]: playlistId -> nome.
  static StyleLearning build(Map<int, List<int>> membership, Map<int, String> names, List<Track> tracks,
      {Map<int, Set<int>> addedFromSuggestions = const {}}) {
    final byId = {for (final t in tracks) if (t.id != null) t.id!: t};
    final trackCo = <int, Map<int, int>>{};
    final artistCo = <String, Map<String, int>>{};
    final styleCount = <String, int>{};
    final pairCount = <String, int>{};
    for (final e in membership.entries) {
      final name = names[e.key] ?? '';
      if (Mood.values.any((m) => m.label.toLowerCase() == name.trim().toLowerCase())) continue;
      final ids = {for (final id in e.value) if (byId.containsKey(id)) id}.toList();
      if (ids.length < 2) continue;
      if (ids.length <= maxPairPlaylist) {
        for (var i = 0; i < ids.length; i++) {
          for (var j = i + 1; j < ids.length; j++) {
            (trackCo[ids[i]] ??= {}).update(ids[j], (v) => v + 1, ifAbsent: () => 1);
            (trackCo[ids[j]] ??= {}).update(ids[i], (v) => v + 1, ifAbsent: () => 1);
          }
        }
      }
      final artists = <String>{
        for (final id in ids)
          if (byId[id]!.artist != unknownArtist) ArtistNames.current.key(byId[id]!.artist)
      }.toList();
      if (artists.length <= maxPairPlaylist) {
        for (var i = 0; i < artists.length; i++) {
          for (var j = i + 1; j < artists.length; j++) {
            (artistCo[artists[i]] ??= {}).update(artists[j], (v) => v + 1, ifAbsent: () => 1);
            (artistCo[artists[j]] ??= {}).update(artists[i], (v) => v + 1, ifAbsent: () => 1);
          }
        }
      }
      // estilos principais (os 2 primeiros de cada música) presentes na playlist
      final styles = <String>{for (final id in ids) ...Styles.of(byId[id]!).take(2)}.toList();
      for (final s in styles) {
        styleCount[s] = (styleCount[s] ?? 0) + 1;
      }
      for (var i = 0; i < styles.length; i++) {
        for (var j = i + 1; j < styles.length; j++) {
          pairCount.update(_pairKey(styles[i], styles[j]), (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }
    final stylePairs = <String, double>{};
    for (final e in pairCount.entries) {
      final parts = e.key.split('\u0000');
      final most = [styleCount[parts[0]] ?? 1, styleCount[parts[1]] ?? 1].reduce((a, b) => a > b ? a : b);
      // uma playlist só já conta um pouco; aparecer junto em todas as playlists de um dos dois vale 1
      stylePairs[e.key] = (e.value / most) * (e.value >= 2 ? 1 : .5);
    }
    return StyleLearning._(trackCo, artistCo, stylePairs, addedFromSuggestions);
  }

  /// Quanto dois estilos andam juntos nas suas playlists (0..1).
  double stylePair(String a, String b) => _stylePairs[_pairKey(a, b)] ?? 0;

  /// Em quantas playlists as duas músicas aparecem juntas.
  int together(int a, int b) => _trackCo[a]?[b] ?? 0;

  /// Músicas que aparecem junto com [id] nas playlists, da mais frequente para a menos.
  List<(int, int)> companions(int id) {
    final m = _trackCo[id];
    if (m == null) return const [];
    return [for (final e in m.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// Artistas que aparecem junto com [artistKey] nas playlists: (chave, nº de playlists).
  List<(String, int)> artistCompanions(String artistKey) {
    final m = _artistCo[artistKey];
    if (m == null) return const [];
    return [for (final e in m.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2));
  }

  int artistsTogether(String a, String b) => _artistCo[a]?[b] ?? 0;
}

/// Tags do Last.fm de cada artista, buscadas uma vez por artista e guardadas em `artist_tags.json`.
/// Dão estilos às músicas que ainda não têm tags próprias.
class ArtistTagStore {
  final File file;
  Map<String, List<MusicTag>> _tags = {};
  bool _loaded = false;

  ArtistTagStore(String dataDir) : file = File('$dataDir${Platform.pathSeparator}artist_tags.json');

  static String key(String artist) => artist.trim().toLowerCase();

  void load() {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!file.existsSync()) return;
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _tags = raw.map((k, v) => MapEntry(k, [for (final m in (v as List)) MusicTag.fromJson((m as Map).cast<String, dynamic>())]));
    } catch (_) {
      _tags = {};
    }
  }

  /// Tags guardadas do artista; lista vazia = já procurou e não tem; null = ainda não procurou.
  List<MusicTag>? get(String artist) {
    load();
    return _tags[key(artist)];
  }

  bool has(String artist) => get(artist) != null;

  void put(String artist, List<MusicTag> tags) {
    load();
    _tags[key(artist)] = tags.take(15).toList();
  }

  Future<void> save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_tags.map((k, v) => MapEntry(k, [for (final t in v) t.toJson()]))));
    await tmp.rename(file.path);
  }
}
