import 'dart:io';

/// Por que uma música não abriu (para o aviso).
enum FailReason {
  /// O arquivo não existe mais (apagado ou movido por fora do app).
  missing,

  /// O arquivo existe, mas o player não conseguiu ler (corrompido ou formato que o celular não toca).
  broken,
}

/// Uma música que não abriu.
class PlaybackFailure {
  final String path;
  final FailReason reason;
  final DateTime at;
  PlaybackFailure(this.path, this.reason, {DateTime? at}) : at = at ?? DateTime.now();

  /// Descobre o motivo olhando se o arquivo ainda está lá.
  static FailReason reasonFor(String path) => File(path).existsSync() ? FailReason.broken : FailReason.missing;

  String get reasonText => switch (reason) {
        FailReason.missing => 'arquivo apagado',
        FailReason.broken => 'arquivo com defeito',
      };
}

/// Decide o que fazer quando a música da fila não abre: pular para a próxima que ainda não falhou,
/// ou parar (quando todas falharam), sem nunca ficar pulando em loop.
///
/// Não sabe nada do player: recebe a posição da que falhou e devolve para onde ir. Assim dá para testar.
class SkipGuard {
  /// Depois de tantas falhas seguidas (sem nenhuma música abrir no meio), desiste e para.
  static const maxStreak = 20;

  int _streak = 0;
  int? _handled;

  /// Falhas seguidas desde a última música que abriu.
  int get streak => _streak;

  /// Uma música abriu e está pronta: zera a contagem.
  void onReady() {
    _streak = 0;
    _handled = null;
  }

  /// Fila nova: esquece o que estava acontecendo.
  void reset() => onReady();

  /// A música na posição [index] não abriu. [length] é o tamanho da fila, [wrap] diz se a fila
  /// recomeça do início no fim (repetir tudo) e [failed] diz se a música de uma posição já falhou antes.
  ///
  /// Devolve a posição para onde pular, `null` para parar, ou -1 quando é o mesmo erro repetido
  /// (o player às vezes avisa duas vezes da mesma falha) e não há nada a fazer.
  int? onError(int index, int length, {bool wrap = false, required bool Function(int) failed}) {
    if (_handled == index) return -1;
    _handled = index;
    _streak++;
    if (length <= 1 || _streak >= length || _streak >= maxStreak) return null;
    for (var step = 1; step < length; step++) {
      var i = index + step;
      if (i >= length) {
        if (!wrap) return null;
        i -= length;
      }
      if (!failed(i)) return i;
    }
    return null; // todas as outras já falharam
  }
}
