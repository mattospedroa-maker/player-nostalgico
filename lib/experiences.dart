import 'dart:convert';
import 'dart:math';

import 'artist_names.dart';
<<<<<<< HEAD
import 'experience_ai.dart';
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
import 'models.dart';
import 'play_stats.dart';
import 'styles.dart';
import 'track_sheet.dart';
<<<<<<< HEAD
import 'visual_tags.dart' show VisualTagMapper;
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e

/// Receita de uma playlist do momento: nome, ícone e as cenas que ela procura (com peso).
class ExperienceRecipe {
  final String id;
  final String title;
  final String emoji;
  final Map<String, double> scenes;
<<<<<<< HEAD

  /// Palavras procuradas no título, álbum, artista, tags e na ficha da IA (temas da IA e "Inventar").
  final List<String> words;

  /// Artistas que combinam com o tema (temas da IA).
  final List<String> artists;
  const ExperienceRecipe(this.id, this.title, this.emoji, this.scenes, {this.words = const [], this.artists = const []});
=======
  const ExperienceRecipe(this.id, this.title, this.emoji, this.scenes);
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
}

/// Cardápio fixo (off-line). Novas ideias entram aqui; a IA e as surpresas completam.
const List<ExperienceRecipe> experienceMenu = [
  ExperienceRecipe('guerra', 'Para ir para a guerra', '⚔️', {'guerra': 1, 'aventura': .6, 'raiva': .4}),
  ExperienceRecipe('treino', 'Treino pesado', '🏋️', {'treino': 1, 'raiva': .5, 'festa': .3}),
  ExperienceRecipe('parque', 'Caminhada no parque', '🌳', {'parque': 1, 'cafe': .5, 'praia': .3}),
  ExperienceRecipe('chuva', 'Dia de chuva na janela', '🌧️', {'chuva': 1, 'reflexao': .6, 'saudade': .4}),
  ExperienceRecipe('madrugada', 'Dirigindo de madrugada', '🌙', {'madrugada': 1, 'cidade': .6, 'sonho': .3}),
  ExperienceRecipe('estrada', 'Pé na estrada', '🛣️', {'estrada': 1, 'retro80': .3}),
  ExperienceRecipe('faroeste', 'Duelo ao meio-dia', '🤠', {'faroeste': 1, 'cinema': .4}),
  ExperienceRecipe('cinema', 'Créditos finais', '🎬', {'cinema': 1, 'aventura': .5}),
  ExperienceRecipe('anime', 'Maratona de anime', '🌸', {'anime': 1}),
  ExperienceRecipe('game', 'Fase final do videogame', '🎮', {'game': 1, 'aventura': .4}),
  ExperienceRecipe('espaco', 'Última noite na estação espacial', '🚀', {'espaco': 1, 'sonho': .5}),
  ExperienceRecipe('sonho', 'Flutuando nas nuvens', '☁️', {'sonho': 1, 'dormir': .3}),
  ExperienceRecipe('praia', 'Fim de tarde na praia', '🏖️', {'praia': 1, 'parque': .3}),
  ExperienceRecipe('festa', 'Esquenta para a festa', '🎉', {'festa': 1, 'limpeza': .4}),
  ExperienceRecipe('foco', 'Foco total', '📚', {'foco': 1}),
  ExperienceRecipe('dormir', 'Antes de dormir', '😴', {'dormir': 1, 'sonho': .4}),
  ExperienceRecipe('saudade', 'Bateu a saudade', '💭', {'saudade': 1, 'reflexao': .4}),
  ExperienceRecipe('fossa', 'Coração partido', '💔', {'fossa': 1, 'saudade': .5}),
  ExperienceRecipe('romance', 'Jantar a dois', '🕯️', {'romance': 1, 'jantar': .7}),
  ExperienceRecipe('raiva', 'Pra descontar a raiva', '😤', {'raiva': 1, 'treino': .3}),
  ExperienceRecipe('cidade', 'Luzes da cidade', '🌃', {'cidade': 1, 'madrugada': .4}),
  ExperienceRecipe('inverno', 'Noite fria de inverno', '❄️', {'inverno': 1, 'reflexao': .4}),
  ExperienceRecipe('cafe', 'Café de domingo', '☕', {'cafe': 1, 'jantar': .3}),
  ExperienceRecipe('sombrio', 'Noite de Halloween', '🦇', {'sombrio': 1}),
  ExperienceRecipe('aventura', 'Começo de uma aventura', '🏔️', {'aventura': 1, 'guerra': .3}),
  ExperienceRecipe('pirata', 'Motim no navio', '🏴‍☠️', {'pirata': 1, 'aventura': .4}),
  ExperienceRecipe('retro80', 'Fita dos anos 80', '📼', {'retro80': 1}),
  ExperienceRecipe('retro2000', 'Adolescência nos anos 2000', '💿', {'retro2000': 1}),
  ExperienceRecipe('brasil', 'Roda de amigos', '🪕', {'brasil': 1}),
  ExperienceRecipe('psicodelia', 'Viagem psicodélica', '🌀', {'psicodelia': 1, 'espaco': .4}),
  ExperienceRecipe('limpeza', 'Faxina animada', '🧹', {'limpeza': 1, 'festa': .4}),
  ExperienceRecipe('reflexao', 'Pensando na vida', '🪟', {'reflexao': 1, 'chuva': .3}),
  ExperienceRecipe('fim', 'Trilha do fim do mundo', '☄️', {'fim': 1, 'sombrio': .3}),
  ExperienceRecipe('livraria', 'Livraria antiga às 16h', '📖', {'cafe': .8, 'foco': .6, 'chuva': .3}),
  ExperienceRecipe('vilao', 'Entrada do vilão', '😈', {'sombrio': .8, 'guerra': .5, 'cinema': .4}),
  ExperienceRecipe('heroi', 'Cena do herói', '🦸', {'aventura': 1, 'cinema': .5, 'treino': .3}),
  ExperienceRecipe('onibus', 'Janela do ônibus', '🚌', {'reflexao': .7, 'estrada': .7, 'saudade': .3}),
];

/// Uma playlist do momento que está no ar: some sozinha em [expiresAt] (40 a 70 horas depois de criada).
class Experience {
  final String id;
  final String title;
  final String emoji;

  /// 'menu' (cardápio), 'surpresa' (tirada da sua biblioteca) ou 'ia'.
  final String kind;
  final List<int> trackIds;

  /// Por que cada música entrou (id -> etiqueta curta).
  final Map<int, String> reasons;

  /// Uma frase sobre de onde ela veio.
  final String why;
<<<<<<< HEAD

  /// "Para completar": músicas que combinam com o tema e você ainda não tem ("Artista — Título").
  final List<String> missing;
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
  final int createdAt;
  final int expiresAt;

  const Experience({
    required this.id,
    required this.title,
    required this.emoji,
    required this.kind,
    required this.trackIds,
    this.reasons = const {},
    this.why = '',
<<<<<<< HEAD
    this.missing = const [],
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
    required this.createdAt,
    required this.expiresAt,
  });

  bool expired(int nowMs) => nowMs >= expiresAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'emoji': emoji,
        'kind': kind,
        'tracks': trackIds,
        'reasons': {for (final e in reasons.entries) '${e.key}': e.value},
        'why': why,
<<<<<<< HEAD
        if (missing.isNotEmpty) 'missing': missing,
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
        'created': createdAt,
        'expires': expiresAt,
      };

  static Experience? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return Experience(
        id: '${j['id']}',
        title: '${j['title']}',
        emoji: '${j['emoji'] ?? '✨'}',
        kind: '${j['kind'] ?? 'menu'}',
        trackIds: [for (final x in (j['tracks'] as List? ?? const [])) if (x is int) x],
        reasons: {
          for (final e in ((j['reasons'] as Map?) ?? const {}).entries)
            if (int.tryParse('${e.key}') != null) int.parse('${e.key}'): '${e.value}'
        },
        why: '${j['why'] ?? ''}',
<<<<<<< HEAD
        missing: [for (final m in (j['missing'] as List? ?? const [])) '$m'],
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
        createdAt: (j['created'] as num).toInt(),
        expiresAt: (j['expires'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// "2d 4h", "19h", "35 min".
  static String timeLeft(int msLeft) {
    if (msLeft <= 0) return 'acabando';
    final m = msLeft ~/ 60000;
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    if (h < 24) return '${h}h';
    return '${h ~/ 24}d ${h % 24}h';
  }
}

/// O que fica guardado: as que estão no ar e as receitas usadas há pouco (para não repetir logo).
class ExperienceState {
  final List<Experience> active;
  final List<String> recent;
  const ExperienceState(this.active, this.recent);
  static const empty = ExperienceState([], []);

  String encode() => jsonEncode({'active': [for (final e in active) e.toJson()], 'recent': recent});

  static ExperienceState decode(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    try {
      final j = jsonDecode(raw) as Map;
      return ExperienceState(
        [for (final e in (j['active'] as List? ?? const [])) ?Experience.fromJson(e)],
        [for (final r in (j['recent'] as List? ?? const [])) '$r'],
      );
    } catch (_) {
      return empty;
    }
  }
}

/// Monta e renova as playlists do momento. Tudo em memória, sem internet.
class ExperienceEngine {
  /// Quantas ficam no ar ao mesmo tempo.
  static const target = 8;

  /// Surpresas no máximo entre as que estão no ar.
  static const maxSurprises = 3;
  static const minTracks = 8;
  static const maxTracks = 25;
  static const maxPerArtist = 3;

  /// Quantas receitas usadas há pouco ficam "de castigo".
  static const recentMemory = 24;
  static const minHours = 40, maxHours = 70;

<<<<<<< HEAD
  /// Temas da IA no ar ao mesmo tempo.
  static const maxAi = 2;

  /// Das músicas sugeridas pela IA ("Artista — Título"), as que você ainda não tem.
  static List<String> missingFrom(List<String> suggested, List<Track> library) {
    final have = {for (final t in library) _titleKey(t.title)};
    final out = <String>[];
    for (final m in suggested) {
      final parts = m.split(RegExp(r'\s+[—–-]\s+'));
      final title = parts.length > 1 ? parts.sublist(1).join(' ') : m;
      if (title.trim().isEmpty || have.contains(_titleKey(title))) continue;
      if (!out.contains(m)) out.add(m);
      if (out.length >= 6) break;
    }
    return out;
  }

  static String _titleKey(String title) =>
      _norm(title.replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '')).replaceAll(RegExp(r'[^a-z0-9]+'), '');

  /// Monta na hora uma playlist do momento a partir de uma receita (botão "Inventar uma experiência").
  /// null = poucas músicas combinam.
  static Experience? invent(ExperienceRecipe r, List<Track> library,
      {PlayStats stats = PlayStats.empty, int? nowMs, Random? rnd, String why = '', List<String> missing = const []}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final random = rnd ?? Random();
    final tracks = pick(r, library, stats: stats, rnd: random, min: 5);
    if (tracks.isEmpty) return null;
    return Experience(
        id: r.id, title: r.title, emoji: r.emoji, kind: 'inventada', trackIds: [for (final (t, _) in tracks) t.id!],
        reasons: {for (final (t, l) in tracks) t.id!: l}, why: why, missing: missingFrom(missing, library), createdAt: now,
        expiresAt: now + (minHours + random.nextInt(maxHours - minHours + 1)) * _hour);
  }

=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
  static const _hour = 3600000;

  /// Músicas para uma receita, com a etiqueta do porquê. Vazio se não tiver músicas suficientes.
  static List<(Track, String)> pick(ExperienceRecipe r, List<Track> library,
<<<<<<< HEAD
      {PlayStats stats = PlayStats.empty, Random? rnd, Sheet Function(Track)? sheetOf, AiFacts? Function(Track)? aiOf, int min = minTracks}) {
    final random = rnd ?? Random();
    final sheet = sheetOf ?? TrackSheet.of;
    final ai = aiOf ?? TrackSheet.aiOf;
    final wordRe = wordsRegex(r.words);
    final artists = {for (final a in r.artists) _norm(a)};
=======
      {PlayStats stats = PlayStats.empty, Random? rnd, Sheet Function(Track)? sheetOf}) {
    final random = rnd ?? Random();
    final sheet = sheetOf ?? TrackSheet.of;
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
    final scored = <(Track, double, String)>[];
    for (final t in library) {
      if (t.id == null) continue;
      var score = 0.0, best = 0.0;
      var label = '';
      for (final (s, pts) in sheet(t).scenes) {
        final w = r.scenes[s.key];
        if (w == null) continue;
        final v = (pts > 4 ? 4 : pts) * w; // cena posta à mão vale como uma cena forte
        score += v;
        if (v > best) {
          best = v;
          label = '${s.emoji} ${s.label}';
        }
      }
<<<<<<< HEAD
      if (artists.isNotEmpty && artists.contains(_norm(ArtistNames.current.main(t.artist)))) {
        score += 1.5;
        if (best < 1.5) {
          best = 1.5;
          label = '🎤 ${ArtistNames.current.main(t.artist)}';
        }
      }
      if (wordRe != null) {
        final f = ai(t);
        final text = _norm([t.title, t.album, t.artist, ...Styles.soundTags(t), if (f != null) ...[...f.topics, ...f.sound, ...f.like]].join(' · '));
        final hits = wordRe.allMatches(text).map((m) => m.group(2)).toSet();
        if (hits.isNotEmpty) {
          final v = hits.length >= 2 ? 2.4 : 1.4;
          score += v;
          if (v > best) {
            best = v;
            label = '🔤 ${hits.first}';
          }
        }
      }
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
      if (score < TrackSheet.minScore) continue;
      // muito pulada pesa menos
      final plays = stats.count(t.id), skips = stats.skipCount(t.id);
      if (skips >= 3 && skips > plays * 2) score *= .6;
      score *= .85 + random.nextDouble() * .3; // um pouco de sorte: cada vez sai uma lista diferente
      scored.add((t, score, label));
    }
<<<<<<< HEAD
    if (scored.length < min) return const [];
=======
    if (scored.length < minTracks) return const [];
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final perArtist = <String, int>{};
    final names = ArtistNames.current;
    final out = <(Track, String)>[];
    for (final (t, _, label) in scored) {
      final k = names.key(t.artist);
      if ((perArtist[k] ?? 0) >= maxPerArtist) continue;
      perArtist[k] = (perArtist[k] ?? 0) + 1;
      out.add((t, label));
      if (out.length >= maxTracks) break;
    }
<<<<<<< HEAD
    return out.length < min ? const [] : out;
  }

  static String _norm(String s) => VisualTagMapper.normalize(s);

  /// Regex das palavras (inteiras, sem acento). null = sem palavras.
  static RegExp? wordsRegex(List<String> words) {
    final ws = [for (final w in words) if (_norm(w).trim().length >= 3) RegExp.escape(_norm(w).trim())];
    if (ws.isEmpty) return null;
    return RegExp('(^|[^a-z0-9])(${ws.join('|')})(\$|[^a-z0-9])');
=======
    return out.length < minTracks ? const [] : out;
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
  }

  /// Surpresas tiradas da sua biblioteca: um artista esquecido, uma década, um estilo raro, um ano.
  static List<(String id, String title, String emoji, String why, List<(Track, String)> tracks)> surprises(
      List<Track> library, PlayStats stats, int nowMs, Random rnd) {
    final out = <(String, String, String, String, List<(Track, String)>)>[];
    final names = ArtistNames.current;
    List<(Track, String)> take(List<Track> list, String label) {
      final l = [...list]..shuffle(rnd);
      return [for (final t in l.take(maxTracks)) (t, label)];
    }

    // artista que você tem bastante e não ouve há mais de 45 dias
    final byArtist = <String, List<Track>>{};
    for (final t in library) {
      if (t.artist == unknownArtist) continue;
      (byArtist[names.main(t.artist)] ??= []).add(t);
    }
    final forgotten = [
      for (final e in byArtist.entries)
        if (e.value.length >= minTracks && e.value.every((t) => nowMs - stats.last(t.id) > 45 * 24 * _hour)) e
    ];
    if (forgotten.isNotEmpty) {
      final e = forgotten[rnd.nextInt(forgotten.length)];
      out.add(('artista:${e.key}', 'Uma noite com ${e.key}', '🎙️', 'Faz tempo que você não ouve ${e.key}.', take(e.value, '🎙️ ${e.key}')));
    }
    // década
    final byDecade = <int, List<Track>>{};
    for (final t in library) {
      final y = t.year;
      if (y != null && y > 1940 && y <= DateTime.now().year) (byDecade[y ~/ 10 * 10] ??= []).add(t);
    }
    final decades = [for (final e in byDecade.entries) if (e.value.length >= 10) e];
    if (decades.isNotEmpty) {
      final e = decades[rnd.nextInt(decades.length)];
      final label = e.key >= 2000 ? 'anos ${e.key}' : 'anos ${e.key % 100}';
      out.add(('decada:${e.key}', 'Viagem aos $label', '📻', 'Músicas suas lançadas nos $label.', take(e.value, '📻 ${e.key}s')));
    }
    // estilo que você quase não tem (entre 8 e 25 músicas)
    final byStyle = <String, List<Track>>{};
    for (final t in library) {
      for (final s in Styles.of(t).take(2)) {
        (byStyle[s] ??= []).add(t);
      }
    }
    final rare = [for (final e in byStyle.entries) if (e.value.length >= minTracks && e.value.length <= 25) e];
    if (rare.isNotEmpty) {
      final e = rare[rnd.nextInt(rare.length)];
      out.add(('estilo:${e.key}', 'Mergulho no ${e.key}', '🔎', 'Um estilo que aparece pouco na sua biblioteca.', take(e.value, '🔎 ${e.key}')));
    }
    // um ano específico
    final byYear = <int, List<Track>>{};
    for (final t in library) {
      if (t.year != null && t.year! > 1940) (byYear[t.year!] ??= []).add(t);
    }
    final years = [for (final e in byYear.entries) if (e.value.length >= 10) e];
    if (years.isNotEmpty) {
      final e = years[rnd.nextInt(years.length)];
      out.add(('ano:${e.key}', 'O som de ${e.key}', '🗓️', 'Tudo o que você tem de ${e.key}.', take(e.value, '🗓️ ${e.key}')));
    }
    return out;
  }

  /// Tira as vencidas (e as que perderam músicas demais) e cria novas até ter [target] no ar.
  /// [libraryIds]: ids que ainda existem. Devolve o estado novo (o mesmo objeto se nada mudou).
  static ExperienceState refresh(ExperienceState state, List<Track> library,
<<<<<<< HEAD
      {PlayStats stats = PlayStats.empty,
      int? nowMs,
      Random? rnd,
      Sheet Function(Track)? sheetOf,
      AiFacts? Function(Track)? aiOf,
      List<AiTheme> aiThemes = const []}) {
=======
      {PlayStats stats = PlayStats.empty, int? nowMs, Random? rnd, Sheet Function(Track)? sheetOf}) {
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final random = rnd ?? Random();
    final ids = {for (final t in library) t.id};
    var changed = false;
    final active = <Experience>[];
    for (final e in state.active) {
      if (e.expired(now)) {
        changed = true;
        continue;
      }
      final kept = [for (final id in e.trackIds) if (ids.contains(id)) id];
      if (kept.length < minTracks ~/ 2) {
        changed = true;
        continue;
      }
      if (kept.length != e.trackIds.length) {
        changed = true;
        active.add(Experience(
            id: e.id, title: e.title, emoji: e.emoji, kind: e.kind, trackIds: kept, reasons: e.reasons, why: e.why,
<<<<<<< HEAD
            missing: e.missing, createdAt: e.createdAt, expiresAt: e.expiresAt));
=======
            createdAt: e.createdAt, expiresAt: e.expiresAt));
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
      } else {
        active.add(e);
      }
    }
    if (active.length >= target || library.length < minTracks) {
      return changed ? ExperienceState(active, state.recent) : state;
    }
    final recent = [...state.recent];
    final busy = {for (final e in active) e.id, ...recent};
    int expiry() => now + (minHours + random.nextInt(maxHours - minHours + 1)) * _hour;

    // surpresas primeiro (no máximo [maxSurprises] no ar)
    var surprisesOn = active.where((e) => e.kind == 'surpresa').length;
    if (surprisesOn < maxSurprises) {
      final list = surprises(library, stats, now, random)..shuffle(random);
      for (final (id, title, emoji, why, tracks) in list) {
        if (surprisesOn >= maxSurprises || active.length >= target) break;
        if (busy.contains(id) || tracks.length < minTracks) continue;
        active.add(Experience(
            id: id, title: title, emoji: emoji, kind: 'surpresa', trackIds: [for (final (t, _) in tracks) t.id!],
            reasons: {for (final (t, l) in tracks) t.id!: l}, why: why, createdAt: now, expiresAt: expiry()));
        recent.add(id);
        busy.add(id);
        surprisesOn++;
        changed = true;
      }
    }
<<<<<<< HEAD
    // temas da IA da semana (no máximo [maxAi] no ar, cada um uma vez só)
    var aiOn = active.where((e) => e.kind == 'ia').length;
    for (final th in aiThemes) {
      if (aiOn >= maxAi || active.length >= target) break;
      final r = th.toRecipe();
      if (busy.contains(r.id)) continue;
      final tracks = pick(r, library, stats: stats, rnd: random, sheetOf: sheetOf, aiOf: aiOf);
      recent.add(r.id); // mesmo sem músicas: não tenta de novo toda hora
      busy.add(r.id);
      changed = true;
      if (tracks.isEmpty) continue;
      active.add(Experience(
          id: r.id, title: r.title, emoji: r.emoji, kind: 'ia', trackIds: [for (final (t, _) in tracks) t.id!],
          reasons: {for (final (t, l) in tracks) t.id!: l}, why: th.why.isEmpty ? 'Tema inventado pela IA para a sua biblioteca.' : th.why,
          missing: missingFrom(th.missing, library), createdAt: now, expiresAt: expiry()));
      aiOn++;
    }
=======
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
    // cardápio, em ordem sorteada, pulando as usadas há pouco; se faltar, a 2ª volta aceita as recentes
    final menu = [...experienceMenu]..shuffle(random);
    final tried = <String>{};
    for (final r in [...menu, ...menu]) {
      if (active.length >= target) break;
      final second = tried.contains(r.id);
      if (active.any((e) => e.id == r.id) || (!second && busy.contains(r.id))) {
        tried.add(r.id);
        continue;
      }
      if (second && !recent.contains(r.id)) continue; // já tentada e sem músicas suficientes
      tried.add(r.id);
<<<<<<< HEAD
      final tracks = pick(r, library, stats: stats, rnd: random, sheetOf: sheetOf, aiOf: aiOf);
=======
      final tracks = pick(r, library, stats: stats, rnd: random, sheetOf: sheetOf);
>>>>>>> 6975244986c5c8a7b6324eb77efc31f8f10b277e
      if (tracks.isEmpty) continue;
      final top = r.scenes.keys.map((k) => TrackSheet.sceneByKey[k]?.label).whereType<String>().take(2).join(' e ');
      active.add(Experience(
          id: r.id, title: r.title, emoji: r.emoji, kind: 'menu', trackIds: [for (final (t, _) in tracks) t.id!],
          reasons: {for (final (t, l) in tracks) t.id!: l}, why: 'Montada com as suas músicas de $top.', createdAt: now, expiresAt: expiry()));
      recent.add(r.id);
      busy.add(r.id);
      changed = true;
    }
    if (!changed) return state;
    return ExperienceState(active, recent.length > recentMemory ? recent.sublist(recent.length - recentMemory) : recent);
  }
}
