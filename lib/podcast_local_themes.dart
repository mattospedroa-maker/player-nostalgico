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

  /// Versão do jeito de agrupar: quando muda, os temas locais guardados são refeitos (os da IA ficam).
  static const source = 'local2';

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
    'completo', 'completa', 'especial', 'cortes', 'corte', 'react', 'aguarde', 'aguardando', 'espera', 'esperando',
    'comecar', 'comecando', 'breve', 'chegando',
    // inglês
    'with', 'from', 'that', 'this', 'what', 'about', 'your', 'have', 'will', 'they', 'their', 'there', 'when', 'where',
    'which', 'would', 'could', 'should', 'into', 'just', 'like', 'more', 'than', 'then', 'them', 'were', 'been', 'being',
    'episode', 'show', 'full', 'part', 'interview',
  };

  /// Temas feitos pelos títulos e capítulos. [previous]: temas que já existiam (o GIF continua pelo nome).
  static List<EpisodeTheme> build(String program, List<Track> episodes, EpisodeInfo? Function(String path) infoFor, {List<EpisodeTheme> previous = const []}) {
    final programWords = _words(program).toSet();
    final display = <String, String>{}; // palavra sem acento -> como aparece (com acento)
    final docs = <Map<String, double>>[]; // por episódio: palavra -> peso (só assunto)
    final namesOf = <List<String>>[]; // por episódio: nomes completos dos convidados ("Sérgio Sacani")
    final nameWords = <String>{}; // palavras que são nome de gente (ficam fora dos temas de assunto)

    for (final e in episodes) {
      final title = _cleanTitle(e.title, program);
      final names = guestNames(title);
      for (final x in infoFor(e.path)?.people ?? const <Participant>[]) {
        if (!x.role.toLowerCase().startsWith('apresent') && x.name.trim().contains(' ')) names.add(x.name.trim());
      }
      namesOf.add(names);
      // título curto inteiro ("BURACOS NEGROS") pode ser assunto: só os nomes com pista forte saem dos assuntos
      for (final nm in [
        ...guestNames(title, includeShort: false),
        for (final x in names)
          if (!title.contains(x)) x,
      ]) {
        nameWords.addAll(_words(nm));
      }
    }

    for (var idx = 0; idx < episodes.length; idx++) {
      final e = episodes[idx];
      final title = _cleanTitle(e.title, program);
      final chapters = [
        for (final c in infoFor(e.path)?.chapters ?? const <Chapter>[])
          if (!isWaitingChapter(c.title)) c.title,
      ];
      final w = <String, double>{};
      void add(String text, double value) {
        for (final (key, shown) in _wordsWithDisplay(text)) {
          if (programWords.contains(key) || nameWords.contains(key)) continue;
          display.putIfAbsent(key, () => shown);
          if ((w[key] ?? 0) < value) w[key] = value;
        }
      }

      // "FULANO DE TAL (ASTROBIÓLOGO)": o que está entre parênteses costuma ser o assunto
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
    // 2ª rodada: o que sobrou e repete o mesmo convidado vira tema com o nome completo dele. Fica por
    // último porque o foco é o assunto: só junta por pessoa quem não entrou em nenhum tema de assunto.
    final usedNames = <String>{};
    while (out.length < maxThemes) {
      String? bestKey;
      var bestSet = <int>[];
      final shown = <String, String>{};
      final members = <String, Set<int>>{};
      for (final i in free) {
        for (final nm in namesOf[i]) {
          if (!nm.contains(' ')) continue; // só com pelo menos dois nomes
          final key = normalizeText(nm);
          if (usedNames.contains(key)) continue;
          shown.putIfAbsent(key, () => nm);
          (members[key] ??= {}).add(i);
        }
      }
      // episódio que cita só o sobrenome ("SACANI E ALBERTO LINDNER") entra no grupo do nome completo
      for (final key in members.keys) {
        final last = key.split(' ').last;
        if (last.length < 4) continue;
        for (final i in free) {
          if (namesOf[i].any((nm) => normalizeText(nm).split(' ').last == last)) members[key]!.add(i);
        }
      }
      for (final en in members.entries) {
        if (en.value.length < 2) continue;
        if (en.value.length > bestSet.length || (en.value.length == bestSet.length && bestKey != null && en.key.compareTo(bestKey) < 0)) {
          bestKey = en.key;
          bestSet = en.value.toList()..sort();
        }
      }
      if (bestKey == null) break;
      usedNames.add(bestKey);
      free.removeAll(bestSet);
      final name = _titleCase(shown[bestKey]!);
      final old = previous.where((x) => x.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      out.add(EpisodeTheme(name: name, gifQuery: name, files: [for (final i in bestSet) p.basename(episodes[i].path)], gif: old?.gif ?? ''));
    }
    return out;
  }

  /// Capítulo de espera de live ("Aguarde", "Vem aí", "Já vamos começar"...): não diz nada do assunto.
  static bool isWaitingChapter(String title) {
    final t = normalizeText(title);
    return RegExp(
      r'\b(aguard\w*|esper\w*|vem ai|ja (vai|vamos) comecar|vai comecar|comecando|comeca (ja|em)|em breve|pre ?live|'
      r'starting( soon)?|waiting|soon|chegando|bem vindos?|boas vindas)\b',
    ).hasMatch(t);
  }

  /// Nomes de convidados no título: fora dos parênteses ("SÉRGIO SACANI (ASTRONOMIA)"), depois dos dois-pontos
  /// separados por "e"/vírgula ("AGRO: ROBERTO RODRIGUES E GUSTAVO SPADOTTI") ou o título inteiro curto ("AMIT GOSWAMI").
  static List<String> guestNames(String title, {bool includeShort = true}) {
    final out = <String>[];
    void chunks(String text) {
      for (var c in text.split(RegExp(r',|\s+e\s+|\s+&\s+|\s+x\s+', caseSensitive: false))) {
        c = c.replaceAll(RegExp(r'\b(dr|dra|prof|profa|pastor|padre)\.?\s+', caseSensitive: false), '').trim();
        final words = c.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (words.isEmpty || words.length > 3) continue;
        if (words.any((w) => RegExp(r'\d').hasMatch(w) || _stop.contains(normalizeText(w)))) continue;
        out.add(words.join(' '));
      }
    }

    final noParens = title.replaceAll(RegExp(r'\([^)]*\)'), ' ').trim();
    if (noParens.length < title.trim().length) {
      chunks(noParens.contains(':') ? noParens.substring(noParens.lastIndexOf(':') + 1) : noParens);
    } else if (title.contains(':')) {
      chunks(title.substring(title.lastIndexOf(':') + 1));
    } else if (includeShort && title.trim().split(RegExp(r'\s+')).length <= 3) {
      chunks(title);
    }
    return out;
  }

  static String _titleCase(String s) => s.toLowerCase().split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

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
