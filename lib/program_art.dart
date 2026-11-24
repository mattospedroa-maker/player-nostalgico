import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'error_log.dart';

/// Imagem de cada programa de podcast: o ícone do canal do YouTube de onde os episódios vieram.
///
/// Fica dentro da própria pasta do programa (`Podcasts/<Programa>/folder.jpg`, o nome que o Windows usa),
/// é baixada uma vez só, pequena (176 px, ~10–20 KB), e depois funciona offline. Se o usuário escolher
/// outra imagem, ela vira `folder.png` (reduzida para 256 px) e tem prioridade.
class ProgramArtService extends ChangeNotifier {
  final http.Client client;
  final SharedPreferences prefs;

  /// Não tenta de novo um programa que falhou antes disso (sem internet, vídeo removido...).
  final Duration retryAfter;

  ProgramArtService({required this.client, required this.prefs, this.retryAfter = const Duration(days: 3)});

  static const downloaded = 'folder.jpg';
  static const chosen = 'folder.png';
  static const _size = 176;

  final Map<String, File?> _known = {};
  final Set<String> _running = {};

  /// Imagem guardada do programa (escolhida pelo usuário > ícone do canal), ou null.
  File? fileFor(String programDir) {
    if (_known.containsKey(programDir)) return _known[programDir];
    for (final name in [chosen, downloaded]) {
      final f = File(p.join(programDir, name));
      if (f.existsSync()) return _known[programDir] = f;
    }
    return _known[programDir] = null;
  }

  void _changed(String programDir) {
    _known.remove(programDir);
    // a mesma pasta com outro conteúdo: o cache de imagens do Flutter guardaria a antiga
    PaintingBinding.instance.imageCache.clear();
    notifyListeners();
  }

  /// Baixa o ícone do canal se ainda não tiver (uma vez; em segundo plano). [videoId]: um episódio do programa.
  Future<bool> ensure(String programDir, {String? videoId, String? channelUrl, bool force = false}) async {
    if (!force && fileFor(programDir) != null) return false;
    if ((videoId == null || videoId.isEmpty) && (channelUrl == null || channelUrl.isEmpty)) return false;
    if (!_running.add(programDir)) return false;
    final key = 'programArtTried2:$programDir';
    try {
      final last = prefs.getInt(key) ?? 0;
      if (!force && DateTime.now().millisecondsSinceEpoch - last < retryAfter.inMilliseconds) return false;
      await prefs.setInt(key, DateTime.now().millisecondsSinceEpoch);
      String? url;
      var channel = channelUrl;
      if (videoId != null && videoId.isNotEmpty) {
        try {
          final html = await _page(Uri.https('www.youtube.com', '/watch', {'v': videoId}));
          if (html != null) {
            url = avatarFromWatchPage(html);
            final id = channelIdFromPage(html);
            if (id != null) channel ??= 'https://www.youtube.com/channel/$id';
          }
        } catch (e) {
          errorLog.info('Podcasts', 'A página do vídeo não abriu', e);
        }
      }
      // reserva: a página do canal (og:image = ícone do canal)
      if (url == null && channel != null && channel.isNotEmpty) {
        try {
          final html = await _page(Uri.parse(channel));
          if (html != null) url = avatarFromChannelPage(html);
        } catch (e) {
          errorLog.info('Podcasts', 'A página do canal não abriu', e);
        }
      }
      if (url == null) return false;
      final res = await client.get(Uri.parse(smallAvatar(url))).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.length < 500) return false;
      await File(p.join(programDir, downloaded)).writeAsBytes(res.bodyBytes, flush: true);
      _changed(programDir);
      return true;
    } catch (e) {
      errorLog.info('Podcasts', 'Não deu para baixar o ícone do canal', e);
      return false;
    } finally {
      _running.remove(programDir);
    }
  }

  /// Usa uma imagem escolhida pelo usuário: reduz para 256 px e grava como folder.png.
  Future<void> setCustom(String programDir, String imagePath) async {
    final codec = await ui.instantiateImageCodec(await File(imagePath).readAsBytes(), targetWidth: 256);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (png == null) throw const FormatException('Imagem ilegível');
    await File(p.join(programDir, chosen)).writeAsBytes(png.buffer.asUint8List(), flush: true);
    _changed(programDir);
  }

  /// Volta para o ícone do canal (apaga a imagem escolhida e baixa de novo se precisar).
  Future<void> resetCustom(String programDir, {String? videoId}) async {
    final f = File(p.join(programDir, chosen));
    if (f.existsSync()) await f.delete();
    _changed(programDir);
    if (fileFor(programDir) == null) await ensure(programDir, videoId: videoId, force: true);
  }

  // ---------------------------------------------------------------------------
  // Miniatura do vídeo de cada episódio (a imagem grande do Tocando agora)

  /// "Episódio.m4a" -> "Episódio.jpg" (ao lado, como o .json do resumo).
  static String episodeThumbPath(String audioPath) => '${p.withoutExtension(audioPath)}.jpg';

  final Map<String, File?> _thumbs = {};

  /// Miniatura do vídeo guardada para o episódio, ou null.
  File? episodeThumb(String audioPath) {
    if (_thumbs.containsKey(audioPath)) return _thumbs[audioPath];
    final f = File(episodeThumbPath(audioPath));
    return _thumbs[audioPath] = f.existsSync() ? f : null;
  }

  /// Baixa a miniatura do vídeo (uma vez): 1280x720 quando existe, senão 480x360. Devolve se tem agora.
  Future<bool> ensureEpisodeThumb(String audioPath, String? videoId) async {
    if (episodeThumb(audioPath) != null) return true;
    if (videoId == null || videoId.isEmpty || !_running.add(audioPath)) return false;
    final key = 'episodeThumbTried:$audioPath';
    try {
      final last = prefs.getInt(key) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - last < const Duration(hours: 12).inMilliseconds) return false;
      await prefs.setInt(key, DateTime.now().millisecondsSinceEpoch);
      for (final name in thumbNames) {
        final res = await client.get(Uri.https('i.ytimg.com', '/vi/$videoId/$name')).timeout(const Duration(seconds: 20));
        // o YouTube devolve uma imagem cinza pequena (~1 KB) quando aquele tamanho não existe
        if (res.statusCode != 200 || res.bodyBytes.length < 2048) continue;
        await File(episodeThumbPath(audioPath)).writeAsBytes(res.bodyBytes, flush: true);
        _thumbs.remove(audioPath);
        await prefs.remove(key);
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      errorLog.info('Podcasts', 'Não deu para baixar a miniatura do vídeo do episódio', e);
      return false;
    } finally {
      _running.remove(audioPath);
    }
  }

  /// Tamanhos tentados em ordem (o 1º é 16:9 sem faixas pretas; o último sempre existe).
  static const thumbNames = ['hq720.jpg', 'maxresdefault.jpg', 'hqdefault.jpg'];

  /// O episódio mudou de lugar: a miniatura vai junto.
  void episodeMoved(String from, String to) {
    try {
      final f = File(episodeThumbPath(from));
      if (f.existsSync()) f.renameSync(episodeThumbPath(to));
    } catch (e) {
      errorLog.info('Podcasts', 'Não deu para mover a miniatura junto com o episódio', e);
    }
    _thumbs.remove(from);
    _thumbs.remove(to);
  }

  /// Pasta foi renomeada/movida: o cache antigo não vale mais.
  void forget(String programDir) => _known.remove(programDir);

  Future<String?> _page(Uri uri) async {
    final res = await client
        .get(
          uri,
          headers: {
            'Accept-Language': 'pt-BR,pt;q=0.9',
            'Cookie': 'CONSENT=YES+1',
            // navegador de computador: a versão móvel (m.youtube.com) tem outro formato
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  /// Ícone do dono do vídeo dentro do `ytInitialData` da página (videoOwnerRenderer → thumbnail).
  static String? avatarFromWatchPage(String html) {
    final at = html.indexOf('"videoOwnerRenderer":{');
    if (at < 0) return null;
    final m = RegExp(r'"url":"((?:https:)?//yt\d\.(?:ggpht|googleusercontent)\.com/[^"]+)"').firstMatch(html.substring(at, (at + 4000).clamp(0, html.length)));
    if (m == null) return null;
    var u = m.group(1)!.replaceAll(r'&', '&').replaceAll(r'\/', '/');
    if (u.startsWith('//')) u = 'https:$u';
    return u;
  }

  /// Id do canal (UC...) na página do vídeo.
  static String? channelIdFromPage(String html) =>
      (RegExp(r'"externalChannelId":"(UC[\w-]{22})"').firstMatch(html) ?? RegExp(r'"channelId":"(UC[\w-]{22})"').firstMatch(html))?.group(1);

  /// Página do canal: a imagem de compartilhamento (og:image) é o ícone do canal.
  static String? avatarFromChannelPage(String html) {
    final m = RegExp(r'<meta property="og:image" content="([^"]+)"').firstMatch(html);
    final u = m?.group(1)?.replaceAll('&amp;', '&');
    return u != null && (u.contains('ggpht.com') || u.contains('googleusercontent.com')) ? u : null;
  }

  /// Pede ao servidor de imagens do Google a versão pequena (`=s176-...`).
  static String smallAvatar(String url) {
    if (RegExp(r'=s\d+').hasMatch(url)) return url.replaceFirst(RegExp(r'=s\d+'), '=s$_size');
    if (RegExp(r'=w\d+-h\d+').hasMatch(url)) return url.replaceFirst(RegExp(r'=w\d+-h\d+'), '=s$_size');
    if (url.contains('ggpht.com') || url.contains('googleusercontent.com')) return url.contains('=') ? url : '$url=s$_size';
    return url;
  }
}
