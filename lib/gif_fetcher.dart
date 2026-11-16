import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'clip_info.dart';
import 'filename_parser.dart';
import 'gif_feedback.dart';
import 'gif_providers.dart';
import 'visual_search.dart';
import 'gif_service.dart';
import 'lastfm.dart';
import 'models.dart';
import 'mood.dart';
import 'organizer.dart' show safeFolderName;
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

  GifFetcher(this.gifs, {required this.client, List<GifProvider>? providers, this.maxBytes = 8 * 1024 * 1024, this.retryAfter = const Duration(days: 3)})
      : providers = providers ?? [NekosBestProvider(client)]; // só GIFs de anime (pedido do usuário)

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
  static GifPlan planFor(Track t, {List<String> extras = const [], List<String> tagAnime = const []}) {
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
      // clima escolhido no selo do GIF vale mais que o gênero
      moods: t.chosenMood?.categories ?? (tagAnime.isNotEmpty ? tagAnime : (hasGenre ? moodCategories(genre) : neutralMoods)),
    );
  }

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

  /// Tags do Last.fm da música, com cache em `GIFs/.lastfm.json`. Nunca lança erro.
  Future<TagResult> tagsFor(Track t) async {
    final (title, artist) = namesFor(t);
    final root = gifs.gifRoot;
    if (root != null && _tagCacheRoot != root) {
      _tagCache = TagCache(File(p.join(root, '.lastfm.json')));
      _tagCacheRoot = root;
    }
    var r = _tagCache?.get(artist, title);
    if (r == null) {
      try {
        r = await LastFmClient(client, lastFmKey()).topTags(artist, title);
      } catch (_) {
        r = const TagResult(TagStatus.badResponse);
      }
      _tagCache?.put(artist, title, r);
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
    } catch (_) {
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
    if (path == null || !File(path).existsSync()) return {};
    try {
      return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// Endereço -> arquivo já baixado (GIFs/.indice.json), para não baixar o mesmo GIF duas vezes.
  Map<String, dynamic> _readIndex() {
    final root = gifs.gifRoot;
    final f = root == null ? null : File(p.join(root, '.indice.json'));
    if (f == null || !f.existsSync()) return {};
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _writeIndex(Map<String, dynamic> index) {
    final root = gifs.gifRoot;
    if (root == null) return;
    File(p.join(root, '.indice.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(index));
  }

  void _writeLog(Map<String, dynamic> log) {
    final path = _logPath();
    if (path == null) return;
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(log));
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
    final plan0 = planFor(t, extras: gifs.extrasFor(t.artist, parseFileName(t.title).title), tagAnime: tagAnime);
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

      Future<List<GifCandidate>> collect(List<String> queries, {required bool anime}) async {
        final out = <GifCandidate>[];
        for (final q in queries) {
          for (final prov in usable.where((pr) => pr.animeOnly == anime)) {
            try {
              for (final c in await prov.search(q, limit: 15)) {
                if (seenUrls.add(c.url)) out.add(c);
              }
            } catch (_) {
              // sem internet ou fonte fora do ar: tenta a próxima
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
      final nekos = usable.whereType<NekosBestProvider>().firstOrNull;
      if (nekos != null && plan.moods.isNotEmpty) {
        // categorias que o usuário marcou como "não combina" para esta música saem da lista
        final fb = feedback;
        final cats = plan.moods.where((c) => fb == null || fb.weight(artist0, title0, 'anime:$c') > 0.4).toList();
        if (cats.isEmpty) cats.addAll(plan.moods);
        // das tags já vêm em ordem de importância; do gênero/clima, sorteia
        if (tagAnime.isEmpty || t.chosenMood != null) {
          cats.shuffle(rnd);
        } else if (cats.length > 2) {
          // mantém a categoria principal e sorteia as outras por música, para o álbum não ficar todo igual
          final rest = cats.sublist(1)..shuffle(rnd);
          cats
            ..removeRange(1, cats.length)
            ..addAll(rest);
        }
        for (final cat in cats.take(4)) {
          try {
            // pede mais do que precisa: sobra para pular os que outras músicas já usam
            for (final c in await nekos.random(cat, amount: 5)) {
              if (seenUrls.add(c.url)) animeC.add(c);
            }
          } catch (_) {}
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
      log[key] = {'v': planVersion, 't': DateTime.now().toIso8601String(), 'anime': animeDone || !bulk, 'lfm': tagAnime.isNotEmpty};
      _writeLog(log);
    } finally {
      _running.remove(t.id);
      await gifs.refresh();
    }
    return saved;
  }

  /// Apaga só os GIFs que o app baixou sozinho (os escolhidos à mão ficam).
  Future<void> _clearAuto(Track t, List<String> pinned, String root) async {
    for (final g in pinned.where((g) => _autoName.hasMatch(p.basename(g)) && p.isWithin(root, g))) {
      await gifs.db.unpinGif(t.id!, g);
      // o arquivo só sai do celular se nenhuma outra música usa
      if (await gifs.db.gifUsers(g) == 0) await File(g).delete().catchError((_) => File(g));
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
        } catch (_) {
          // sem internet ou limite do GIPHY: segue com o anime
        }
      }
    }
    saved += await fetchFor(t, force: true).catchError((_) => 0);
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
    } catch (_) {
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
