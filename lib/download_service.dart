import 'dart:async';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
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

  int get doneCount => queue.where((e) => e.finished).length;
  int get okCount => queue.where((e) => e.status == YtStatus.done).length;
  bool get busy => running;

  Future<void>? _updating;

  /// Atualiza o yt-dlp uma vez por dia (o YouTube muda e versões antigas param de funcionar).
  Future<void> _maybeUpdate() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (app.prefs.getString('ytdlpUpdated') == today) return Future.value();
    return _updating ??= ytdlp.update().then((_) => app.prefs.setString('ytdlpUpdated', today)).catchError((_) => true).whenComplete(() => _updating = null);
  }

  void warmUp() => unawaited(_maybeUpdate());

  static String normalizeUrl(String raw) {
    var s = raw.trim();
    final m = RegExp(r'https?://\S+').firstMatch(s); // texto compartilhado com o link no meio
    if (m != null) s = m.group(0)!;
    if (!s.startsWith('http') && s.contains('.')) s = 'https://$s';
    return s;
  }

  static bool looksLikePlaylist(String url) => url.contains('list=') && !url.contains('watch?v=') || url.contains('/playlist');

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
      playlist = entries;
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
        }
      } catch (_) {
        // sem internet / MusicBrainz ocupado: fica o nome do vídeo
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
  }

  void toggle(YtEntry e) {
    e.selected = !e.selected;
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
          } catch (_) {}
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
    } catch (_) {
      // sem tags: o nome do arquivo e as pastas já dizem tudo
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
    final byName = <String, List<YtEntry>>{};
    for (final e in queue.where((e) => e.status == YtStatus.done)) {
      final name = _playlistOf.remove(e);
      if (name != null) byName.putIfAbsent(name, () => []).add(e);
    }
    for (final entry in byName.entries) {
      var pl = app.playlists.where((x) => x.name == entry.key).firstOrNull;
      if (pl == null) {
        await app.createPlaylist(entry.key);
        pl = app.playlists.where((x) => x.name == entry.key).firstOrNull;
      }
      if (pl == null) continue;
      for (final e in entry.value) {
        final t = app.tracks.where((t) => p.equals(t.path, e.savedPath!)).firstOrNull;
        if (t != null) await app.addToPlaylist(pl.id, t);
      }
    }
  }
}
