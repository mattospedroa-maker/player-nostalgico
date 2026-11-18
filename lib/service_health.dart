import 'package:flutter/foundation.dart';

import 'error_log.dart';

/// Quais serviços de fora estão fora do ar agora (plano B dos GIFs).
///
/// Um serviço que falha fica "fora do ar" por [pause] e não é chamado nesse tempo (o app não perde
/// tempo esperando ele a cada música). Passado o tempo, tenta de novo; se responder, volta ao normal.
class ServiceHealth extends ChangeNotifier {
  /// Quanto tempo um serviço que caiu fica sem ser chamado.
  final Duration pause;

  /// Relógio (trocável nos testes).
  DateTime Function() now;

  ServiceHealth({this.pause = const Duration(minutes: 30), DateTime Function()? now}) : now = now ?? DateTime.now;

  final Map<String, DateTime> _downUntil = {};
  final Map<String, Object?> _why = {};

  /// Serviços já avisados nesta queda (o balão aparece uma vez por queda, não a cada música).
  final Set<String> _announced = {};

  /// O serviço está pausado (caiu há pouco)?
  bool isDown(String name) {
    final until = _downUntil[name];
    return until != null && now().isBefore(until);
  }

  /// Caiu em algum momento e ainda não voltou (mesmo que a pausa já tenha passado).
  bool wasDown(String name) => _downUntil.containsKey(name);

  Object? reason(String name) => _why[name];

  /// O serviço não respondeu: fica pausado por [pause].
  void down(String name, Object? error) {
    _downUntil[name] = now().add(pause);
    _why[name] = error;
    notifyListeners();
  }

  /// O serviço respondeu: volta ao normal.
  void up(String name) {
    if (!_downUntil.containsKey(name)) return;
    _downUntil.remove(name);
    _why.remove(name);
    if (_announced.remove(name)) errorLog.info('GIFs', '$name voltou a responder');
    notifyListeners();
  }

  /// Avisa uma vez por queda: balão + ⚠ quando a internet funciona (o serviço caiu mesmo);
  /// só registro quando parece falta de internet.
  void announce(String name, {required bool online, required String fallback}) {
    if (!wasDown(name) || !_announced.add(name)) return;
    final minutes = pause.inMinutes;
    if (online) {
      errorLog.warn('GIFs', '$name fora do ar: $fallback. Tento de novo em $minutes min.', error: _why[name], balloon: true);
    } else {
      errorLog.info('GIFs', 'Sem internet para buscar GIFs: $fallback', _why[name]);
    }
  }
}

/// O serviço respondeu com erro (ex.: 503). Diferente de "sem internet": prova que a conexão funciona.
class ServiceDown implements Exception {
  final String service;
  final int status;
  const ServiceDown(this.service, this.status);
  @override
  String toString() => '$service respondeu com erro $status';
}
