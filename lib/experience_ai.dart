import 'experiences.dart';
import 'models.dart';
import 'styles.dart';
import 'track_sheet.dart';
import 'visual_tags.dart' show VisualTagMapper;

/// Um tema inventado pela IA (ou montado pelas palavras no "Inventar uma experiência").
class AiTheme {
  final String title;
  final String emoji;
  final Map<String, double> scenes;
  final List<String> words;
  final List<String> artists;
  final String why;

  /// Músicas famosas que combinam ("Artista — Título"), para o "Para completar".
  final List<String> missing;

  const AiTheme({
    required this.title,
    this.emoji = '✨',
    this.scenes = const {},
    this.words = const [],
    this.artists = const [],
    this.why = '',
    this.missing = const [],
  });

  String get id => 'ia:${VisualTagMapper.normalize(title).replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';

  ExperienceRecipe toRecipe() => ExperienceRecipe(id, title, emoji, scenes, words: words, artists: artists);

  static List<String> _strs(Object? v, int max, {int maxLen = 60}) => [
        if (v is List)
          for (final x in v.take(max * 2))
            if ('$x'.trim().isNotEmpty) '$x'.trim().length > maxLen ? '$x'.trim().substring(0, maxLen) : '$x'.trim()
      ].take(max).toList();

  /// Lê um tema da resposta da IA (ou do que ficou guardado). null = sem nome ou sem nenhuma pista.
  static AiTheme? fromJson(Object? j) {
    if (j is! Map) return null;
    final title = '${j['title'] ?? ''}'.trim();
    if (title.isEmpty || title.length > 60) return null;
    final scenes = <String, double>{};
    final raw = j['scenes'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final w = e.value is num ? (e.value as num).toDouble() : double.tryParse('${e.value}');
        if (TrackSheet.sceneByKey.containsKey('${e.key}') && w != null && w > 0) scenes['${e.key}'] = w > 1 ? 1 : w;
      }
    } else if (raw is List) {
      var w = 1.0;
      for (final k in raw) {
        if (TrackSheet.sceneByKey.containsKey('$k')) {
          scenes['$k'] = w;
          w = w > .5 ? w - .25 : .5;
        }
      }
    }
    final words = _strs(j['words'], 10, maxLen: 30);
    final artists = _strs(j['artists'], 10);
    if (scenes.isEmpty && words.isEmpty && artists.isEmpty) return null;
    final emoji = '${j['emoji'] ?? ''}'.trim();
    return AiTheme(
      title: title,
      emoji: emoji.isEmpty || emoji.runes.length > 4 ? '✨' : emoji,
      scenes: scenes,
      words: words,
      artists: artists,
      why: '${j['why'] ?? ''}'.trim().length > 160 ? '${j['why']}'.trim().substring(0, 160) : '${j['why'] ?? ''}'.trim(),
      missing: _strs(j['missing'], 6, maxLen: 80),
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'emoji': emoji,
        'scenes': scenes,
        if (words.isNotEmpty) 'words': words,
        if (artists.isNotEmpty) 'artists': artists,
        if (why.isNotEmpty) 'why': why,
        if (missing.isNotEmpty) 'missing': missing,
      };
}

/// Pedidos à IA para as playlists do momento e o "Inventar" sem internet.
class ExperienceAi {
  /// Resumo curto da biblioteca para a IA (só nomes de artistas, estilos e contagens, nunca arquivos).
  static String summarize(List<Track> library) {
    final styles = <String, int>{}, artists = <String, int>{}, scenes = <String, int>{}, decades = <int, int>{};
    final sounds = <String, int>{}, likes = <String, int>{};
    for (final t in library) {
      for (final s in Styles.of(t).take(2)) {
        styles[s] = (styles[s] ?? 0) + 1;
      }
      if (t.artist != unknownArtist) artists[t.artist] = (artists[t.artist] ?? 0) + 1;
      for (final k in TrackSheet.scenesOf(t)) {
        scenes[k] = (scenes[k] ?? 0) + 1;
      }
      if (t.year != null && t.year! > 1940) decades[t.year! ~/ 10 * 10] = (decades[t.year! ~/ 10 * 10] ?? 0) + 1;
      final f = TrackSheet.aiOf(t);
      if (f != null) {
        for (final x in f.sound) {
          sounds[x] = (sounds[x] ?? 0) + 1;
        }
        for (final x in f.like) {
          likes[x] = (likes[x] ?? 0) + 1;
        }
      }
    }
    String top(Map<Object, int> m, int n) {
      final l = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      return l.take(n).map((e) => '${e.key} (${e.value})').join(', ');
    }

    return [
      'Total: ${library.length} músicas.',
      'Estilos: ${top(styles, 25)}',
      'Artistas: ${top(artists, 40)}',
      'Cenas: ${top(scenes, 33)}',
      if (decades.isNotEmpty) 'Décadas: ${top(decades, 8)}',
      if (sounds.isNotEmpty) 'Sons marcantes: ${top(sounds, 15)}',
      if (likes.isNotEmpty) 'Parece trilha de: ${top(likes, 15)}',
    ].join('\n');
  }

  static String _format(int n) => '''
Responda só com JSON: {"themes":[{"title":"","emoji":"","scenes":{"chave":1.0},"words":[],"artists":[],"why":"","missing":[]}]} com $n tema(s).
- "title": nome curto e divertido em português (pode citar filme, jogo, série ou situação, ex.: "O Bom, o Mau e o Feio", "Motim no navio").
- "emoji": um emoji.
- "scenes": 1 a 3 chaves desta lista (só estas) com peso de 0.3 a 1: ${sceneCatalog.map((s) => '${s.key} (${s.label})').join(', ')}
- "words": até 8 palavras em inglês e português que aparecem em títulos, álbuns ou tags dessas músicas (ex.: "western", "whistle", "deserto").
- "artists": até 8 artistas DA LISTA ACIMA que combinam.
- "why": uma frase curta em português dizendo de onde veio a ideia.
- "missing": até 4 músicas famosas que combinam muito com o tema, no formato "Artista — Título" (podem não estar na biblioteca).''';

  /// Pedido semanal: temas novos e surpreendentes que a biblioteca consegue preencher.
  static String weeklyPrompt(String summary, {List<String> avoid = const [], int count = 3}) => '''
Você é o curador de um player de música off-line nostálgico. Toda semana ele mostra "playlists do momento":
temas como "Para ir para a guerra" ou "Caminhada no parque", e algumas surpresas criativas como "trilha de O Bom, o Mau e o Feio".
As playlists só podem usar músicas que a pessoa já tem. Invente $count temas NOVOS e criativos que esta biblioteca consiga preencher
com pelo menos 8 músicas (use as cenas, estilos e artistas que aparecem bastante).
${avoid.isEmpty ? '' : 'Não repita estes temas: ${avoid.join(', ')}.'}

Biblioteca:
$summary

${_format(count)}''';

  /// Pedido do "Inventar uma experiência": transforma o que a pessoa digitou num tema.
  static String inventPrompt(String text, String summary) => '''
Você é o curador de um player de música off-line. A pessoa pediu uma playlist para este momento: "$text".
Monte o tema usando só o que a biblioteca tem.

Biblioteca:
$summary

${_format(1)}''';

  static List<AiTheme> parseThemes(Map<String, dynamic> json) => [
        for (final t in (json['themes'] as List? ?? const [])) ?AiTheme.fromJson(t),
      ];

  static const _stop = {
    'para', 'pra', 'com', 'sem', 'uma', 'umas', 'uns', 'dos', 'das', 'que', 'ao', 'aos', 'na', 'no', 'nas', 'nos', 'de', 'do', 'da',
    'em', 'um', 'the', 'and', 'for', 'with', 'of', 'in', 'on', 'at', 'to', 'playlist', 'musica', 'musicas', 'momento', 'quando',
    'estou', 'tou', 'meu', 'minha', 'muito', 'mais', 'bem', 'tipo', 'algo', 'coisa', 'hora', 'dia',
  };

  /// Palavras do português do dia a dia que apontam para uma cena (completam as palavras de cada cena).
  static const _hints = <String, String>{
    'cavalgada': 'faroeste', 'cavalo': 'faroeste', 'cowboy': 'faroeste', 'xerife': 'faroeste', 'duelo': 'faroeste',
    'batalha': 'guerra', 'luta': 'guerra', 'soldado': 'guerra', 'exercito': 'guerra', 'espada': 'guerra',
    'academia': 'treino', 'corrida': 'treino', 'correr': 'treino', 'malhar': 'treino', 'bike': 'treino',
    'chovendo': 'chuva', 'garoa': 'chuva', 'tempestade': 'chuva', 'nublado': 'chuva',
    'carro': 'estrada', 'viagem': 'estrada', 'dirigir': 'estrada', 'rodovia': 'estrada',
    'noite': 'madrugada', 'insonia': 'madrugada', 'lua': 'madrugada',
    'sol': 'praia', 'calor': 'praia', 'piscina': 'praia', 'verao': 'praia', 'mar': 'praia',
    'balada': 'festa', 'aniversario': 'festa', 'churrasco': 'festa', 'dancar': 'festa',
    'estudar': 'foco', 'trabalhar': 'foco', 'ler': 'foco', 'leitura': 'foco', 'livro': 'foco', 'programar': 'foco',
    'dormir': 'dormir', 'sono': 'dormir', 'deitar': 'dormir', 'relaxar': 'dormir',
    'saudade': 'saudade', 'lembrar': 'saudade', 'infancia': 'saudade', 'ex': 'fossa', 'termino': 'fossa', 'chorar': 'fossa',
    'namorar': 'romance', 'namorada': 'romance', 'namorado': 'romance', 'encontro': 'romance', 'amor': 'romance',
    'raiva': 'raiva', 'odio': 'raiva', 'estressado': 'raiva', 'filme': 'cinema', 'cinema': 'cinema', 'heroi': 'aventura',
    'jogo': 'game', 'jogar': 'game', 'boss': 'game', 'espaco': 'espaco', 'estrelas': 'espaco', 'foguete': 'espaco',
    'nuvem': 'sonho', 'flutuar': 'sonho', 'cidade': 'cidade', 'neon': 'cidade', 'frio': 'inverno', 'neve': 'inverno',
    'cafe': 'cafe', 'manha': 'cafe', 'domingo': 'cafe', 'terror': 'sombrio', 'medo': 'sombrio', 'halloween': 'sombrio',
    'aventura': 'aventura', 'montanha': 'aventura', 'trilha': 'aventura', 'pirata': 'pirata', 'navio': 'pirata',
    'faxina': 'limpeza', 'limpar': 'limpeza', 'arrumar': 'limpeza', 'pensar': 'reflexao', 'vida': 'reflexao',
    'onibus': 'reflexao', 'janela': 'reflexao', 'apocalipse': 'fim', 'zumbi': 'fim', 'jantar': 'jantar', 'vinho': 'jantar',
    'anime': 'anime', 'deserto': 'faroeste', 'parque': 'parque', 'caminhar': 'parque', 'caminhada': 'parque', 'passeio': 'parque',
  };

  /// "Inventar" sem internet: casa as palavras do texto com as cenas (nome, palavras e dicas em português).
  static AiTheme offlineTheme(String text) {
    final norm = VisualTagMapper.normalize(text).replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    final tokens = [for (final w in norm.split(' ')) if (w.length >= 2 && !_stop.contains(w)) w];
    final score = <String, double>{};
    for (final w in tokens) {
      final hint = _hints[w] ?? (w.endsWith('s') ? _hints[w.substring(0, w.length - 1)] : null);
      if (hint != null) score[hint] = (score[hint] ?? 0) + 2;
      for (final s in sceneCatalog) {
        final label = VisualTagMapper.normalize(s.label);
        if (s.key == w || label.split(' ').contains(w)) score[s.key] = (score[s.key] ?? 0) + 1.5;
        if (w.length >= 4 && s.words.any((x) => VisualTagMapper.normalize(x) == w)) score[s.key] = (score[s.key] ?? 0) + 1;
      }
    }
    final ranked = score.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final scenes = <String, double>{};
    const weights = [1.0, .7, .5];
    for (var i = 0; i < ranked.length && i < 3; i++) {
      scenes[ranked[i].key] = weights[i];
    }
    final clean = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final title = clean.isEmpty ? 'Experiência' : clean[0].toUpperCase() + clean.substring(1);
    return AiTheme(
      title: title.length > 50 ? '${title.substring(0, 50)}…' : title,
      emoji: ranked.isEmpty ? '✨' : TrackSheet.sceneByKey[ranked.first.key]!.emoji,
      scenes: scenes,
      words: [for (final w in tokens) if (w.length >= 4) w].take(8).toList(),
      why: scenes.isEmpty
          ? 'Montada pelas palavras que você digitou.'
          : 'Montada pelas palavras que você digitou (${scenes.keys.map((k) => TrackSheet.sceneByKey[k]!.label).join(', ')}).',
    );
  }
}
