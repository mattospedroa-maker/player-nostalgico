import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'filename_parser.dart';
import 'gif_providers.dart';
import 'gif_service.dart';
import 'models.dart';
import 'organizer.dart' show safeFolderName;

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

  GifFetcher(this.gifs, {required this.client, List<GifProvider>? providers, this.maxBytes = 8 * 1024 * 1024, this.retryAfter = const Duration(days: 3)})
      : providers = providers ?? [OpenverseProvider(client), WikimediaProvider(client), NekosBestProvider(client)];

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
    for (final (re, cats) in _moods) {
      if (RegExp(re).hasMatch(g)) return cats;
    }
    return const ['happy', 'wave', 'smile', 'thumbsup', 'dance'];
  }

  /// As buscas em três grupos, na ordem dos 9 GIFs:
  /// 2 pelo nome da música, 2 pelo artista, 2 pelo gênero, e o resto intercalando os três.
  static GifPlan planFor(Track t, {List<String> extras = const []}) {
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
      moods: hasGenre ? moodCategories(genre) : const [],
    );
  }

  /// Ordem das vagas: 2 da música, 2 do artista, 2 do gênero, depois anime no clima da música intercalado com o gênero.
  static const slotOrder = [0, 0, 1, 1, 2, 2, 3, 2, 3];

  /// Vagas guardadas para os GIFs de anime (só baixados música a música, nunca em massa).
  static const animeSlots = 2;

  /// Pastas onde os GIFs da música ficam: `GIFs/Artista/Título/`.
  static (String, String) dirsFor(Track t) {
    final parsed = parseFileName(t.title);
    final artist = t.artist == unknownArtist || t.artist.trim().isEmpty ? (parsed.artist ?? 'Outros') : t.artist;
    return (safeFolderName(artist), safeFolderName(parsed.title));
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
  static const planVersion = 2;

  /// Nomes dos arquivos baixados automaticamente (hash do conteúdo).
  static final _autoName = RegExp(r'^[0-9a-f]{12}\.gif$');

  /// Baixa GIFs até a música ter [maxGifsPerTrack] fixados. Retorna quantos baixou.
  /// Sem [force], não repete uma busca recente que não achou nada.
  /// Com [bulk] (biblioteca toda), não usa fontes que proíbem download em massa.
  Future<int> fetchFor(Track t, {bool force = false, bool bulk = false}) async {
    final root = gifs.gifRoot;
    if (root == null || t.id == null || _running.contains(t.id)) return 0;
    final key = t.path;
    final log = _readLog();
    final entry = log[key];
    final version = entry is Map ? (entry['v'] as num?)?.toInt() ?? 1 : (entry == null ? planVersion : 1);
    final last = DateTime.tryParse('${entry is Map ? entry['t'] : entry ?? ''}');
    final (artistDir, titleDir) = dirsFor(t);
    final dest = Directory(p.join(root, artistDir, titleDir));

    var pinned = (await gifs.db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    if (version < planVersion) {
      // regra antiga: apaga só os GIFs que o app baixou sozinho (os escolhidos à mão ficam)
      for (final g in pinned.where((g) => _autoName.hasMatch(p.basename(g)) && p.isWithin(root, g))) {
        await gifs.db.unpinGif(t.id!, g);
        // o arquivo só sai do celular se nenhuma outra música usa
        if (await gifs.db.gifUsers(g) == 0) await File(g).delete().catchError((_) => File(g));
      }
      pinned = pinned.where((g) => File(g).existsSync()).toList();
    }
    final animeDone = entry is Map && entry['anime'] == true;
    final plan0 = planFor(t, extras: gifs.extrasFor(t.artist, parseFileName(t.title).title));
    // em massa, deixa vagas para os GIFs de anime que vêm quando a música tocar
    final reserve = bulk && plan0.anime && providers.any((pr) => pr.animeOnly) ? animeSlots : 0;
    final need = maxGifsPerTrack - reserve - pinned.length;
    if (need <= 0) return 0;
    final recent = last != null && DateTime.now().difference(last) < retryAfter;
    final animePending = !bulk && plan0.anime && !animeDone;
    if (version >= planVersion && !force && recent && !animePending) return 0;

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
      final titleC = await collect(plan.title, anime: false);
      if (plan.anime) titleC.insertAll(0, await collect(plan.animeQueries, anime: true));
      final artistC = (await collect(plan.artist, anime: false))..shuffle(rnd); // varia entre as músicas do artista
      final genreC = (await collect(plan.genre, anime: false))..shuffle(rnd);
      final animeC = <GifCandidate>[];
      final nekos = usable.whereType<NekosBestProvider>().firstOrNull;
      if (nekos != null && plan.moods.isNotEmpty) {
        final cats = List.of(plan.moods)..shuffle(rnd);
        for (final cat in cats.take(3)) {
          try {
            for (final c in await nekos.random(cat, amount: 2)) {
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
      while (saved < need && buckets.any((b) => b.isNotEmpty)) {
        final want = slotOrder[(pinned.length + slot) % slotOrder.length];
        slot++;
        // se o grupo da vez acabou, pega do próximo que tiver
        final bucket = [for (var k = 0; k < 4; k++) buckets[(want + k) % 4]].firstWhere((b) => b.isNotEmpty);
        while (bucket.isNotEmpty) {
          final c = bucket.removeAt(0);
          // 1) mesmo endereço já baixado para outra música: usa o mesmo arquivo, sem baixar
          final known = index[c.url] as String?;
          if (known != null && File(known).existsSync()) {
            if (!have.add(p.basenameWithoutExtension(known))) continue;
            await gifs.db.pinGif(t.id!, known);
            saved++;
            break;
          }
          final bytes = await _download(c.url);
          if (bytes == null) continue;
          final hash = sha1.convert(bytes).toString().substring(0, 12);
          if (!have.add(hash)) continue; // mesmo GIF vindo de outro endereço
          // 2) mesmo conteúdo já guardado (por outra música): aponta para ele, não grava de novo
          var target = gifs.findByName('$hash.gif');
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
      if (credits.isNotEmpty) {
        await File(p.join(dest.path, 'creditos.txt')).writeAsString('${credits.join('\n')}\n', mode: FileMode.append);
      }
      _writeIndex(index);
      log[key] = {'v': planVersion, 't': DateTime.now().toIso8601String(), 'anime': animeDone || !bulk};
      _writeLog(log);
    } finally {
      _running.remove(t.id);
      await gifs.refresh();
    }
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
