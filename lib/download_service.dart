import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'duplicates.dart';
import 'error_log.dart';
import 'metadata.dart';
import 'models.dart';
import 'organizer.dart';
import 'podcast_info.dart';
import 'podcasts.dart';
import 'youtube_names.dart';
import 'ytdlp.dart';

enum YtStatus { ready, queued, downloading, converting, updating, done, failed, canceled }

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

  /// Salvar como podcast (pasta Podcasts/Programa/) em vez de música. O app adivinha; dá para trocar.
  bool podcast = false;

  /// Nome do canal (vira o programa quando é podcast).
  final String channel;

  /// Informações que o yt-dlp devolveu (completas no "Um vídeo"; resumidas na playlist).
  Map<String, dynamic> rawInfo = const {};

  /// Situação do resumo do episódio (só podcast).
  SummaryStatus summary = SummaryStatus.none;

  /// Nomes adivinhados para música (voltam quando troca de Podcast para Música).
  late YtNames musicNames = names;

  YtEntry({required this.id, required this.url, required this.originalTitle, required this.names, this.thumbnail, this.durationSec, this.selected = true, this.channel = ''});

  /// Nomes de podcast: programa = canal, episódio = título inteiro do vídeo.
  YtNames get podcastNames {
    final program = channel.trim().isEmpty ? unknownProgram : channel.trim();
    return YtNames(artist: program, title: originalTitle.trim().isEmpty ? 'Sem título' : originalTitle.trim(), album: program);
  }

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
      channel: '${info['channel'] ?? info['uploader'] ?? ''}'.replaceAll(RegExp(r'\s*-\s*(topic|tópico)$', caseSensitive: false), '').trim(),
    );
    if (e.unavailable) e.selected = false;
    e.musicNames = e.names;
    e.rawInfo = info;
    if (looksLikePodcastVideo(info)) {
      e.podcast = true;
      e.names = e.podcastNames;
    }
    return e;
  }
}

/// Baixa o áudio de vídeos/playlists do YouTube (.m4a), corrige os nomes e guarda em Fonte/Artista/Álbum/Título.m4a.
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

  // ---------- plano B: yt-dlp velho ----------

  /// Atualizando o yt-dlp agora porque o YouTube mudou (para a tela mostrar).
  bool updatingYtDlp = false;

  /// Versão do yt-dlp antes da atualização forçada (para a tela: "versão 2026.08.12 → …").
  String? versionBefore;
  DateTime? _forcedAt;
  String? _forcedResult;
  Future<String?>? _forcing;

  /// Depois de uma atualização forçada, outra só depois disso (se ainda falha, a versão nova não resolve).
  static const forceAgainAfter = Duration(minutes: 15);

  /// Roda [run]; se falhar com cara de yt-dlp velho, atualiza na hora (mesmo que já tenha atualizado hoje)
  /// e tenta de novo uma vez. [entry] mostra "Atualizando yt-dlp" na fila enquanto isso.
  Future<T> withFreshYtDlp<T>(Future<T> Function() run, {YtEntry? entry}) async {
    try {
      return await run();
    } on YtDlpException catch (err) {
      if (!err.outdated || _cancelAll) rethrow;
      final r = await _forceUpdate(entry);
      if (r == null) {
        throw const YtDlpException('O YouTube mudou e o yt-dlp precisa de atualização, mas não deu para atualizar agora '
            '(sem internet ou o GitHub não respondeu). Tente de novo mais tarde.');
      }
      if (r != 'DONE') throw const YtDlpException(stillBroken);
      if (entry != null) entry.status = YtStatus.downloading;
      notifyListeners();
      try {
        return await run();
      } on YtDlpException catch (again) {
        if (again.outdated) throw const YtDlpException(stillBroken);
        rethrow;
      }
    }
  }

  static const stillBroken = 'O YouTube mudou e nem a versão mais nova do yt-dlp funciona ainda. '
      'Costuma sair conserto em poucos dias; tente de novo depois.';

  /// Atualiza o yt-dlp agora. "DONE" = atualizou; "ALREADY_UP_TO_DATE" = já era a mais nova; null = não deu.
  Future<String?> _forceUpdate(YtEntry? entry) {
    final at = _forcedAt;
    if (at != null && DateTime.now().difference(at) < forceAgainAfter) {
      // acabou de atualizar e ainda falha: a versão nova também não resolve
      return Future.value(_forcedResult == null ? null : 'ALREADY_UP_TO_DATE');
    }
    return _forcing ??= () async {
      final prev = entry?.status;
      entry?.status = YtStatus.updating;
      updatingYtDlp = true;
      versionBefore = await ytdlp.version().catchError((Object _) => '');
      notifyListeners();
      try {
        final r = await ytdlp.update();
        final after = await ytdlp.version().catchError((Object _) => '');
        await app.prefs.setString('ytdlpUpdated', DateTime.now().toIso8601String().substring(0, 10));
        errorLog.info(
            'YouTube',
            r == 'DONE'
                ? 'O YouTube mudou: yt-dlp atualizado na hora (${versionBefore ?? '?'} → $after) e o download tentado de novo'
                : 'O YouTube mudou, mas o yt-dlp já estava na versão mais nova ($after)');
        _forcedResult = r;
        return r;
      } catch (e) {
        errorLog.warn('YouTube', 'O yt-dlp precisa de atualização, mas não deu para atualizar', error: e, balloon: true);
        _forcedResult = null;
        return null;
      } finally {
        _forcedAt = DateTime.now();
        updatingYtDlp = false;
        if (entry != null && entry.status == YtStatus.updating) entry.status = prev ?? YtStatus.downloading;
        notifyListeners();
      }
    }()
        .whenComplete(() => _forcing = null);
  }

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
    // álbum do YT Music aberto pela página dele (music.youtube.com/browse/MPREb…) também é uma lista
    if (u.pathSegments.length > 1 && u.pathSegments.first == 'browse' && RegExp(r'^(MPREb|VL)').hasMatch(u.pathSegments[1])) {
      return LinkKind.playlist;
    }
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
      final info = await withFreshYtDlp(() => ytdlp.info(url, playlist: false));
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
      final info = await withFreshYtDlp(() => ytdlp.info(url, playlist: true));
      final entries = (info['entries'] as List?)?.whereType<Map>().map((m) => YtEntry.fromInfo(m.cast<String, dynamic>())).toList() ?? [];
      if (entries.isEmpty) throw const YtDlpException('Não achei vídeos nesse link. É mesmo uma playlist?');
      playlistTitle = '${info['title'] ?? 'Playlist'}';
      // playlist de podcast (nome ou link do YouTube Music): todos os vídeos viram episódios
      if (hasPodcastWords(playlistTitle!) || url.contains('/podcast')) {
        for (final e in entries) {
          _applyKind(e, true);
        }
      }
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
      if (e.podcast) continue; // episódio não tem álbum no MusicBrainz
      if (e.edited || e.unavailable || e.names.album != unknownAlbum) continue;
      e.lookingUp = true;
      notifyListeners();
      try {
        final n = e.names;
        final hint = n.artist == unknownArtist ? null : n.artist;
        final found = await mb.lookupSmart(n.title, artist: hint, titleOnlyMinScore: 101);
        if (found != null && !e.edited && !e.podcast && (hint == null || _sameArtist(found.artist, hint))) {
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

  /// Troca entre Música e Podcast (um vídeo).
  void setPodcast(YtEntry e, bool v) {
    if (e.podcast == v) return;
    _applyKind(e, v);
    markExisting([e], uncheck: !identical(e, single));
    notifyListeners();
    if (!v) unawaited(_lookupAlbums([e]));
  }

  /// Troca todos os vídeos da playlist entre Música e Podcast.
  void setPlaylistPodcast(bool v) {
    for (final e in playlist) {
      _applyKind(e, v);
    }
    markExisting(playlist, uncheck: true);
    notifyListeners();
    if (!v) unawaited(_lookupAlbums(playlist));
  }

  bool get playlistIsPodcast => playlist.isNotEmpty && playlist.every((e) => e.podcast);

  void _applyKind(YtEntry e, bool podcast) {
    if (e.podcast == podcast) return;
    if (!e.podcast) e.musicNames = e.names;
    e.podcast = podcast;
    e.names = podcast ? e.podcastNames : e.musicNames;
    e.edited = false;
  }

  void edit(YtEntry e, {String? artist, String? title, String? album}) {
    e.names = e.names.copyWith(artist: artist, title: title, album: album);
    e.edited = true;
    final before = e.existingPath;
    markExisting([e], uncheck: !identical(e, single));
    if (before != e.existingPath) notifyListeners();
  }

  // ---------- repetidas ----------

  /// Vídeos do YouTube já baixados: id -> caminho do arquivo de áudio.
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
    final episodes = {for (final t in app.podcasts) '${t.artist.toLowerCase()}|${t.title.toLowerCase()}': t.path};
    final ids = _downloaded;
    for (final e in entries) {
      if (e.unavailable) continue;
      String? found;
      final byId = ids[e.id];
      if (byId != null && File(byId).existsSync()) found = byId;
      if (found == null && e.podcast) found = episodes['${e.names.artist.toLowerCase()}|${e.names.title.toLowerCase()}'];
      if (found == null && !e.podcast && usableTitle(e.names.title)) {
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
    if (!running) {
      unawaited(_runQueue());
    } else {
      _pool?.poke(); // um dos dois downloads pode estar livre
    }
  }

  Future<void> cancelAll() async {
    _cancelAll = true;
    for (final e in queue) {
      if (e.status == YtStatus.queued) e.status = YtStatus.canceled;
      if (e.status == YtStatus.downloading || e.status == YtStatus.converting) await ytdlp.cancel(e.id);
    }
    notifyListeners();
  }

  /// Downloads ao mesmo tempo. Um terceiro não ajuda: yt-dlp, FFmpeg e disco disputam o mesmo celular.
  static const maxParallel = 2;
  ParallelQueue<YtEntry>? _pool;

  /// Próximo da fila (já marcado como baixando, para o outro download não pegar o mesmo).
  YtEntry? _takeNext() {
    if (_cancelAll) return null;
    final e = queue.where((e) => e.status == YtStatus.queued).firstOrNull;
    if (e == null) return null;
    e.status = YtStatus.downloading;
    notifyListeners();
    return e;
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _runQueue() async {
    final root = app.sourceRoot;
    if (root == null) return;
    running = true;
    _cancelAll = false;
    notifyListeners();
    final tmpBase = p.join((await getTemporaryDirectory()).path, 'youtube');
    try {
      await _maybeUpdate();
      final pool = _pool = ParallelQueue<YtEntry>(maxParallel, _takeNext, (e) => _downloadOne(e, tmpBase, root));
      await pool.run();
    } finally {
      for (final e in queue) {
        if (e.status == YtStatus.queued) e.status = YtStatus.canceled;
      }
      _pool = null;
      running = false;
      final ok = okCount;
      final eps = queue.where((e) => e.status == YtStatus.done && e.podcast).length;
      final songs = ok - eps;
      final failed = queue.where((e) => e.status == YtStatus.failed).length;
      lastSummary = ok == 0 && failed == 0
          ? null
          : '${[
              if (songs > 0) '$songs ${songs == 1 ? 'música baixada e organizada' : 'músicas baixadas e organizadas'} em Artista/Álbum',
              if (eps > 0) '$eps ${eps == 1 ? 'episódio salvo' : 'episódios salvos'} em Podcasts/Programa',
              if (failed > 0) '$failed com erro',
            ].join(' · ')}.';
      notifyListeners();
      if (lastSummary != null) unawaited(ytdlp.notify('Downloads do YouTube', lastSummary!, done: true));
      if (ok > 0) await _addToLibrary();
    }
  }

  /// Baixa um vídeo, grava as tags e guarda na Biblioteca. Nunca lança: o erro fica no item.
  Future<void> _downloadOne(YtEntry e, String tmpBase, String root) async {
    final tmp = p.join(tmpBase, e.id.isEmpty ? '${DateTime.now().millisecondsSinceEpoch}' : e.id);
    // podcast: descrição, capítulos, legenda e resumo da IA andam junto com o download do áudio
    final Future<EpisodeInfo>? extra = e.podcast ? _episodeInfo(e) : null;
    try {
      // plano B: se o YouTube mudou, atualiza o yt-dlp e tenta esta música de novo.
      // O AAC é copiado como vem; só sem AAC (Opus) converte, e aí o podcast fica em 96k (fala não precisa de 192k).
      final audio = await withFreshYtDlp(entry: e, () => ytdlp.downloadAudio(e.url, tmp, id: e.id, fallbackBitrate: e.podcast ? '96k' : '192k',
          onProgress: (prog, line) {
        // "convertendo" só quando o FFmpeg converte de verdade (plano B do Opus); a cópia do AAC segue como download
        if (YtDlp.isConvertingLine(line)) {
          e.status = YtStatus.converting;
        } else if (line.startsWith('[download]')) {
          e.status = YtStatus.downloading;
        }
        if (prog >= 0) e.progress = (prog / 100).clamp(0, 1);
        notifyListeners();
        if (DateTime.now().difference(_lastNotify).inMilliseconds > 1000) {
          _lastNotify = DateTime.now();
          unawaited(ytdlp.notify('Baixando ${doneCount + 1} de ${queue.length}', e.names.title, progress: prog.round()));
        }
      }));
      e.savedPath = e.podcast ? await _saveEpisode(File(audio), e.names, root) : await _saveToLibrary(File(audio), e.names, root);
      e.sizeBytes = File(e.savedPath!).lengthSync();
      await _rememberDownload(e.id, e.savedPath!);
      e.status = YtStatus.done;
      e.progress = 1;
      if (extra != null) {
        final path = e.savedPath!;
        unawaited(extra.then((info) async {
          await app.podcastInfo.save(path, info);
          e.summary = info.status;
          notifyListeners();
        }));
      }
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

  /// Grava as tags com o nome corrigido e move para Fonte/Artista/Álbum/Título.m4a.
  Future<String> _saveToLibrary(File audio, YtNames n, String root) async {
    await _tag(audio, n.title, n.artist, n.album, podcast: false);
    final target = _freePath(targetPathFor(root, audio.path, n.artist, n.album, title: n.title));
    await Directory(p.dirname(target)).create(recursive: true);
    await Organizer.moveFile(audio, target);
    return target;
  }

  /// Grava as tags fora da tela (o arquivo inteiro é relido e regravado; num episódio de 3h isso travaria a interface).
  Future<void> _tag(File audio, String title, String artist, String album, {required bool podcast}) async {
    final path = audio.path;
    try {
      await Isolate.run(() => writeDownloadTags(path, title: title, artist: artist, album: album, podcast: podcast));
    } catch (e) {
      // as tags que o yt-dlp gravou (título e canal do vídeo) continuam no arquivo; o nome e as pastas dizem o resto
      errorLog.warn('YouTube', 'Não deu para gravar as tags em "$title"', error: e);
    }
  }

  /// "Título.m4a" já existe: "Título (2).m4a", "Título (3).m4a"...
  static String _freePath(String target) {
    final base = p.withoutExtension(target), ext = p.extension(target);
    var out = target;
    for (var k = 2; File(out).existsSync(); k++) {
      out = '$base ($k)$ext';
    }
    return out;
  }

  /// Informações do episódio: pega o JSON completo do vídeo (a playlist só traz o resumido) e monta o resumo.
  /// Nunca falha: sem internet/chave/legenda, devolve o que deu (e o status explica).
  Future<EpisodeInfo> _episodeInfo(YtEntry e) async {
    try {
      var yt = e.rawInfo;
      if (!yt.containsKey('automatic_captions') && !yt.containsKey('description')) {
        yt = await ytdlp.info(e.url, playlist: false);
      }
      return await app.podcastInfo.build(yt, title: e.names.title, program: e.names.artist, onStatus: (s) {
        e.summary = s;
        notifyListeners();
      });
    } catch (err) {
      errorLog.info('Podcasts', 'Não deu para buscar as informações do episódio "${e.names.title}"', err);
      e.summary = SummaryStatus.failed;
      notifyListeners();
      return EpisodeInfo(videoId: e.id, url: e.url, status: SummaryStatus.failed, error: '$err');
    }
  }

  /// Vídeo do YouTube de onde veio o arquivo (null = não foi baixado pelo app).
  String? youtubeIdFor(String path) {
    for (final en in _downloaded.entries) {
      if (p.equals(en.value, path)) return en.key;
    }
    return null;
  }

  /// Episódio de podcast: tags com programa/título inteiro e vai para Podcasts/Programa/Episódio.m4a.
  Future<String> _saveEpisode(File audio, YtNames n, String root) async {
    await _tag(audio, n.title, n.artist, n.artist, podcast: true);
    final target = _freePath(podcastTargetPath(root, n.artist, '${safeFolderName(n.title)}${p.extension(audio.path).toLowerCase()}'));
    await Directory(p.dirname(target)).create(recursive: true);
    await Organizer.moveFile(audio, target);
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
      if (e.podcast) continue; // podcast nunca entra em playlist de músicas
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

/// Grava título, artista, álbum e gênero no arquivo baixado. No .m4a vão nos átomos do MP4 (©nam, ©ART, ©alb, ©gen),
/// pela escrita MP4 do audio_metadata_reader; no .mp3, em ID3. Música: o gênero "Music" que o yt-dlp põe (categoria do
/// vídeo) sai, o gênero real vem do MusicBrainz/Last.fm. Podcast: gênero "Podcast".
/// Lança erro se as tags não ficarem gravadas (conferido relendo o arquivo).
void writeDownloadTags(String path, {required String title, required String artist, required String album, bool podcast = false}) {
  final file = File(path);
  final genre = podcast ? 'Podcast' : (FileMetadataReader.readTagsSync(path)?.genre ?? '');
  updateMetadata(file, (m) {
    m.setTitle(title);
    m.setArtist(artist);
    m.setAlbum(album);
    m.setGenres(genre.isEmpty ? const [] : [genre]);
    // o yt-dlp grava a data de envio (20261121) em ©day; a leitura do pacote vira um ano absurdo e a escrita
    // gravaria lixo ("-198271"). Data de envio não é ano de lançamento: sai.
    if (m is Mp4Metadata) {
      final y = m.year?.year;
      if (y != null && (y < 1000 || y > 9999)) m.year = null;
    }
  });
  final back = FileMetadataReader.readTagsSync(path);
  if (back == null || back.title != title.trim() || back.artist != artist.trim()) {
    throw StateError('as tags não ficaram gravadas em ${p.basename(path)}');
  }
}

/// Fila que roda no máximo [limit] trabalhos ao mesmo tempo. [next] entrega o próximo item (null = acabou por ora);
/// quando um trabalho termina, a vaga é preenchida de novo. [poke] chama mais itens que entraram depois.
class ParallelQueue<T> {
  final int limit;
  final T? Function() next;
  final Future<void> Function(T item) work;
  ParallelQueue(this.limit, this.next, this.work);

  int _active = 0;
  final _done = Completer<void>();

  /// Trabalhos rodando agora.
  int get active => _active;

  /// Começa e termina quando não houver mais nada rodando nem na fila.
  Future<void> run() {
    poke();
    return _done.future;
  }

  void poke() {
    if (_done.isCompleted) return;
    while (_active < limit) {
      final item = next();
      if (item == null) break;
      _active++;
      Future<void>.sync(() => work(item)).catchError((Object e) {
        errorLog.warn('YouTube', 'Um download parou com erro inesperado', error: e);
      }).whenComplete(() {
        _active--;
        poke();
      });
    }
    if (_active == 0 && !_done.isCompleted) _done.complete();
  }
}
