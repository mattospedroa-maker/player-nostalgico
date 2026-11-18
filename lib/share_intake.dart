import 'dart:io';

import 'package:flutter/services.dart';

import 'error_log.dart';

/// Links que chegam pelo menu "Compartilhar" do Android (ex.: do app do YouTube).
/// [onShared] é chamado com o texto compartilhado, tanto com o app fechado quanto já aberto.
class ShareIntake {
  static const _channel = MethodChannel('nostalgic/share');

  static Future<void> attach(void Function(String text) onShared) async {
    if (!Platform.isAndroid) return;
    void receive(String text) {
      errorLog.info('Compartilhar', 'Link recebido: $text');
      onShared(text);
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared' && call.arguments is String) receive(call.arguments as String);
    });
    try {
      // também avisa o Android que o Dart já está escutando: os próximos links vêm na hora
      final first = await _channel.invokeMethod<String>('initial');
      if (first != null && first.trim().isNotEmpty) receive(first);
    } catch (e) {
      errorLog.info('Compartilhar', 'Não deu para ler o link compartilhado', e);
    }
  }
}
