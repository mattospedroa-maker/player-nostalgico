/// Resumo do histórico por música (quantas vezes tocou até o fim, quando tocou por último).
/// Vem de uma consulta agrupada só, em vez de carregar o histórico inteiro a cada tela.
class PlayStats {
  final Map<int, int> plays;
  final Map<int, int> lastPlayed;
  final Map<int, int> skips;
  const PlayStats({this.plays = const {}, this.lastPlayed = const {}, this.skips = const {}});

  static const empty = PlayStats();

  int count(int? id) => id == null ? 0 : plays[id] ?? 0;
  int last(int? id) => id == null ? 0 : lastPlayed[id] ?? 0;
  int skipCount(int? id) => id == null ? 0 : skips[id] ?? 0;
}
