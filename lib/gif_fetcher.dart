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
import 'gif_providers.dart';
import 'gif_service.dart';
import 'lastfm.dart';
import 'models.dart';
import 'mood.dart';
import 'organizer.dart' show safeFolderName;
import 'service_health.dart';
import 'visual_search.dart';
import 'visual_tags.dart';

/// Máximo de GIFs por música (para não ocupar espaço demais).
const maxGifsPerTrack = 9;

/// Baixa GIFs da internet (Openverse + Wikimedia) pelo nome da música e do artista,
/// guarda em `GIFs/Artista/Título/` e fixa na música. Depois funciona offline.
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
      : providers = providers ?? [NekosBestProvider(client)], // só GIFs de anime (pedido do usuário)
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

  /// As buscas em três grupos, na ordem dos 9 GIFs:
  /// 2 pelo nome da música, 2 pelo artista, 2 pelo gênero, e o resto intercalando os três.
  /// [tagAnime]: categorias de anime vindas das tags do Last.fm (valem mais que o gênero, menos que o clima escolhido).
  static GifPlan planFor(Track t, {List<String> extras = const [], List<String> tagAnime = const [], List<MusicTag>? tags}) {
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

    return GifPlan(
      title: uniq([...extras, if (artist.isNotEmpty) '$title $artist', title]),
      artist: uniq([if (artist.isNotEmpty) artist, if (artist.isNotEmpty) '$artist band', if (artist.isNotEmpty) '$artist live']),
      genre: uniq([if (hasGenre) genre, if (hasGenre) '$mainGenre concert', if (hasGenre) '$mainGenre music']),
      animeQueries: uniq(extras),
      moods: moodsFor(t, tagAnime: tagAnime, hasGenre: hasGenre, tags: tags),
    );
  }

  /// Categorias de anime da música: clima escolhido > clima automático (pistas) > tags do Last.fm > gênero.
  /// Com clima automático, as categorias dele se alternam com as das tags (que trazem atmosfera e cenas do clipe),
  /// começando pelo clima.
  static List<String> moodsFor(Track t, {List<String> tagAnime = const [], bool? hasGenre, List<MusicTag>? tags}) {
    final chosen = t.chosenMood;
    if (chosen != null) return chosen.categories;
    final auto = MoodClues.forTrack(t, tags: tags).mood;
    if (auto != null) {
      // categorias das tags que brigam com o clima saem (ex.: soco numa música melancólica só porque a banda é de metal)
      final clash = {for (final m in _clashes[auto]!) ...m.categories}.difference(auto.categories.toSet());
      final fromTags = tagAnime.where((c) => !clash.contains(c)).toList();
      final out = <String>[];
      for (var i = 0; i < auto.categories.length || i < fromTags.length; i++) {
        if (i < auto.categories.length && !out.contains(auto.categories[i])) out.add(auto.categories[i]);
        if (i < fromTags.length && !out.contains(fromTags[i])) out.add(fromTags[i]);
      }
      return out;
    }
    if (tagAnime.isNotEmpty) return tagAnime;
    final g = t.genre.trim();
    final known = hasGenre ?? (g.isNotEmpty && g.toLowerCase() != 'desconhecido');
    return known ? moodCategories(g) : neutralMoods;
  }

  static const _clashes = <Mood, List<Mood>>{
    Mood.calmo: [Mood.acao, Mood.festa],
    Mood.triste: [Mood.acao, Mood.festa],
    Mood.romantico: [Mood.acao],
    Mood.festa: [Mood.triste, Mood.calmo],
    Mood.epico: [Mood.triste, Mood.calmo],
    Mood.acao: [Mood.calmo, Mood.romantico, Mood.triste],
  };

  /// Ordem das vagas: 2 da música, 2 do artista, 2 do gênero, depois anime no clima da música intercalado com o gênero.
  static const slotOrder = [0, 3, 3, 0, 3, 1, 3, 2, 3];

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
      if (r.tags.isNotEmpty) MoodClues.invalidate();
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

  /// Pesquisas visuais da música: tags do Last.fm + cenas do clipe -> dicionário; sem nada, a alternativa básica.
  /// O clima escolhido no selo pesa mais que tudo.
  Future<VisualPlan> visualPlanFor(Track t) async {
    final (title, artist) = namesFor(t);
    final r = await tagsFor(t);
    final clip = await clipFor(t);
    var plan = mapper.convert(r.tags, mood: t.chosenMood, title: title, artist: artist, genre: t.genre, scenes: clip?.scenes ?? const {});
    // palavras do usuário (música e artista) e o nome da trilha sonora vêm na frente: são as mais específicas
    final top = plan.all.isEmpty ? 1.0 : plan.all.first.score;
    final extras = gifs.extrasFor(t.artist, title);
    final ost = soundtrackName(t.album);
    final front = <VisualQuery>[
      for (final e in extras)
        for (final w in e.split(',').map((x) => x.trim()).where((x) => x.length >= 2)) VisualQuery(w, 'Suas palavras', top * 2),
      if (ost != null) VisualQuery(ost, 'Trilha sonora', top * 1.4),
    ];
    if (front.isNotEmpty) {
      final seen = <String>{};
      plan = VisualPlan(
        all: [...front, ...plan.all].where((q) => seen.add(VisualTagMapper.normalize(q.text))).toList(),
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
  static const planVersion = 4; // 4: varia os GIFs entre músicas do mesmo álbum

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
    final visual = await visualPlanFor(t);
    final tagAnime = visual.fromTags ? visual.anime : const <String>[];
    // a música foi buscada antes de ter as tags: refaz os automáticos uma vez com elas
    final redoForTags = entry is Map && entry['lfm'] != true && tagAnime.isNotEmpty && t.chosenMood == null && !bulk;
    if (version < planVersion || redoForTags) {
      await _clearAuto(t, pinned, root);
      pinned = (await gifs.db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    }
    final animeDone = entry is Map && entry['anime'] == true;
    final plan0 = planFor(t, extras: gifs.extrasFor(t.artist, parseFileName(t.title).title), tagAnime: tagAnime, tags: cachedTags(t));
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
      final seenUrls = <String>{};
      final usable = providers.where((pr) => (!bulk || pr.allowBulk) && (!pr.animeOnly || plan.anime)).toList();
      // plano B: quais fontes de anime falharam e se alguma respondeu
      final moodFailures = <String, Object>{};
      final moodUsed = <String>{};

      Future<List<GifCandidate>> collect(List<String> queries, {required bool anime}) async {
        final out = <GifCandidate>[];
        for (final q in queries) {
          for (final prov in usable.where((pr) => pr.animeOnly == anime)) {
            if (health.isDown(prov.name)) continue; // caiu há pouco: nem tenta
            try {
              for (final c in await prov.search(q, limit: 15)) {
                if (seenUrls.add(c.url)) out.add(c);
              }
              health.up(prov.name);
            } catch (e) {
              // sem internet ou fonte fora do ar: tenta a próxima
              errorLog.info('GIFs', 'Busca de GIFs falhou em ${prov.name}', e);
              if (prov is AnimeMoodSource) {
                health.down(prov.name, e);
                moodFailures[prov.name] = e;
              }
            }
          }
          if (out.length >= 8) break;
        }
        return out;
      }

      final rnd = Random(t.path.hashCode);
      final (title0, artist0) = namesFor(t);
      final rejected = feedback?.rejected(artist0, title0) ?? const <String>{};
      final titleC = await collect(plan.title, anime: false);
      if (plan.anime) titleC.insertAll(0, await collect(plan.animeQueries, anime: true));
      final artistC = (await collect(plan.artist, anime: false))..shuffle(rnd); // varia entre as músicas do artista
      final genreC = (await collect(plan.genre, anime: false))..shuffle(rnd);
      final animeC = <GifCandidate>[];
      // em massa as fontes de anime não entram (termos do nekos.best); música a música, sim
      final sources = bulk ? const <AnimeMoodSource>[] : moodSources;
      final climas = _readClimas();
      if (sources.isNotEmpty && plan.moods.isNotEmpty) {
        // categorias que o usuário marcou como "não combina" para esta música saem da lista
        final fb = feedback;
        final cats = plan.moods.where((c) => fb == null || fb.weight(artist0, title0, 'anime:$c') > 0.4).toList();
        if (cats.isEmpty) cats.addAll(plan.moods);
        // das tags já vêm em ordem de importância; do gênero/clima, sorteia
        if (tagAnime.isEmpty || t.chosenMood != null) {
          cats.shuffle(rnd);
        } else if (cats.length > 2) {
          // mantém a categoria principal (com clima automático, as duas primeiras: a do clima e a das tags)
          // e sorteia as outras por música, para o álbum não ficar todo igual
          final keep = MoodClues.forTrack(t, tags: cachedTags(t)).mood != null && cats.length > 3 ? 2 : 1;
          final rest = cats.sublist(keep)..shuffle(rnd);
          cats
            ..removeRange(keep, cats.length)
            ..addAll(rest);
        }
        for (final cat in cats.take(4)) {
          // a primeira fonte que responder vale; se ela caiu, a próxima (waifu.pics) entra no lugar
          for (final src in sources) {
            if (health.isDown(src.name)) continue;
            try {
              // pede mais do que precisa: sobra para pular os que outras músicas já usam
              final got = await src.random(cat, amount: 5);
              health.up(src.name);
              if (got.isEmpty) continue;
              moodUsed.add(src.name);
              for (final c in got) {
                if (!seenUrls.add(c.url)) continue;
                animeC.add(c);
                if (c.category != null && nekosCategory(c.url) == null) climas[c.url] = c.category;
              }
              break;
            } catch (e) {
              errorLog.info('GIFs', '${src.name} não respondeu', e);
              health.down(src.name, e);
              moodFailures[src.name] = e;
            }
          }
        }
        animeC.shuffle(rnd);
      }
      final buckets = [titleC, artistC, genreC, animeC];

      // hashes do que a música já tem, para não repetir o mesmo GIF
      final have = pinned.map((g) => p.basenameWithoutExtension(g)).toSet();
      final index = _readIndex();
      final credits = <String>[];
      var slot = 0;
      // GIFs que outras músicas já usam: ficam para o fim (só entram se faltar GIF novo)
      final reuse = <String>[];
      while (saved < need && buckets.any((b) => b.isNotEmpty)) {
        final want = slotOrder[(pinned.length + slot) % slotOrder.length];
        slot++;
        // se o grupo da vez acabou, pega do próximo que tiver
        final bucket = [for (var k = 0; k < 4; k++) buckets[(want + k) % 4]].firstWhere((b) => b.isNotEmpty);
        while (bucket.isNotEmpty) {
          final c = bucket.removeAt(0);
          if (rejected.contains(c.url)) continue; // o usuário disse que não combina
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
            saved++;
            break;
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
          saved++;
          break;
        }
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
      // nenhuma fonte de anime respondeu: não marca como buscada, para tentar de novo quando a música tocar
      if (!(outage && moodUsed.isEmpty)) {
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
    for (final u in urls) {
      final cat = nekosCategory(u);
      if (cat != null) feedback?.vote(artist, title, 'anime:$cat', -1);
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

/// Buscas de uma música, separadas por grupo.
class GifPlan {
  final List<String> title, artist, genre, animeQueries, moods;
  const GifPlan({required this.title, required this.artist, required this.genre, required this.animeQueries, required this.moods});
  bool get anime => animeQueries.isNotEmpty || moods.isNotEmpty;
}
