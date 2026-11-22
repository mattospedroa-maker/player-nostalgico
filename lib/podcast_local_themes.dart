import 'package:path/path.dart' as p;

import 'library_search.dart' show normalizeText;
import 'models.dart';
import 'podcast_info.dart';
import 'podcast_themes.dart';

/// Separa os episódios por tema sem IA: junta os que repetem as mesmas palavras importantes nos títulos
/// e nos capítulos (que já ficam guardados no .json do episódio). Instantâneo e offline.
///
/// Como funciona: cada episódio vira um conjunto de palavras (título vale mais que capítulo); palavras
/// comuns ("de", "introdução", o nome do programa...) saem. Depois, de forma gulosa, a palavra que junta
/// mais episódios ainda soltos vira um tema, até [maxThemes] temas. Quem sobra vai para "Outros".
class LocalThemes {
  static const maxThemes = 12;

  /// Palavras que não dizem nada sobre o assunto (já sem acento).
  static const _stop = {
    // português
    'para', 'pela', 'pelo', 'pelas', 'pelos', 'como', 'mais', 'menos', 'muito', 'muita', 'muitos', 'muitas', 'sobre', 'entre',
    'quando', 'porque', 'onde', 'qual', 'quais', 'quem', 'isso', 'isto', 'esse', 'essa', 'esses', 'essas', 'este',
    'esta', 'estes', 'estas', 'aquele', 'aquela', 'nossa', 'nosso', 'nossos', 'nossas', 'minha', 'meus', 'minhas', 'suas',
    'seus', 'dele', 'dela', 'deles', 'delas', 'voce', 'voces', 'gente', 'eles', 'elas', 'tudo', 'todo', 'toda', 'todos',
    'todas', 'nada', 'algo', 'cada', 'outro', 'outra', 'outros', 'outras', 'ainda', 'agora', 'hoje', 'aqui', 'depois', 'antes',
    'sempre', 'nunca', 'tambem', 'apenas', 'mesmo', 'mesma', 'pode', 'podem', 'fazer', 'falar', 'fala', 'falando', 'sabe',
    'saber', 'acha', 'acho', 'vamos', 'vale', 'sendo', 'seria', 'estao', 'estava', 'temos', 'tinha', 'qualquer',
    'coisa', 'coisas', 'parte', 'partes', 'tipo', 'jeito', 'forma', 'vezes', 'grande', 'grandes', 'novo', 'nova', 'novos',
    'novas', 'primeiro', 'primeira', 'ultimo', 'ultima', 'melhor', 'melhores', 'pior', 'quanto', 'quanta', 'tanto', 'tanta',
    'realmente', 'verdade', 'existe', 'existem', 'sera', 'fica', 'ficar', 'anos', 'dias',
    // estrutura do programa
    'podcast', 'podcasts', 'episodio', 'episodios', 'programa', 'temporada', 'introducao', 'abertura', 'encerramento',
    'final', 'finais', 'intro', 'inicio', 'comeco', 'convidado', 'convidada', 'convidados', 'apresentacao', 'perguntas',
    'pergunta', 'resposta', 'respostas', 'recado', 'recados', 'patrocinio', 'patrocinador', 'live', 'ltda', 'oficial',
    'completo', 'completa', 'especial', 'cortes', 'corte', 'react',
    // inglês
    'with', 'from', 'that', 'this', 'what', 'about', 'your', 'have', 'will', 'they', 'their', 'there', 'when', 'where',
    'which', 'would', 'could', 'should', 'into', 'just', 'like', 'more', 'than', 'then', 'them', 'were', 'been', 'being',
    'episode', 'show', 'full', 'part', 'interview',
  };

  /// Temas feitos pelos títulos e capítulos. [previous]: temas que já existiam (o GIF continua pelo nome).
  static List<EpisodeTheme> build(String program, List<Track> episodes, EpisodeInfo? Function(String path) infoFor, {List<EpisodeTheme> previous = const []}) {
    final programWords = _words(program).toSet();
    final display = <String, String>{}; // palavra sem acento -> como aparece (com acento)
    final docs = <Map<String, double>>[]; // por episódio: palavra -> peso

    for (final e in episodes) {
      final title = _cleanTitle(e.title, program);
      final chapters = [for (final c in infoFor(e.path)?.chapters ?? const <Chapter>[]) c.title];
      final w = <String, double>{};
      void add(String text, double value) {
        for (final (key, shown) in _wordsWithDisplay(text)) {
          if (programWords.contains(key)) continue;
          display.putIfAbsent(key, () => shown);
          if ((w[key] ?? 0) < value) w[key] = value;
        }
      }

      // "FULANO DE TAL (ASTROBIÓLOGO)": o que está entre parênteses costuma ser o assunto; fora, o nome do convidado
      final inParens = [for (final m in RegExp(r'\(([^)]*)\)').allMatches(title)) m.group(1)!];
      if (inParens.isNotEmpty) {
        add(title.replaceAll(RegExp(r'\([^)]*\)'), ' '), 0.5);
        for (final x in inParens) {
          add(x, 3);
        }
      } else {
        add(title, 2);
      }
      for (final c in chapters) {
        add(c, 1);
      }
      docs.add(w);
    }

    // plural junta com o singular quando os dois aparecem ("tecnologias" -> "tecnologia")
    final all = {for (final d in docs) ...d.keys};
    String fold(String k) => k.endsWith('s') && all.contains(k.substring(0, k.length - 1)) ? k.substring(0, k.length - 1) : k;
    for (var i = 0; i < docs.length; i++) {
      final m = <String, double>{};
      for (final en in docs[i].entries) {
        final k = fold(en.key);
        if ((m[k] ?? 0) < en.value) m[k] = en.value;
      }
      docs[i] = m;
    }

    final n = episodes.length;
    final minSize = n >= 40 ? 3 : 2;
    // palavra em quase todos os episódios não separa nada (ex.: "ciência" num programa de ciência)
    final maxSize = (n * 0.4).ceil().clamp(minSize, n);
    final free = {for (var i = 0; i < n; i++) i};
    final out = <EpisodeTheme>[];
    final used = <String>{};
    while (out.length < maxThemes) {
      String? best;
      var bestScore = 0.0;
      var bestSet = <int>[];
      final members = <String, List<int>>{};
      final score = <String, double>{};
      for (final i in free) {
        for (final en in docs[i].entries) {
          if (used.contains(en.key)) continue;
          (members[en.key] ??= []).add(i);
          score[en.key] = (score[en.key] ?? 0) + en.value;
        }
      }
      for (final en in members.entries) {
        final size = en.value.length;
        if (size < minSize || size > maxSize) continue;
        // soma dos pesos: assunto no título > capítulo > nome de convidado
        final sc = score[en.key]!;
        if (sc > bestScore || (sc == bestScore && best != null && en.key.compareTo(best) < 0)) {
          best = en.key;
          bestScore = sc;
          bestSet = en.value;
        }
      }
      if (best == null) break;
      used.add(best);
      free.removeAll(bestSet);
      final name = _capitalize(display[best] ?? best);
      final old = previous.where((x) => x.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      out.add(EpisodeTheme(name: name, gifQuery: display[best] ?? best, files: [for (final i in bestSet) p.basename(episodes[i].path)], gif: old?.gif ?? ''));
    }
    return out;
  }

  /// Tira do título o nome do programa, "Podcast #123", "Ep. 12" e o que vem depois de " - Programa".
  static String _cleanTitle(String title, String program) {
    var t = title;
    final i = normalizeText(t).indexOf(normalizeText(program));
    if (i > 0) {
      // "CONVIDADO (ASSUNTO) - Inteligência Ltda. Podcast #108": fica só o começo
      final cut = t.toLowerCase().lastIndexOf(' - ');
      if (cut > 0) t = t.substring(0, cut);
    }
    return t.replaceAll(RegExp(r'#\s*\d+|\bep\.?\s*\d+|\bepis[oó]dio\s*\d+', caseSensitive: false), ' ');
  }

  static Iterable<String> _words(String text) => _wordsWithDisplay(text).map((w) => w.$1);

  /// Palavras de 4+ letras, sem as comuns: (sem acento, como aparece em minúsculas).
  static Iterable<(String, String)> _wordsWithDisplay(String text) sync* {
    for (final raw in text.toLowerCase().split(RegExp(r"[^\p{L}\p{N}]+", unicode: true))) {
      if (raw.length < 4 || RegExp(r'^\d+$').hasMatch(raw)) continue;
      final key = normalizeText(raw).replaceAll(' ', '');
      if (key.length < 4 || _stop.contains(key)) continue;
      yield (key, raw);
    }
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
