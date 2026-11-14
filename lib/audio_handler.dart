import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

/// Erro ao ligar a notificação de mídia (aparece no Tocando agora, para dar para corrigir).
String? audioInitError;

/// Liga o player à notificação e à tela de bloqueio do Android:
/// botões ♥ ⏮ ⏯ ⏭ e a arte com o GIF que está passando.
class PlayerAudioHandler extends BaseAudioHandler with SeekHandler {
  AudioPlayer? player;
  Future<void> Function()? onNext;
  Future<void> Function()? onPrevious;
  Future<void> Function()? onFavorite;
  bool favorite = false;

  @override
  Future<void> play() async => player?.play();

  @override
  Future<void> pause() async => player?.pause();

  @override
  Future<void> seek(Duration position) async => player?.seek(position);

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> stop() async {
    await player?.pause();
    await super.stop();
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'favorite') await onFavorite?.call();
  }

  MediaControl get _favControl => MediaControl.custom(
        androidIcon: favorite ? 'drawable/ic_fav_on' : 'drawable/ic_fav_off',
        label: favorite ? 'Descurtir' : 'Curtir',
        name: 'favorite',
      );

  /// Manda o estado atual (tocando, posição, botões) para o Android.
  void broadcast() {
    final pl = player;
    if (pl == null) return;
    final playing = pl.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        _favControl,
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [1, 2, 3],
      processingState: switch (pl.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: playing,
      updatePosition: pl.position,
      bufferedPosition: pl.bufferedPosition,
      speed: pl.speed,
      queueIndex: pl.currentIndex,
    ));
  }

  void setFavorite(bool fav) {
    if (fav == favorite) return;
    favorite = fav;
    broadcast();
  }

  /// Arte atual de cada música (caminho da música -> PNG), para não se perder quando o item é publicado de novo.
  final Map<String, Uri> art = {};

  /// Arte da notificação. O Android não anima GIF, então usa o primeiro quadro (como PNG).
  Future<void> setArtwork(String trackPath, String? gifPath, {required String cacheDir}) async {
    final png = gifPath == null ? null : await gifFrame(gifPath, cacheDir);
    if (png == null) {
      art.remove(trackPath);
    } else {
      art[trackPath] = Uri.file(png);
    }
    final item = mediaItem.value;
    if (item == null || item.id != trackPath) return; // a música mudou enquanto convertia
    if (item.artUri == art[trackPath]) return;
    mediaItem.add(item.copyWith(artUri: art[trackPath]));
  }
}

/// Converte o primeiro quadro de um GIF em PNG (até 512 px), com cache.
Future<String?> gifFrame(String gifPath, String cacheDir) async {
  try {
    final out = File(p.join(cacheDir, 'arte', '${sha1.convert(utf8.encode(gifPath)).toString().substring(0, 16)}.png'));
    if (out.existsSync()) return out.path;
    final codec = await ui.instantiateImageCodec(await File(gifPath).readAsBytes(), targetWidth: 512);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    await out.parent.create(recursive: true);
    await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return out.path;
  } catch (_) {
    return null;
  }
}
