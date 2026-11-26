import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'clip_info.dart';
import 'error_log.dart';
import 'filename_parser.dart';
import 'gif_feedback.dart';
import 'gif_mix.dart';
import 'gif_providers.dart';
import 'gif_service.dart';
import 'lastfm.dart';
import 'lyrics.dart';
import 'models.dart';
import 'mood.dart';
import 'organizer.dart' show safeFolderName;
import 'service_health.dart';
import 'styles.dart';
import 'visual_search.dart';
import 'visual_tags.dart';

/// Máximo de GIFs por música (para não ocupar espaço demais).
const maxGifsPerTrack = 9;

/// Baixa GIFs da internet pelo plano visual da música (cenas, clima, título, artista, gênero, palavras do usuário),
/// guarda em `GIFs/Artista/Título/` e fixa na música. Depois funciona offline.
/// Padrão: anime (nekos.best, waifu.pics de reserva) + geral (Openverse e Wikimedia, licenças livres que
/// permitem baixar e guardar com crédito), intercalados por [GifMix] (~70% anime / ~30% geral).
class GifFetcher {
  final GifService gifs;
  final List<GifProvider> providers;
  final http.Client client;
  final int maxBytes;

  /// Não tenta de novo a mesma música antes disso (se a busca anterior não achou nada).
  final Duration retryAfter;

  final Set<int> _running = {};

  /// Chave do Last.fm (fica nas configurações do app). Vazia = sem Last.fm, usa o gênero.
  String? Function() lastFmKey = () => null;

  /// Converte as tags do Last.fm em pesquisas visuais e categorias de anime.
  final VisualTagMapper mapper = VisualTagMapper();

  /// Última situação da consulta ao Last.fm por música (para avisar na tela).
  final Map<int?, TagStatus> tagStatus = {};
  TagCache? _tagCache;
  String? _tagCacheRoot;
  ClipCache? _clipCache;

  /// Ler o clipe na Wikipédia (desligável nos testes).
  bool useClipInfo = true;

  /// Última situação do clipe por música (para mostrar "Do clipe: ...").
  final Map<int?, ClipInfo?> clipInfo = {};
  final Map<String, DateTime> _clipFailedAt = {};

  /// Ler a letra para tirar as cenas (desligável nos testes).
  bool useLyrics = true;

  /// A aba Internet deixa buscar letras agora? (sem: só as que já estão no cache)
  bool Function()? allowLyrics;

  /// Últimas cenas da letra por música (a letra mesmo nunca é guardada).
  final Map<int?, List<LyricScene>> lyricScenes = {};
  LyricsCache? _lyricsCache;
  String? _lyricsRoot;
  final Map<String, DateTime> _lyricsFailedAt = {};

  TempoCache? _tempoCache;
  String? _tempoRoot;
  final Map<String, DateTime> _tempoFailedAt = {};

  GifFeedback? _feedback;
  String? _feedbackRoot;

  /// Preferências que o usuário ensinou (👎 e downloads), em `GIFs/.preferencias.json`.
  GifFeedback? get feedback {
    final root = gifs.gifRoot;
    if (root == null) return null;
    if (_feedbackRoot != root) {
      _feedback = GifFeedback(File(p.join(root, '.preferencias.json')));
      _feedbackRoot = root;
    }
    return _feedback;
  }

  /// Álbum de trilha sonora (anime, jogo, filme): o nome vira busca. Ex.: "Naruto Original Soundtrack" -> "Naruto".
  static String? soundtrackName(String album) {
    final a = album.trim();
    if (a.isEmpty || a == unknownAlbum) return null;
    final re = RegExp(r'\b(o\.?s\.?t\.?|original (motion picture |game |video game )?soundtrack|soundtrack|original score|score|opening|ending|theme songs?|trilha sonora|anime)\b', caseSensitive: false);
    if (!re.hasMatch(a)) return null;
    final name = a.replaceAll(re, ' ').replaceAll(RegExp(r'[\(\)\[\]\-:|]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return name.length >= 2 ? name : null;
  }

  /// Fontes de GIF de anime por clima, em ordem: se a primeira cai, a próxima entra (plano B).
  final List<AnimeMoodSource> moodSources;

  /// Quais serviços caíram agora.
  final ServiceHealth health;

  GifFetcher(this.gifs,
      {required this.client,
      List<GifProvider>? providers,
      List<AnimeMoodSource>? moodSources,
      ServiceHealth? health,
      this.maxBytes = 8 * 1024 * 1024,
      this.retryAfter = const Duration(days: 3)})
      : providers = providers ??
            [
              NekosBestProvider(client),
              // gerais: licenças livres (CC/domínio público) permitem guardar no aparelho com crédito.
              // Fora do "Baixar para todas" para respeitar o limite de pedidos sem chave do Openverse.
              OpenverseProvider(client, allowBulk: false, minInterval: const Duration(seconds: 1)),
              WikimediaProvider(client, allowBulk: false),
            ],
        health = health ?? ServiceHealth(),
        moodSources = moodSources ??
            [
              ...(providers ?? const []).whereType<AnimeMoodSource>(),
              if (providers == null) ...[NekosBestProvider(client), WaifuPicsProvider(client)],
            ];

  /// Aviso da barra de status do Tocando agora, por música (ex.: "nekos.best fora do ar · usando GIFs guardados").
  /// Null quando está tudo normal.
  final Map<int?, String> outageStatus = {};

  /// GIFs guardados de outras músicas do mesmo clima, mostrados enquanto a fonte está fora do ar.
  /// Não são fixados na música: quando o serviço volta, ela ganha os dela.
  final Map<int?, List<String>> borrowed = {};

  String? statusFor(Track t) => outageStatus[t.id];

  bool isFetching(Track t) => _running.contains(t.id);

  /// Clima do gênero -> categorias de GIF de anime (nekos.best). A primeira regra que bater vale.
  static const _moods = <(String, List<String>)>[
    (r'romant|love|amor|bachata|kizomba', ['kiss', 'hug', 'cuddle', 'handhold', 'blush']),
    (r'\bemo\b|sad|triste|depress|sofr[eê]ncia', ['cry', 'hug', 'pat', 'sleep', 'pout']),
    (r'indie|alternative|alternativ|pop.?rock|soft rock|britpop|surf', ['run', 'highfive', 'thumbsup', 'wave', 'laugh']),
    (r'metal|rock|punk|hardcore|industrial|grunge|thrash|core\b|nu.?metal|djent|hard', ['punch', 'kick', 'shoot', 'slap', 'angry', 'yeet']),
    (r'rap|hip.?hop|trap|drill|grime|phonk', ['shoot', 'smug', 'dance', 'thumbsup', 'yeet']),
    (r'funk|disco|groove|boogie', ['dance', 'happy', 'clap', 'highfive', 'laugh']),
    (r'electr|edm|house|techno|trance|dubstep|drum|bass|eurobeat|synth|hyperpop', ['dance', 'happy', 'yeet', 'highfive', 'run']),
    (r'j-?pop|j-?rock|vocaloid|anime|anisong|city pop|idol', ['happy', 'dance', 'wave', 'wink', 'smile']),
    (r'k-?pop|pop|teen', ['dance', 'happy', 'wave', 'smile', 'wink']),
    (r'sertanejo|country|forr[oó]|pagode|samba|ax[eé]|arrocha|piseiro|brega|cumbia|reggaeton|latin|folk', ['dance', 'happy', 'clap', 'highfive', 'laugh', 'handhold']),
    (r'reggae|ska|dub\b', ['dance', 'happy', 'nod', 'smile', 'thumbsup']),
    (r'mpb|bossa|jazz|blues|soul|r&b|rnb|motown|swing', ['smile', 'nod', 'cuddle', 'handhold', 'pat']),
    (r'gospel|worship|religi|cristã|christian', ['smile', 'hug', 'clap', 'happy', 'handhold']),
    (r'soundtrack|trilha|\bost\b|score|game|epic|[eé]pic', ['run', 'kick', 'punch', 'thumbsup', 'wave']),
    (r'lo.?fi|chill|ambient|acoustic|ac[uú]stic|classical|cl[aá]ssic|piano|instrumental|new age|orchestr|orquest|ballad|balada', ['sleep', 'yawn', 'cuddle', 'pat', 'smile']),
    (r'kids|infantil|children', ['happy', 'wave', 'pat', 'hug', 'smile']),
  ];

  /// Gênero conhecido -> categorias do clima; gênero desconhecido -> mistura neutra; sem gênero -> nada.
  static List<String> moodCategories(String genre) {
    final g = genre.toLowerCase().trim();
    if (g.isEmpty || g == 'desconhecido') return const [];
    // a biblioteca tem poucos gêneros diferentes: guarda a resposta de cada um
    // (antes compilava as expressões da tabela a cada chamada, e isso roda para cada música na busca, no mix e nas coleções)
    final known = _moodCache[g];
    if (known != null) return known;
    if (_moodCache.length > 4000) _moodCache.clear();
    return _moodCache[g] = _moodFor(g);
  }

  static final Map<String, List<String>> _moodCache = {};
  static final List<(RegExp, List<String>)> _moodRes = [for (final (re, cats) in _moods) (RegExp(re), cats)];

  static List<String> _moodFor(String g) {
    for (final (re, cats) in _moodRes) {
      if (re.hasMatch(g)) return cats;
    }
    return const ['happy', 'wave', 'smile', 'thumbsup', 'dance'];
  }

  /// Sem gênero: mistura neutra (os GIFs de anime sempre vêm).
  static const neutralMoods = ['happy', 'wave', 'smile', 'thumbsup', 'dance', 'laugh'];

  /// As buscas por grupo, na ordem das vagas ([slotOrder]):
  /// até 5 de cena (palavras do usuário, letra, clipe, dicionário), 2 de reação de anime, o resto título+artista.
  /// Artista e gênero ficam de reserva, para quando os outros grupos não acham nada.
  /// [tagAnime]: categorias de anime vindas das tags do Last.fm.
  /// [scenes]: pesquisas de cena já em ordem (letra, clipe, dicionário); com alguma, não busca "artista live" nem "gênero concert".
  /// [bpm]/[energy]: andamento da música (muda a ordem dos climas).
  static GifPlan planFor(Track t,
      {List<String> extras = const [],
      List<String> tagAnime = const [],
      List<MusicTag>? tags,
      List<String> scenes = const [],
      int? bpm,
      double? energy}) {
    final parsed = parseFileName(t.title);
    final title = parsed.title.trim();
    var artist = t.artist.trim();
    if (artist.isEmpty || artist == unknownArtist) artist = parsed.artist ?? '';
    final genre = t.genre.trim();
    final hasGenre = genre.isNotEmpty && genre.toLowerCase() != 'desconhecido';
    // "Industrial Metal" -> também "metal concert"
    final mainGenre = hasGenre ? genre.split(RegExp(r'[\s/,;-]+')).where((w) => w.length > 1).last : '';
    List<String> uniq(List<String> qs) {
      final seen = <String>{};
      return qs.map((q) => q.trim()).where((q) => q.length >= 2 && seen.add(q.toLowerCase())).toList();
    }

    final hasScene = uniq(scenes).isNotEmpty;
    return GifPlan(
      scenes: uniq([...extras, ...scenes]),
      title: uniq([if (artist.isNotEmpty) '$title $artist', title]),
      artist: uniq([if (artist.isNotEmpty) artist, if (artist.isNotEmpty) '$artist band', if (artist.isNotEmpty && !hasScene) '$artist live']),
      genre: uniq([if (hasGenre) genre, if (hasGenre && !hasScene) '$mainGenre concert', if (hasGenre) '$mainGenre music']),
      animeQueries: uniq(extras),
      moods: moodsFor(t, tagAnime: tagAnime, hasGenre: hasGenre, tags: tags, bpm: bpm, energy: energy),
    );
  }

  /// Categorias de anime da música. O clima escolhido pelo usuário é absoluto (ignora pontos, andamento e letra).
  /// Automático: os pontos de cada clima ([MoodGuess.scores]) com o andamento aplicado viram a ordem
  /// ([categoriesFromScores]); sem ponto nenhum, as tags do Last.fm, senão o gênero, senão a mistura neutra.
  static List<String> moodsFor(Track t,
      {List<String> tagAnime = const [], bool? hasGenre, List<MusicTag>? tags, int? bpm, double? energy}) {
    final chosen = t.chosenMood;
    if (chosen != null) return chosen.categories;
    final scores = MoodClues.withTempo(MoodClues.forTrack(t, tags: tags).scores, bpm: bpm ?? t.bpm, energy: energy);
    final ordered = categoriesFromScores(scores, tagAnime: tagAnime);
    if (ordered.isNotEmpty) return ordered;
    if (tagAnime.isNotEmpty) return tagAnime;
    final g = t.genre.trim();
    final known = hasGenre ?? (g.isNotEmpty && g.toLowerCase() != 'desconhecido');
    return known ? moodCategories(g) : neutralMoods;
  }

  /// Quantas categorias de cada clima entram quando há dois climas na disputa.
  static const perMood = 3;

  /// Pontos dos climas -> categorias de anime, em ordem. Função pura (testável).
  /// - Só um clima com pontos: as categorias dele.
  /// - Líder com folga ([MoodClues.minLead]): 3 do líder, depois 3 do 2º (o 2º que briga com o líder não entra).
  /// - Folga menor: intercala os dois (3 de cada).
  /// Depois vêm as categorias das tags ([tagAnime]), sem repetir e sem as que brigam com o líder.
  /// Sem ponto nenhum: vazio (quem chama usa o gênero).
  static List<String> categoriesFromScores(Map<Mood, double> scores, {List<String> tagAnime = const []}) {
    final ranked = scores.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    if (ranked.isEmpty) return const [];
    final lead = ranked.first.key;
    Mood? second = ranked.length > 1 ? ranked[1].key : null;
    final clear = second == null || ranked.first.value - ranked[1].value >= MoodClues.minLead - 1e-9;
    if (second != null && clear && _clashes[lead]!.contains(second)) second = null;
    final out = <String>[];
    void add(String c) {
      if (!out.contains(c)) out.add(c);
    }

    if (second == null) {
      lead.categories.forEach(add);
    } else if (clear) {
      lead.categories.take(perMood).forEach(add);
      second.categories.take(perMood).forEach(add);
    } else {
      for (var i = 0; i < perMood; i++) {
        if (i < lead.categories.length) add(lead.categories[i]);
        if (i < second.categories.length) add(second.categories[i]);
      }
    }
    // categorias das tags que brigam com o líder saem (ex.: soco numa música triste só porque a banda é de rock);
    // num empate, as do 2º clima continuam valendo
    final clash = {for (final m in _clashes[lead]!) ...m.categories}
        .difference({...lead.categories, if (second != null && !clear) ...second.categories});
    for (final c in tagAnime) {
      if (!clash.contains(c)) add(c);
    }
    return out;
  }

  static const _clashes = <Mood, List<Mood>>{
    Mood.calmo: [Mood.acao, Mood.festa],
    Mood.triste: [Mood.acao, Mood.festa],
    Mood.romantico: [Mood.acao],
    Mood.festa: [Mood.triste, Mood.calmo],
    Mood.epico: [Mood.triste, Mood.calmo],
    Mood.acao: [Mood.calmo, Mood.romantico, Mood.triste],
  };

  /// Limite de pedidos por provedor em cada música (respeita os limites das fontes; o player não espera por isso).
  static const maxRequestsPerProvider = 5;

  /// Tempo máximo de cada pedido a um provedor.
  static const providerTimeout = Duration(seconds: 12);

  /// Clima da música (escolhido ou automático) -> pesquisa de cena para o provedor geral.
  static const moodQueries = {
    Mood.calmo: 'calm night sky',
    Mood.triste: 'rain window',
    Mood.romantico: 'sunset couple',
    Mood.festa: 'party lights',
    Mood.epico: 'epic landscape',
    Mood.acao: 'fight scene',
  };

  static String? moodQueryFor(Track t, {List<MusicTag>? tags}) {
    final m = t.chosenMood ?? MoodClues.forTrack(t, tags: tags).mood;
    return m == null ? null : moodQueries[m];
  }

  /// Vagas guardadas para os GIFs de anime (só baixados música a música, nunca em massa).
  static const animeSlots = 2;

  /// Pastas onde os GIFs da música ficam: `GIFs/Artista/Título/`.
  static (String, String) dirsFor(Track t) {
    final parsed = parseFileName(t.title);
    final artist = t.artist == unknownArtist || t.artist.trim().isEmpty ? (parsed.artist ?? 'Outros') : t.artist;
    return (safeFolderName(artist), safeFolderName(parsed.title));
  }

  /// Título e artista limpos, do jeito que o Last.fm conhece.
  static (String, String) namesFor(Track t) {
    final parsed = parseFileName(t.title);
    var artist = t.artist.trim();
    if (artist.isEmpty || artist == unknownArtist) artist = parsed.artist ?? '';
    return (parsed.title.trim(), artist);
  }

  TagCache? get _tags {
    final root = gifs.gifRoot;
    if (root != null && _tagCacheRoot != root) {
      _tagCache = TagCache(File(p.join(root, '.lastfm.json')));
      _tagCacheRoot = root;
    }
    return _tagCache;
  }

  /// Tags já guardadas da música (sem internet, mesmo vencidas). Usadas pelo clima automático.
  List<MusicTag>? cachedTags(Track t) {
    final (title, artist) = namesFor(t);
    return _tags?.get(artist, title, ignoreAge: true)?.tags;
  }

  /// Tags do Last.fm da música, com cache em `GIFs/.lastfm.json`. Nunca lança erro.
  Future<TagResult> tagsFor(Track t) async {
    final (title, artist) = namesFor(t);
    var r = _tags?.get(artist, title);
    if (r == null) {
      try {
        r = await LastFmClient(client, lastFmKey()).topTags(artist, title);
      } catch (e) {
        errorLog.info('GIFs', 'Last.fm não respondeu', e);
        r = const TagResult(TagStatus.badResponse);
      }
      _tagCache?.put(artist, title, r);
      // tags novas podem mudar o clima automático desta música
      if (r.tags.isNotEmpty) {
        MoodClues.invalidate();
        Styles.invalidate(); // os estilos e as réguas também vêm das tags
      }
    }
    tagStatus[t.id] = r.status;
    return r;
  }

  /// Cenas do videoclipe pela Wikipédia, com cache em `GIFs/.clipes.json`. Nunca lança erro.
  Future<ClipInfo?> clipFor(Track t) async {
    if (!useClipInfo) return null;
    final (title, artist) = namesFor(t);
    final root = gifs.gifRoot;
    if (root != null) _clipCache ??= ClipCache(File(p.join(root, '.clipes.json')));
    final (hit, cached) = _clipCache?.get(artist, title) ?? (false, null);
    if (hit) return clipInfo[t.id] = cached;
    // sem internet há pouco: não tenta de novo agora
    final failed = _clipFailedAt[ClipCache.keyFor(artist, title)];
    if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 10)) return null;
    final c = ClipInfoClient(client);
    ClipInfo? info;
    try {
      info = await c.lookup(artist, title);
    } catch (e) {
      errorLog.info('GIFs', 'Wikipédia não respondeu (cenas do clipe)', e);
      return null;
    }
    _clipCache?.put(artist, title, info, reached: c.reached);
    if (!c.reached) _clipFailedAt[ClipCache.keyFor(artist, title)] = DateTime.now();
    return clipInfo[t.id] = info;
  }

  /// Cenas tiradas da letra (LRCLIB, senão lyrics.ovh), com cache em `GIFs/.lyrics.json`.
  /// A letra não é mostrada nem gravada: só as cenas. Falhou sem internet = não tenta por 10 min. Nunca lança erro.
  /// [online] false: só o que já está no cache.
  Future<List<LyricScene>> lyricScenesFor(Track t, {bool online = true}) async {
    if (!useLyrics) return const [];
    final (title, artist) = namesFor(t);
    final root = gifs.gifRoot;
    if (root != null && _lyricsRoot != root) {
      _lyricsCache = LyricsCache(File(p.join(root, '.lyrics.json')));
      _lyricsRoot = root;
    }
    final cached = _lyricsCache?.get(artist, title);
    if (cached != null) return lyricScenes[t.id] = cached;
    if (!online || allowLyrics?.call() == false) return const [];
    final key = LyricsCache.keyFor(artist, title);
    final failed = _lyricsFailedAt[key];
    if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 10)) return const [];
    final c = LyricsClient(client);
    List<LyricScene> found;
    try {
      found = await c.scenes(artist, title, album: t.album == unknownAlbum ? '' : t.album);
    } catch (e) {
      errorLog.info('GIFs', 'Letra não respondeu (cenas da letra)', e);
      _lyricsFailedAt[key] = DateTime.now();
      return const [];
    }
    if (!c.reached) {
      _lyricsFailedAt[key] = DateTime.now();
      return const [];
    }
    _lyricsCache?.put(artist, title, found);
    return lyricScenes[t.id] = found;
  }

  /// Andamento da música: tag TBPM do arquivo; se vazia, Last.fm `track.getInfo` (cache em `GIFs/.ritmo.json`).
  /// O BPM achado no Last.fm fica gravado na música. [online] false: só o que já se sabe. Nunca lança erro.
  Future<TrackTempo> tempoFor(Track t, {bool online = true}) async {
    final (title, artist) = namesFor(t);
    final root = gifs.gifRoot;
    if (root != null && _tempoRoot != root) {
      _tempoCache = TempoCache(File(p.join(root, '.ritmo.json')));
      _tempoRoot = root;
    }
    final cached = _tempoCache?.get(artist, title);
    final own = MoodClues.validBpm(t.bpm);
    if (own != null) return TrackTempo(bpm: own, energy: cached?.energy);
    if (cached != null) return cached;
    final apiKey = lastFmKey()?.trim() ?? '';
    if (!online || apiKey.isEmpty) return const TrackTempo();
    final key = TagCache.keyFor(artist, title);
    final failed = _tempoFailedAt[key];
    if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 10)) return const TrackTempo();
    final r = await LastFmClient(client, apiKey).trackTempo(artist, title);
    if (r == null) {
      _tempoFailedAt[key] = DateTime.now();
      return const TrackTempo();
    }
    _tempoCache?.put(artist, title, r);
    final bpm = r.bpm;
    if (bpm != null && t.id != null) {
      try {
        await gifs.db.setBpm(t.id!, bpm);
      } catch (e) {
        errorLog.info('GIFs', 'Não deu para guardar o andamento da música', e);
      }
    }
    return r;
  }

  /// Grupo das pesquisas que vêm da letra (aparece assim na tela "GIFs pela vibe").
  static const lyricsGroup = 'Da letra';

  /// Pesquisas visuais da música, em ordem: palavras do usuário (e nome da trilha sonora), cenas da letra,
  /// cenas do clipe, depois as do dicionário pelas tags do Last.fm; sem nada, a alternativa básica.
  /// O clima escolhido no selo pesa mais que as tags. [lyrics] false: cenas da letra só do cache.
  Future<VisualPlan> visualPlanFor(Track t, {bool lyrics = true}) async {
    final (title, artist) = namesFor(t);
    final r = await tagsFor(t);
    final clip = await clipFor(t);
    final fromLyrics = await lyricScenesFor(t, online: lyrics);
    var plan = mapper.convert(r.tags, mood: t.chosenMood, title: title, artist: artist, genre: t.genre, scenes: clip?.scenes ?? const {});
    // palavras do usuário (música e artista) e o nome da trilha sonora vêm na frente: são as mais específicas
    final top = plan.all.isEmpty ? 1.0 : plan.all.first.score;
    final extras = gifs.extrasFor(t.artist, title);
    final ost = soundtrackName(t.album);
    final front = <VisualQuery>[
      for (final e in extras)
        for (final w in e.split(',').map((x) => x.trim()).where((x) => x.length >= 2)) VisualQuery(w, 'Suas palavras', top * 2),
      for (final (i, s) in fromLyrics.indexed) VisualQuery(s.query, lyricsGroup, top * (1.5 - i * 0.02)),
      if (ost != null) VisualQuery(ost, 'Trilha sonora', top * 1.4),
    ];
    // cenas do clipe vêm antes das pesquisas que saem só das tags
    final clipLabels = {
      for (final k in clip?.scenes.keys ?? const <String>[]) ...visualTags.where((e) => e.scene && e.key == k).map((e) => e.label),
    };
    final clipFirst = clipLabels.isEmpty
        ? plan.all
        : [
            for (final q in plan.all) clipLabels.contains(q.group) ? VisualQuery(q.text, q.group, top * 1.1 + q.score * 0.01) : q,
          ];
    if (front.isNotEmpty || clipLabels.isNotEmpty) {
      final seen = <String>{};
      final merged = [...front, ...clipFirst]..sort((a, b) => b.score.compareTo(a.score));
      plan = VisualPlan(
        all: merged.where((q) => seen.add(VisualTagMapper.normalize(q.text))).toList(),
        anime: plan.anime,
        matchedTags: plan.matchedTags,
        fromTags: plan.fromTags,
        clipScenes: plan.clipScenes,
      );
    }
    return feedback?.apply(plan, artist, title) ?? plan;
  }

  /// Texto pronto para a busca na web (inclui as palavras extras).
  String webQueryFor(Track t) {
    final parsed = parseFileName(t.title);
    final artist = t.artist == unknownArtist ? (parsed.artist ?? '') : t.artist;
    return [parsed.title, artist, ...gifs.extrasFor(t.artist, parsed.title), 'gif'].where((s) => s.trim().isNotEmpty).join(' ');
  }

  String? _logPath() => gifs.gifRoot == null ? null : p.join(gifs.gifRoot!, '.buscas.json');

  Map<String, dynamic> _readLog() {
    final path = _logPath();
    return path == null ? {} : _readJson(path);
  }

  /// Endereço -> arquivo já baixado (GIFs/.indice.json), para não baixar o mesmo GIF duas vezes.
  Map<String, dynamic> _readIndex() {
    final root = gifs.gifRoot;
    return root == null ? {} : _readJson(p.join(root, '.indice.json'));
  }

  void _writeIndex(Map<String, dynamic> index) {
    final root = gifs.gifRoot;
    if (root == null) return;
    _writeJson(p.join(root, '.indice.json'), index);
  }

  void _writeLog(Map<String, dynamic> log) {
    final path = _logPath();
    if (path == null) return;
    _writeJson(path, log);
  }

  /// Registro e índice ficam na memória depois da primeira leitura: antes eram lidos e decodificados do
  /// disco a cada música que começava a tocar. Só esta classe grava esses arquivos. Como as buscas
  /// usam o mesmo mapa, duas buscas ao mesmo tempo não apagam mais o registro uma da outra.
  final Map<String, Map<String, dynamic>> _json = {};

  Map<String, dynamic> _readJson(String path) {
    final known = _json[path];
    if (known != null) return known;
    var m = <String, dynamic>{};
    try {
      final f = File(path);
      if (f.existsSync()) m = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
    } catch (e) {
      errorLog.info('GIFs', 'Registro de buscas de GIF ilegível (${p.basename(path)}), recomeçado', e);
    }
    return _json[path] = m;
  }

  void _writeJson(String path, Map<String, dynamic> m) {
    _json[path] = m;
    try {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(m));
    } catch (e) {
      errorLog.warn('GIFs', 'Não deu para salvar ${p.basename(path)} na pasta de GIFs', error: e);
    }
  }

  /// Versão da regra de escolha. Músicas buscadas com uma regra antiga são refeitas.
  static const planVersion = 5; // 5: vagas por cena/anime/título, clima pelos pontos + andamento, cenas da letra

  /// Nomes dos arquivos baixados automaticamente (hash do conteúdo).
  static final _autoName = RegExp(r'^[0-9a-f]{12}\.gif$');

  /// Baixa GIFs até a música ter [maxGifsPerTrack] fixados. Retorna quantos baixou.
  /// Sem [force], não repete uma busca recente que não achou nada.
  /// Com [bulk] (biblioteca toda), não usa fontes que proíbem download em massa.
  Future<int> fetchFor(Track t, {bool force = false, bool bulk = false}) async {
    final root = gifs.gifRoot;
    if (root == null || t.id == null || _running.contains(t.id)) return 0;
    // em massa só usa fontes que permitem; se nenhuma permite, espera a música tocar
    if (!providers.any((pr) => !bulk || pr.allowBulk)) return 0;
    final key = t.path;
    final log = _readLog();
    final entry = log[key];
    final version = entry is Map ? (entry['v'] as num?)?.toInt() ?? 1 : (entry == null ? planVersion : 1);
    final last = DateTime.tryParse('${entry is Map ? entry['t'] : entry ?? ''}');
    final (artistDir, titleDir) = dirsFor(t);
    final dest = Directory(p.join(root, artistDir, titleDir));

    var pinned = (await gifs.db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    // tags do Last.fm (do cache quando já consultou): escolhem as categorias de anime
    final visual = await visualPlanFor(t, lyrics: !bulk);
    final tagAnime = visual.fromTags ? visual.anime : const <String>[];
    // a música foi buscada antes de ter as tags: refaz os automáticos uma vez com elas
    final redoForTags = entry is Map && entry['lfm'] != true && tagAnime.isNotEmpty && t.chosenMood == null && !bulk;
    if (version < planVersion || redoForTags) {
      await _clearAuto(t, pinned, root);
      pinned = (await gifs.db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    }
    final animeDone = entry is Map && entry['anime'] == true;
    // andamento: só música a música (em massa, só o que já se sabe)
    final tempo = await tempoFor(t, online: !bulk);
    // cenas em ordem (letra, clipe, dicionário); as palavras do usuário e o nome/artista entram pelo planFor
    const notScene = {'Suas palavras', 'Música', 'Artista'};
    final sceneQueries = [for (final q in visual.all) if (!notScene.contains(q.group)) q.text].take(8).toList();
    final plan0 = planFor(t,
        extras: gifs.extrasFor(t.artist, parseFileName(t.title).title),
        tagAnime: tagAnime,
        tags: cachedTags(t),
        scenes: sceneQueries,
        bpm: tempo.bpm,
        energy: tempo.energy);
    // em massa, deixa vagas para os GIFs de anime que vêm quando a música tocar
    final reserve = bulk && plan0.anime && providers.any((pr) => pr.animeOnly) ? animeSlots : 0;
    final need = maxGifsPerTrack - reserve - pinned.length;
    if (need <= 0) return 0;
    final recent = last != null && DateTime.now().difference(last) < retryAfter;
    final animePending = !bulk && plan0.anime && !animeDone;
    if (version >= planVersion && !redoForTags && !force && recent && !animePending) return 0;

    _running.add(t.id!);
    gifs.changed();
    var saved = 0;
    try {
      final plan = plan0;
      final usable = providers.where((pr) => (!bulk || pr.allowBulk) && (!pr.animeOnly || plan.anime)).toList();
      // plano B: quais fontes de anime falharam e se alguma respondeu
      final moodFailures = <String, Object>{};
      final moodUsed = <String>{};
      final (title0, artist0) = namesFor(t);
      final rejected = feedback?.rejected(artist0, title0) ?? const <String>{};
      final fb = feedback;
      // cena, clima, título, artista, gênero e palavras do usuário -> provedor geral;
      // palavras do usuário e nome da trilha sonora -> também a busca de anime
      final routes = routeQueries(
        userWords: plan.animeQueries,
        scenes: [for (final s in plan.scenes) if (!plan.animeQueries.contains(s)) s],
        ost: soundtrackName(t.album),
        mood: moodQueryFor(t, tags: cachedTags(t)),
        title: plan.title,
        artist: plan.artist,
        genre: plan.genre,
      );
      // candidatos bons suficientes por lado (sobra para downloads que falham e repetidos)
      final enough = need * 2;

      // Um provedor: pesquisas na ordem de importância, no máximo [maxRequestsPerProvider] pedidos,
      // cada um com [providerTimeout]. Falhou = para nesta música (os outros provedores seguem).
      Future<List<GifCandidate>> ask(GifProvider prov, List<RoutedQuery> queries) async {
        final out = <GifCandidate>[];
        var asked = 0;
        for (final q in queries) {
          if (asked >= maxRequestsPerProvider || out.length >= enough || health.isDown(prov.name)) break;
          asked++;
          try {
            final got = await prov.search(q.text, limit: 15).timeout(providerTimeout);
            health.up(prov.name);
            for (final (i, c) in got.indexed) {
              // fraco (nada da pesquisa no metadado ou nota baixa) não entra, nem para completar
              if (queryMatch(q.text, c.meta) <= 0) continue;
              var score = relevance(q, c.meta, i);
              if (fb != null) score *= fb.weight(artist0, title0, q.text).clamp(0.15, 1.2);
              if (score < minGoodScore) continue;
              out.add(c.ranked(query: q.text, score: score, kind: kindOf(c, animeOnlySource: prov.animeOnly)));
            }
          } catch (e) {
            // sem internet, fora do ar, limite de pedidos ou demorou demais
            errorLog.info('GIFs', 'Busca de GIFs falhou em ${prov.name}', e);
            health.down(prov.name, e);
            if (prov is AnimeMoodSource) moodFailures[prov.name] = e;
            break;
          }
        }
        return out;
      }

      // em massa as fontes de anime não entram (termos do nekos.best); música a música, sim
      final sources = bulk ? const <AnimeMoodSource>[] : moodSources;
      final climas = _readClimas();

      // GIFs de anime pelas categorias do clima: um de cada categoria por vez, na ordem de moodsFor
      Future<List<GifCandidate>> moodGifs() async {
        final out = <GifCandidate>[];
        if (sources.isEmpty || plan.moods.isEmpty) return out;
        // categoria com 2 ou mais 👎 do artista sai (um 👎 só não tira, mas desce)
        final cats = plan.moods.where((c) => fb == null || fb.categoryDislikes(artist0, c) < 2).toList();
        for (final (ci, cat) in cats.take(4).indexed) {
          // a primeira fonte que responder vale; se ela caiu, a próxima (waifu.pics) entra no lugar
          for (final src in sources) {
            if (health.isDown(src.name)) continue;
            try {
              // pede mais do que precisa: sobra para pular os que outras músicas já usam
              final got = await src.random(cat, amount: 5).timeout(providerTimeout);
              health.up(src.name);
              if (got.isEmpty) continue;
              moodUsed.add(src.name);
              var w = 1.0;
              if (fb != null) {
                w = fb.weight(artist0, title0, 'anime:$cat').clamp(0.15, 1.2).toDouble();
                if (fb.categoryDislikes(artist0, cat) == 1) w *= 0.8;
              }
              for (final (j, c) in got.indexed) {
                if (c.category != null && nekosCategory(c.url) == null) climas[c.url] = c.category;
                out.add(c.ranked(query: 'anime:$cat', score: (0.85 - j * 0.04 - ci * 0.01) * w, kind: GifKind.anime));
              }
              break;
            } catch (e) {
              errorLog.info('GIFs', '${src.name} não respondeu', e);
              health.down(src.name, e);
              moodFailures[src.name] = e;
            }
          }
        }
        return out;
      }

      // anime e geral na mesma seleção, ao mesmo tempo: a falha de um não cancela o outro
      final lists = await Future.wait<List<GifCandidate>>([
        for (final pr in usable.where((pr) => !pr.animeOnly)) ask(pr, routes.general).catchError((Object _) => <GifCandidate>[]),
        for (final pr in usable.where((pr) => pr.animeOnly)) ask(pr, routes.anime).catchError((Object _) => <GifCandidate>[]),
        moodGifs().catchError((Object _) => <GifCandidate>[]),
      ]);
      // mesmo endereço vindo de mais de um provedor/pesquisa: fica uma vez, com a melhor nota
      final best = <String, GifCandidate>{};
      for (final c in lists.expand((l) => l)) {
        if (rejected.contains(c.url)) continue; // o usuário disse que não combina
        final old = best[c.url];
        if (old == null || c.score > old.score) best[c.url] = c;
      }
      final mix = GifMix(
        anime: [for (final c in best.values) if (c.kind == GifKind.anime) c],
        general: [for (final c in best.values) if (c.kind != GifKind.anime) c],
        total: need,
      );

      // hashes do que a música já tem, para não repetir o mesmo GIF
      final have = pinned.map((g) => p.basenameWithoutExtension(g)).toSet();
      final index = _readIndex();
      final credits = <String>[];
      // GIFs que outras músicas já usam: ficam para o fim (só entram se faltar GIF novo)
      final reuse = <String>[];
      while (saved < need) {
        final c = mix.next();
        if (c == null) break;
        // 1) mesmo endereço já baixado para outra música: usa o mesmo arquivo, sem baixar
        final known = index[c.url] as String?;
        if (known != null && File(known).existsSync()) {
          if (have.contains(p.basenameWithoutExtension(known))) continue;
          if (rejected.contains(p.basenameWithoutExtension(known))) continue;
          if (await gifs.db.gifUsers(known) > 0) {
            reuse.add(known);
            continue;
          }
          have.add(p.basenameWithoutExtension(known));
          await gifs.db.pinGif(t.id!, known);
          mix.accept(c);
          saved++;
          continue;
        }
        final bytes = await _download(c.url);
        if (bytes == null) continue;
        final hash = sha1.convert(bytes).toString().substring(0, 12);
        if (rejected.contains(hash)) continue;
        if (!have.add(hash)) continue; // mesmo GIF vindo de outro endereço
        // 2) mesmo conteúdo já guardado (por outra música): aponta para ele, não grava de novo
        var target = gifs.findByName('$hash.gif');
        if (target != null && await gifs.db.gifUsers(target) > 0) {
          // outra música já tem esse GIF: guarda para o fim
          have.remove(hash);
          index[c.url] = target;
          reuse.add(target);
          continue;
        }
        if (target == null) {
          target = p.join(dest.path, '$hash.gif');
          await dest.create(recursive: true);
          await File(target).writeAsBytes(bytes, flush: true);
          gifs.addToCache(target);
          credits.add('$hash.gif · ${c.credit}');
        }
        index[c.url] = target;
        await gifs.db.pinGif(t.id!, target);
        mix.accept(c);
        saved++;
      }
      for (final g in reuse) {
        if (saved >= need) break;
        if (!have.add(p.basenameWithoutExtension(g))) continue;
        await gifs.db.pinGif(t.id!, g);
        saved++;
      }
      if (credits.isNotEmpty) {
        await File(p.join(dest.path, 'creditos.txt')).writeAsString('${credits.join('\n')}\n', mode: FileMode.append);
      }
      _writeIndex(index);
      _writeClimas(climas);
      final primary = sources.firstOrNull?.name;
      final outage = primary != null && plan.moods.isNotEmpty && health.wasDown(primary);
      if (outage) {
        // a internet funciona se alguma fonte respondeu ou se o serviço respondeu com erro (ex.: 503)
        final online = moodUsed.isNotEmpty ||
            moodFailures.values.any((e) => e is ServiceDown) ||
            health.reason(primary) is ServiceDown;
        final backup = moodUsed.where((n) => n != primary).firstOrNull;
        final lend = saved < need
            ? await _borrow(t, plan.moods, exclude: {...pinned, ...(await gifs.db.pinnedGifs(t.id!))}, max: need - saved)
            : const <String>[];
        borrowed[t.id] = lend;
        final what = backup != null
            ? 'GIFs do $backup no lugar'
            : (lend.isNotEmpty ? 'usando GIFs guardados' : 'sem GIFs guardados desse clima');
        outageStatus[t.id] = online ? '$primary fora do ar · $what' : 'Sem internet · $what';
        health.announce(primary, online: online, fallback: backup != null ? 'trazendo GIFs do $backup no lugar' : 'mostrando GIFs guardados no celular');
      } else {
        outageStatus.remove(t.id);
        borrowed.remove(t.id);
      }
      // nenhuma fonte de anime respondeu, ou a música terminou sem GIF nenhum (tudo falhou no download, por
      // exemplo): não marca como buscada, para tentar de novo da próxima vez que tocar (antes esperava 3 dias)
      final empty = saved == 0 && pinned.isEmpty;
      if (!(outage && moodUsed.isEmpty) && !empty) {
        log[key] = {'v': planVersion, 't': DateTime.now().toIso8601String(), 'anime': animeDone || !bulk, 'lfm': tagAnime.isNotEmpty};
        _writeLog(log);
      }
    } finally {
      _running.remove(t.id);
      await gifs.refresh();
    }
    return saved;
  }

  /// Clima de cada GIF de anime que não diz o clima no endereço (waifu.pics): `GIFs/.climas.json`.
  Map<String, dynamic> _readClimas() {
    final root = gifs.gifRoot;
    return root == null ? {} : _readJson(p.join(root, '.climas.json'));
  }

  void _writeClimas(Map<String, dynamic> m) {
    final root = gifs.gifRoot;
    if (root == null || m.isEmpty) return;
    _writeJson(p.join(root, '.climas.json'), m);
  }

  /// Categoria de clima de um GIF de anime baixado (pelo endereço de onde veio).
  String? categoryOf(String url) => nekosCategory(url) ?? _readClimas()[url] as String?;

  /// Plano B: GIFs de anime já guardados (de outras músicas) com o mesmo clima, sem baixar nada.
  Future<List<String>> _borrow(Track t, List<String> moods, {required Set<String> exclude, required int max}) async {
    if (max <= 0) return const [];
    final (title, artist) = namesFor(t);
    final rejected = feedback?.rejected(artist, title) ?? const <String>{};
    final want = moods.toSet();
    final seen = exclude.map((g) => p.basename(g)).toSet();
    final found = <String>[];
    for (final e in _readIndex().entries) {
      final path = e.value;
      if (path is! String) continue;
      final cat = categoryOf(e.key);
      if (cat == null || !want.contains(cat)) continue;
      if (rejected.contains(p.basenameWithoutExtension(path)) || rejected.contains(e.key)) continue;
      if (!seen.add(p.basename(path)) || !File(path).existsSync()) continue;
      found.add(path);
    }
    found.shuffle(Random(t.path.hashCode ^ DateTime.now().day));
    return found.take(max).toList();
  }

  /// Apaga só os GIFs que o app baixou sozinho (os escolhidos à mão ficam).
  Future<void> _clearAuto(Track t, List<String> pinned, String root) async {
    for (final g in pinned.where((g) => _autoName.hasMatch(p.basename(g)) && p.isWithin(root, g))) {
      await gifs.db.unpinGif(t.id!, g);
      // o arquivo só sai do celular se nenhuma outra música usa
      if (await gifs.db.gifUsers(g) == 0) {
        await File(g).delete().catchError((Object e) {
          errorLog.warn('GIFs', 'Não deu para apagar um GIF antigo', error: e);
          return File(g);
        });
      }
    }
  }

  /// Troca os GIFs automáticos da música (ex.: o clima mudou). Os escolhidos à mão ficam.
  Future<int> refetchFor(Track t) async {
    final root = gifs.gifRoot;
    if (root == null || t.id == null || _running.contains(t.id)) return 0;
    final pinned = (await gifs.db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    await _clearAuto(t, pinned, root);
    await gifs.refresh();
    return fetchFor(t, force: true);
  }

  /// 👎 num GIF salvo: tira da música, nunca mais volta sozinho (para a música e o artista)
  /// e a categoria de anime que trouxe ele perde força.
  Future<void> rejectFile(Track t, String path) async {
    final (title, artist) = namesFor(t);
    final hash = p.basenameWithoutExtension(path);
    final urls = [for (final e in _readIndex().entries) if (e.value == path) e.key];
    feedback?.reject(artist, title, [hash, ...urls]);
    // um 👎 conta uma vez por categoria, mesmo que o GIF tenha vindo de mais de um endereço
    for (final cat in {for (final u in urls) ?categoryOf(u)}) {
      feedback?.vote(artist, title, 'anime:$cat', -1);
      feedback?.dislikeCategory(artist, cat);
    }
    await gifs.deleteGif(path, trackId: t.id);
  }

  /// Baixa uns GIFs na hora para palavras que o usuário acabou de escrever (pedido dele: ver o resultado logo).
  /// GIPHY (anime primeiro) quando tem chave; anime do nekos.best sempre, pelas palavras extras.
  Future<int> fetchForKeywords(Track t, List<String> words, {GiphyProvider? giphy, int perWord = 3}) async {
    final (title, artist) = namesFor(t);
    final rejected = feedback?.rejected(artist, title) ?? const <String>{};
    final (artistDir, titleDir) = dirsFor(t);
    var saved = 0;
    if (giphy != null && (giphy.apiKey ?? '').isNotEmpty) {
      for (final w in words.where((w) => w.trim().length >= 2).take(3)) {
        try {
          final page = await TermPager(giphy, VisualQuery(w.trim(), 'Suas palavras', 2), exclude: rejected, artist: artist, song: title)
              .next(count: perWord + 2);
          var n = 0;
          for (final r in page) {
            if (n >= perWord) break;
            final bytes = await _download(r.gif.url);
            if (bytes == null) continue;
            final path = await gifs.saveForTrack(t, bytes,
                artistDir: artistDir, titleDir: titleDir, credit: 'GIPHY · ${r.gif.pageUrl.isEmpty ? r.gif.url : r.gif.pageUrl}');
            if (path != null) {
              n++;
              saved++;
            }
          }
        } catch (e) {
          // sem internet ou limite do GIPHY: segue com o anime
          errorLog.info('GIFs', 'GIPHY não respondeu para "$w"', e);
        }
      }
    }
    saved += await fetchFor(t, force: true).catchError((Object e) {
      errorLog.info('GIFs', 'Busca automática de GIFs falhou', e);
      return 0;
    });
    return saved;
  }

  Future<Uint8List?> _download(String url) async {
    try {
      final req = http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'PlayerNostalgico/0.2 (app pessoal offline)';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return null;
      if ((res.contentLength ?? 0) > maxBytes) return null;
      final b = BytesBuilder(copy: false);
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        b.add(chunk);
        if (b.length > maxBytes) return null;
      }
      final bytes = b.takeBytes();
      // confere que é mesmo um GIF ("GIF87a"/"GIF89a")
      if (bytes.length < 6 || ascii.decode(bytes.sublist(0, 3), allowInvalid: true) != 'GIF') return null;
      return bytes;
    } catch (e) {
      errorLog.info('GIFs', 'Download de um GIF falhou', e);
      return null;
    }
  }
}

/// Buscas de uma música, separadas por grupo (na ordem de [GifFetcher.slotOrder]).
class GifPlan {
  final List<String> scenes, title, artist, genre, animeQueries, moods;
  const GifPlan(
      {this.scenes = const [], required this.title, required this.artist, required this.genre, required this.animeQueries, required this.moods});
  bool get anime => animeQueries.isNotEmpty || moods.isNotEmpty;
}
