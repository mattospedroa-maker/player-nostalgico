import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'error_log.dart';

/// Como o app usa a internet (aba Internet das Opções).
enum NetMode {
  online('Internet ligada'),
  wifiOnly('Só no Wi-Fi'),
  offline('Trabalhando off-line');

  final String label;
  const NetMode(this.label);
}

/// O que o app busca sozinho na internet. Cada um pode ser desligado na aba Internet.
/// O que você pede na hora (baixar do YouTube, "Preencher pelo MusicBrainz", botão Resumo) sempre funciona.
enum NetFeature {
  gifs('GIFs das músicas'),
  photos('Fotos dos artistas'),
  covers('Capas dos álbuns e dos programas'),
  lyrics('Letras (para escolher os GIFs)'),
  info('Gênero, artista e álbum'),
  ai('Resumo e temas dos podcasts por IA');

  final String label;
  const NetFeature(this.label);
}

/// Decide se o app pode usar a internet agora, para cada coisa que ele busca sozinho.
class NetPolicy extends ChangeNotifier {
  final SharedPreferences prefs;
  NetPolicy(this.prefs);

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _onWifi = true;

  /// Começa a acompanhar se o celular está no Wi-Fi (só faz diferença no modo "Só no Wi-Fi").
  void watch([Connectivity? connectivity]) {
    final c = connectivity ?? Connectivity();
    try {
      c.checkConnectivity().then(_update).catchError((Object e) {
        errorLog.info('Internet', 'Não deu para saber se o celular está no Wi-Fi', e);
      });
      _sub = c.onConnectivityChanged.listen(_update, onError: (Object e) {
        errorLog.info('Internet', 'Não deu para acompanhar a conexão', e);
      });
    } catch (e) {
      errorLog.info('Internet', 'Não deu para acompanhar a conexão', e);
    }
  }

  void _update(List<ConnectivityResult> r) {
    final wifi = r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    if (wifi == _onWifi) return;
    _onWifi = wifi;
    notifyListeners();
  }

  /// Só para testes.
  @visibleForTesting
  set onWifi(bool v) => _update([if (v) ConnectivityResult.wifi else ConnectivityResult.mobile]);

  bool get onWifi => _onWifi;

  NetMode get mode => NetMode.values.asNameMap()[prefs.getString('netMode')] ?? NetMode.online;

  Set<NetFeature> get disabled {
    final names = prefs.getStringList('netOff') ?? const [];
    return {for (final n in names) ?NetFeature.values.asNameMap()[n]};
  }

  /// A internet pode ser usada agora (modo + Wi-Fi).
  bool get online => switch (mode) {
        NetMode.online => true,
        NetMode.wifiOnly => _onWifi,
        NetMode.offline => false,
      };

  bool allows(NetFeature f) => online && !disabled.contains(f);

  Future<void> set(NetMode mode, Set<NetFeature> off) async {
    await prefs.setString('netMode', mode.name);
    await prefs.setStringList('netOff', [for (final f in off) f.name]);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
