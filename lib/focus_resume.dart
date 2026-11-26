import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// Volta a tocar sozinho quando outro app (um Shorts, um vídeo do Instagram…) termina de usar o som.
///
/// Interrupção curta (ligação, aviso do GPS): o Android avisa quando acabou e o just_audio já volta.
/// Interrupção "definitiva" (o YouTube pega o som para ele): o Android não avisa o fim. Então, só
/// nesse caso e só se a música estava tocando, olhamos de 1,5 em 1,5 s se ainda tem outro app
/// tocando; quando ele fica uns 4,5 s calado, a música volta. Se você der play/pause antes, ou se
/// passar de 20 minutos, a gente desiste. Pausa feita por você nunca volta sozinha.
class FocusResume {
  final AudioPlayer player;
  FocusResume(this.player);

  static const _tick = Duration(milliseconds: 1500);
  static const _quietTicks = 3;
  static const _giveUp = Duration(minutes: 20);

  final _subs = <StreamSubscription>[];
  bool _wasPlaying = false;
  Timer? _watch;

  void start() {
    if (!Platform.isAndroid) return;
    // estado "tocando" como chega pelo stream: quando a interrupção chega, ainda diz o de antes,
    // mesmo que o just_audio já tenha mandado pausar
    _subs.add(player.playingStream.listen((p) {
      _wasPlaying = p;
      if (p) _stop(); // voltou a tocar (sozinho ou por você): não precisa mais vigiar
    }));
    unawaited(AudioSession.instance.then((session) {
      _subs.add(session.interruptionEventStream.listen((e) {
        if (e.begin && e.type == AudioInterruptionType.unknown && _wasPlaying) _watchOther();
      }));
      // fone desconectado: pausa por segurança e não volta sozinho
      _subs.add(session.becomingNoisyEventStream.listen((_) => _stop()));
    }));
  }

  void _watchOther() {
    _stop();
    final started = DateTime.now();
    var heardOther = false;
    var quiet = 0;
    var busy = false;
    final android = AndroidAudioManager();
    _watch = Timer.periodic(_tick, (_) async {
      if (busy) return;
      if (player.playing || DateTime.now().difference(started) > _giveUp) return _stop();
      busy = true;
      try {
        final active = await android.isMusicActive();
        if (_watch == null) return; // cancelado enquanto perguntava
        if (active) {
          heardOther = true;
          quiet = 0;
        } else if (heardOther && ++quiet >= _quietTicks) {
          _stop();
          unawaited(player.play()); // pede o som de volta ao Android
        }
      } catch (_) {
        _stop();
      } finally {
        busy = false;
      }
    });
  }

  void _stop() {
    _watch?.cancel();
    _watch = null;
  }

  void dispose() {
    _stop();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
  }
}
