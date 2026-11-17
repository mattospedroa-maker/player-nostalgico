import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'duplicates.dart';
import 'error_log.dart';
import 'models.dart';
import 'organizer.dart';
import 'youtube_names.dart';
import 'ytdlp.dart';

enum YtStatus { ready, queued, downloading, converting, done, failed, canceled }

/// Um vídeo da tela "Baixar do YouTube".
class YtEntry {
  final String id;
  final String url;
  final String originalTitle;
  final String? thumbnail;
  final int? durationSec;
  YtNames names;

  /// O usuário mexeu no nome: a busca de álbum não troca mais.
  bool edited = false;
  bool lookingUp = false;
  bool selected;
  YtStatus status = YtStatus.ready;
  double progress = 0;
  String? error;
  String? savedPath;
  int? sizeBytes;

  /// Caminho da música igual que já está na Biblioteca (null = nova).
  String? existingPath;

  /// O usuário marcou/desmarcou à mão: a detecção de repetidas não mexe mais.
  bool userToggled = false;

  YtEntry({required this.id, required this.url, required this.originalTitle, required this.names, this.thumbnail, this.durationSec, this.selected = true});

  bool get unavailable => originalTitle == '[Private video]' || originalTitle == '[Deleted video]';
  bool get finished => status == YtStatus.done || status == YtStatus.failed || status == YtStatus.canceled;

  static YtEntry fromInfo(Map<String, dynamic> info) {
    final id = '${info['id'] ?? ''}';
    String? thumb = info['thumbnail'] as String?;
    final thumbs = info['thumbnails'];
    if (thumb == null && thumbs is List && thumbs.isNotEmpty) thumb = (thumbs.last as Map)['url'] as String?;
    final url = (info['webpage_url'] ?? info['url'] ?? 'https://www.youtube.com/watch?v=$id').toString();
    final e = YtEntry(
      id: id,
      url: url.startsWith('http') ? url : 'https://www.youtube.com/watch?v=$id',
      originalTitle: '${info['title'] ?? ''}',
      thumbnail: thumb,
      durationSec: (info['duration'] as num?)?.round(),
      names: guessYoutubeNames(info),
    );
    if (e.unavailable) e.selected = false;
    return e;
  }
}

/// Baixa vídeos/playlists do YouTube em .mp3, corrige os nomes e guarda em Fonte/Artista/Álbum/Título.mp3.
/// Fica fora da tela: dá para sair e continuar usando o app enquanto baixa.
enum LinkKind { video, playlist, both, unknown }

class DownloadService extends ChangeNotifier {
  final AppState app;
  final YtDlp ytdlp;
  final MusicBrainzClient mb;
  DownloadService(this.app, {YtDlp? ytdlp, MusicBrainzClient? mb})
      : ytdlp = ytdlp ?? YtDlp(),
        mb = mb ?? MusicBrainzClient();

  // aba "Um vídeo"
  YtEntry? single;
  bool loadingSingle = false;
  String? singleError;

  // aba "Playlist"
  String? playlistTitle;
  List<YtEntry> playlist = const [];
  bool loadingPlaylist = false;
  String? playlistError;
  bool makePlaylist = false;

  // fila de download
  final List<YtEntry> queue = [];
  bool running = false;
  bool _cancelAll = false;
  String? lastSummary;
  final Map<YtEntry, String> _playlistOf = {};
  final Map<String, List<String>> _existingFor = {};

  int get doneCount => queue.where((e) => e.finished).length;
  int get okCount => queue.where((e) => e.status == YtStatus.done).length;
  bool get busy => running;

  Future<void>? _updating;

  /// Atualiza o yt-dlp uma vez por dia (o YouTube muda e versões antigas param de funcionar).
  Future<void> _maybeUpdate() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (app.prefs.getString('ytdlpUpdated') == today) return Future.value();
    return _updating ??= ytdlp.update().then((_) => app.prefs.setString('ytdlpUpdated', today)).catchError((Object e) {
      // o download tenta com a versão que já tem; se o YouTube mudou, ele falha e diz o motivo
      errorLog.warn('YouTube', 'Não deu para atualizar o yt-dlp', error: e);
      return true;
    }).whenComplete(() => _updating = null);
  }

  void warmUp() => unawaited(_maybeUpdate());

  static String normalizeUrl(String raw) {
    var s = raw.trim();
    final m = RegExp(r'https?://\S+').firstMatch(s); // texto compartilhado com o link no meio
    if (m != null) s = m.group(0)!;
    if (!s.startsWith('http') && s.contains('.')) s = 'https://$s';
    return s;
  }

  static bool looksLikePlaylist(String url) => linkKind(url) == LinkKind.playlist;

  /// O que o link aponta: um vídeo, uma playlist, ou um vídeo aberto de dentro de uma playlist (os dois).
  /// Os "Mix" automáticos do YouTube (list=RD…) não têm fim, então contam como vídeo.
  static LinkKind linkKind(String raw) {
    final u = Uri.tryParse(normalizeUrl(raw));
    if (u == null || u.host.isEmpty) return LinkKind.unknown;
    final list = u.queryParameters['list'] ?? '';
    final hasList = list.isNotEmpty && !list.startsWith('RD');
    final hasVideo = (u.queryParameters['v'] ?? '').isNotEmpty ||
        u.host.endsWith('youtu.be') && u.pathSegments.isNotEmpty ||
        u.pathSegments.isNotEmpty && const {'shorts', 'live', 'embed'}.contains(u.pathSegments.first);
    if (u.pathSegments.isNotEmpty && u.pathSegments.first == 'playlist') return hasList ? LinkKind.playlist : LinkKind.unknown;
    if (hasVideo && hasList) return LinkKind.both;
    if (hasList) return LinkKind.playlist;
    return LinkKind.video;
  }

  Future<void> fetchSingle(String raw) async {
    final url = normalizeUrl(raw);
    if (url.isEmpty) return;
    loadingSingle = true;
    singleError = null;
    single = null;
    notifyListeners();
    try {
      await _maybeUpdate();
      final info = await ytdlp.info(url, playlist: false);
      single = YtEntry.fromInfo(info);
      markExisting([single!], uncheck: false);
      notifyListeners();
      unawaited(_lookupAlbums([single!]));
    } catch (e) {
      singleError = '$e';
    } finally {
      loadingSingle = false;
      notifyListeners();
    }
  }

  Future<void> fetchPlaylist(String raw) async {
    final url = normalizeUrl(raw);
    if (url.isEmpty) return;
    loadingPlaylist = true;
    playlistError = null;
    playlist = const [];
    playlistTitle = null;
    notifyListeners();
    try {
      await _maybeUpdate();
      final info = await ytdlp.info(url, playlist: true);
      final entries = (info['entries'] as List?)?.whereType<Map>().map((m) => YtEntry.fromInfo(m.cast<String, dynamic>())).toList() ?? [];
      if (entries.isEmpty) throw const YtDlpException('Não achei vídeos nesse link. É mesmo uma playlist?');
      playlistTitle = '${info['title'] ?? 'Playlist'}';
      playlist = _dropRepeatedInList(entries);
      markExisting(playlist, uncheck: true);
      notifyListeners();
      unawaited(_lookupAlbums(entries));
    } catch (e) {
      playlistError = '$e';
    } finally {
      loadingPlaylist = false;
      notifyListeners();
    }
  }

  /// Procura o álbum (e a grafia certa) no MusicBrainz, como o "Buscar novas músicas".
  Future<void> _lookupAlbums(List<YtEntry> entries) async {
    for (final e in entries) {
      if (e.edited || e.unavailable || e.names.album != unknownAlbum) continue;
      e.lookingUp = true;
      notifyListeners();
      try {
        final n = e.names;
        final hint = n.artist == unknownArtist ? null : n.artist;
        final found = await mb.lookup(n.title, artist: hint);
        if (found != null && !e.edited && (hint == null || _sameArtist(found.artist, hint))) {
          e.names = YtNames(artist: found.artist, title: found.title, album: found.album);
          markExisting([e], uncheck: !identical(e, single));
        }
      } catch (err) {
        // sem internet / MusicBrainz ocupado: fica o nome do vídeo
        errorLog.info('YouTube', 'MusicBrainz não respondeu (álbum do vídeo)', err);
      }
      e.lookingUp = false;
      notifyListeners();
    }
  }

  static String _n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9À-ɏ぀-ヿ一-鿿]+'), '');
  static bool _sameArtist(String a, String b) => _n(a).contains(_n(b)) || _n(b).contains(_n(a));

  void edit(YtEntry e, {String? artist, String? title, String? album}) {
    e.names = e.names.copyWith(artist: artist, title: title, album: album);
    e.edited = true;
    final before = e.existingPath;
    markExisting([e], uncheck: !identical(e, single));
    if (before != e.existingPath) notifyListeners();
  }

  // ---------- repetidas ----------

  /// Vídeos do YouTube já baixados: id -> caminho do .mp3.
  Map<String, String> get _downloaded {
    try {
      final raw = app.prefs.getString('ytBaixados');
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (e) {
      errorLog.warn('YouTube', 'A lista de vídeos já baixados estava ilegível', error: e);
      return {};
    }
  }

  Future<void> _rememberDownload(String id, String path) async {
    if (id.isEmpty) return;
    final m = _downloaded..[id] = path;
    await app.prefs.setString('ytBaixados', jsonEncode(m));
  }

  /// Procura cada vídeo na Biblioteca (mesmo vídeo já baixado, ou mesmo artista + título).
  /// Na playlist, os que já existem ficam desmarcados (a não ser que o usuário tenha mexido).
  void markExisting(List<YtEntry> entries, {required bool uncheck}) {
    final byBase = <String, List<Track>>{};
    for (final t in app.tracks) {
      if (usableTitle(t.title)) byBase.putIfAbsent(baseKey(t), () => []).add(t);
    }
    final ids = _downloaded;
    for (final e in entries) {
      if (e.unavailable) continue;
      String? found;
      final byId = ids[e.id];
      if (byId != null && File(byId).existsSync()) found = byId;
      if (found == null && usableTitle(e.names.title)) {
        final artist = e.names.artist == unknownArtist ? '' : e.names.artist;
        final key = songKey(artist, e.names.title).split('|').take(2).join('|');
        final (_, version) = songParts(e.names.title, album: e.names.album);
        final dur = (e.durationSec ?? 0) * 1000;
        found = (byBase[key] ?? const <Track>[])
            .where((t) => versionOf(t) == version)
            // versão ao vivo/remix: basta ter uma do mesmo tipo; original: precisa ser a mesma gravação
            .where((t) => version.isNotEmpty || dur <= 0 || t.durationMs <= 0 || (t.durationMs - dur).abs() <= 15000)
            .map((t) => t.path)
            .firstOrNull;
      }
      e.existingPath = found;
      if (uncheck && !e.userToggled) e.selected = found == null;
    }
  }

  /// Mesma música duas vezes na playlist: fica só a primeira marcada.
  List<YtEntry> _dropRepeatedInList(List<YtEntry> entries) {
    final seen = <String>{};
    for (final e in entries) {
      if (!seen.add(songKey(e.names.artist, e.names.title))) e.selected = false;
    }
    return entries;
  }

  int get playlistExistingCount => playlist.where((e) => e.existingPath != null).length;

  void toggle(YtEntry e) {
    e.selected = !e.selected;
    e.userToggled = true;
    notifyListeners();
  }

  void selectAll(bool v) {
    for (final e in playlist) {
      if (!e.unavailable) e.selected = v;
    }
    notifyListeners();
  }

  void setMakePlaylist(bool v) {
    makePlaylist = v;
    notifyListeners();
  }

  /// Coloca na fila e começa a baixar.
  void enqueue(List<YtEntry> entries, {String? playlistName}) {
    if (!running) {
      queue.removeWhere((e) => e.finished);
      lastSummary = null;
    }
    for (final e in entries) {
      if (queue.contains(e)) continue;
      e
        ..status = YtStatus.queued
        ..progress = 0
        ..error = null;
      queue.add(e);
      if (playlistName != null) _playlistOf[e] = playlistName;
    }
    // músicas da playlist que já estavam na Biblioteca também entram na playlist do app
    if (playlistName != null) {
      _existingFor[playlistName] = [
        for (final e in playlist)
          if (!entries.contains(e) && e.existingPath != null) e.existingPath!,
      ];
    }
    notifyListeners();
    if (!running) unawaited(_runQueue());
  }

  Future<void> cancelAll() async {
    _cancelAll = true;
    for (final e in queue) {
      if (e.status == YtStatus.queued) e.status = YtStatus.canceled;
      if (e.status == YtStatus.downloading || e.status == YtStatus.converting) await ytdlp.cancel(e.id);
    }
    notifyListeners();
  }

  Future<void> _runQueue() async {
    final root = app.sourceRoot;
    if (root == null) return;
    running = true;
    _cancelAll = false;
    notifyListeners();
    final tmpBase = p.join((await getTemporaryDirectory()).path, 'youtube');
    DateTime lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _maybeUpdate();
      while (true) {
        final i = queue.indexWhere((e) => e.status == YtStatus.queued);
        if (i < 0 || _cancelAll) break;
        final e = queue[i];
        e.status = YtStatus.downloading;
        notifyListeners();
        final tmp = p.join(tmpBase, e.id.isEmpty ? '${DateTime.now().millisecondsSinceEpoch}' : e.id);
        try {
          final mp3 = await ytdlp.downloadMp3(e.url, tmp, id: e.id, onProgress: (prog, line) {
            final converting = line.contains('ExtractAudio') || line.contains('EmbedThumbnail') || line.contains('Metadata');
            e.status = converting ? YtStatus.converting : YtStatus.downloading;
            if (prog >= 0) e.progress = (prog / 100).clamp(0, 1);
            notifyListeners();
            if (DateTime.now().difference(lastNotify).inMilliseconds > 1000) {
              lastNotify = DateTime.now();
              unawaited(ytdlp.notify('Baixando ${doneCount + 1} de ${queue.length}', e.names.title, progress: prog.round()));
            }
          });
          e.status = YtStatus.converting;
          notifyListeners();
          e.savedPath = await _saveToLibrary(File(mp3), e.names, root);
          e.sizeBytes = File(e.savedPath!).lengthSync();
          await _rememberDownload(e.id, e.savedPath!);
          e.status = YtStatus.done;
          e.progress = 1;
        } on YtDlpException catch (err) {
          e.status = _cancelAll || err.message == 'Cancelado' ? YtStatus.canceled : YtStatus.failed;
          e.error = err.message;
        } catch (err) {
          e.status = YtStatus.failed;
          e.error = '$err';
        } finally {
          try {
            Directory(tmp).deleteSync(recursive: true);
          } catch (err) {
            errorLog.info('YouTube', 'Não deu para limpar a pasta temporária do download', err);
          }
        }
        notifyListeners();
      }
    } finally {
      for (final e in queue) {
        if (e.status == YtStatus.queued) e.status = YtStatus.canceled;
      }
      running = false;
      final ok = okCount;
      final failed = queue.where((e) => e.status == YtStatus.failed).length;
      lastSummary = ok == 0 && failed == 0
          ? null
          : '$ok ${ok == 1 ? 'música baixada' : 'músicas baixadas'} em MP3 e organizadas em Artista/Álbum'
              '${failed > 0 ? ' · $failed com erro' : ''}.';
      notifyListeners();
      if (lastSummary != null) unawaited(ytdlp.notify('Downloads do YouTube', lastSummary!, done: true));
      if (ok > 0) await _addToLibrary();
    }
  }

  /// Grava as tags com o nome corrigido e move para Fonte/Artista/Álbum/Título.mp3.
  Future<String> _saveToLibrary(File mp3, YtNames n, String root) async {
    try {
      updateMetadata(mp3, (m) {
        m.setTitle(n.title);
        m.setArtist(n.artist);
        m.setAlbum(n.album);
      });
    } catch (e) {
      // sem tags: o nome do arquivo e as pastas já dizem tudo
      errorLog.warn('YouTube', 'Não deu para gravar as tags em "${n.title}"', error: e);
    }
    var target = targetPathFor(root, mp3.path, n.artist, n.album, title: n.title);
    final base = p.withoutExtension(target);
    for (var k = 2; File(target).existsSync(); k++) {
      target = '$base ($k).mp3';
    }
    await Directory(p.dirname(target)).create(recursive: true);
    await Organizer.moveFile(mp3, target);
    return target;
  }

  /// Relê a pasta para as novas aparecerem e monta a playlist, se pedido.
  Future<void> _addToLibrary() async {
    while (app.scanning) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await app.rescan();
    final byName = <String, List<String>>{};
    for (final e in queue.where((e) => e.status == YtStatus.done)) {
      final name = _playlistOf.remove(e);
      if (name != null) byName.putIfAbsent(name, () => []).add(e.savedPath!);
    }
    for (final name in byName.keys.toList()) {
      byName[name]!.insertAll(0, _existingFor.remove(name) ?? const []);
    }
    for (final entry in byName.entries) {
      var pl = app.playlists.where((x) => x.name == entry.key).firstOrNull;
      if (pl == null) {
        await app.createPlaylist(entry.key);
        pl = app.playlists.where((x) => x.name == entry.key).firstOrNull;
      }
      if (pl == null) continue;
      final already = (await app.db.playlistTracks(pl.id)).map((t) => t.id).toSet();
      for (final path in entry.value) {
        final t = app.tracks.where((t) => p.equals(t.path, path)).firstOrNull;
        if (t != null && !already.contains(t.id)) {
          already.add(t.id);
          await app.addToPlaylist(pl.id, t);
        }
      }
    }
  }
}
