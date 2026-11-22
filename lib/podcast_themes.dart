import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'error_log.dart';
import 'gif_providers.dart';
import 'models.dart';
import 'podcast_info.dart';
import 'podcast_local_themes.dart';

/// Um tema dentro de um programa: nome curto, palavras para o GIF e os episódios (nomes de arquivo).
class EpisodeTheme {
  final String name;
  final String gifQuery;
  final List<String> files;

  /// Nome do arquivo do GIF dentro de `.temas/` (vazio = ainda sem GIF).
  final String gif;
  const EpisodeTheme({required this.name, required this.gifQuery, required this.files, this.gif = ''});

  EpisodeTheme copyWith({List<String>? files, String? gif}) => EpisodeTheme(name: name, gifQuery: gifQuery, files: files ?? this.files, gif: gif ?? this.gif);

  Map<String, dynamic> toJson() => {'nome': name, 'gif_busca': gifQuery, 'arquivos': files, 'gif': gif};

  static EpisodeTheme fromJson(Map<String, dynamic> m) => EpisodeTheme(
    name: '${m['nome'] ?? ''}',
    gifQuery: '${m['gif_busca'] ?? ''}',
    files: [for (final f in (m['arquivos'] as List? ?? const [])) '$f'],
    gif: '${m['gif'] ?? ''}',
  );
}

/// Temas guardados de um programa. [signature] = episódios que existiam quando foi agrupado.
class ProgramThemes {
  final String signature;
  final List<EpisodeTheme> themes;

  /// Episódios que o usuário mudou de tema (arquivo → nome do tema; '' = Outros). Valem depois de reagrupar.
  final Map<String, String> manual;

  /// Quem agrupou: 'local…' (títulos e capítulos, na hora) ou 'ia' (Gemini, melhora os nomes depois).
  final String source;
  const ProgramThemes(this.signature, this.themes, {this.manual = const {}, this.source = 'ia'});

  bool get byAi => source == 'ia';

  Map<String, dynamic> toJson() => {
    'assinatura': signature,
    'fonte': source,
    'temas': [for (final t in themes) t.toJson()],
    'manual': manual,
  };

  static ProgramThemes fromJson(Map<String, dynamic> m) => ProgramThemes(
    '${m['assinatura'] ?? ''}',
    [
      for (final t in (m['temas'] as List? ?? const []))
        if (t is Map) EpisodeTheme.fromJson(t.cast<String, dynamic>()),
    ],
    manual: {for (final e in ((m['manual'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
    source: '${m['fonte'] ?? 'ia'}',
  );

  /// Tema de cada arquivo, com as mudanças do usuário por cima.
  ProgramThemes withManual(Map<String, String> moves) {
    var out = themes;
    for (final e in moves.entries) {
      if (e.value.isNotEmpty && !out.any((x) => x.name == e.value)) continue; // o tema sumiu no reagrupamento
      out = [
        for (final x in out)
          x.copyWith(
            files: [
              for (final f in x.files)
                if (f != e.key) f,
              if (x.name == e.value) e.key,
            ],
          ),
      ];
    }
    return ProgramThemes(signature, out, manual: moves, source: source);
  }
}

/// Episódios de um programa separados por tema (o Gemini agrupa; cada tema ganha um GIF do GIPHY).
///
/// Tudo fica em `Podcasts/<Programa>/.temas/` (temas.json + um GIF leve por tema, WebP de 200 px).
/// Agrupa uma vez por programa e de novo só quando chega/sai episódio. Uma chamada ao Gemini por vez.
class PodcastThemesService extends ChangeNotifier {
  final http.Client client;
  final SharedPreferences prefs;
  final String Function() geminiKey;
  final GiphyProvider Function() giphy;

  /// Programas com menos episódios que isso não são separados (não tem o que agrupar).
  static const minEpisodes = 4;
  static const folder = '.temas';

  PodcastThemesService({required this.client, required this.prefs, required this.geminiKey, required this.giphy});

  final Map<String, ProgramThemes?> _cache = {};
  final Set<String> _working = {};
  final Map<String, DateTime> _gifTried = {};
  final Map<String, String> _localTried = {};

  bool isWorking(String programDir) => _working.contains(programDir);

  static String signatureOf(List<Track> episodes) {
    final names = [for (final e in episodes) p.basename(e.path)]..sort();
    return names.join('\n').hashCode.toRadixString(16);
  }

  File _file(String programDir) => File(p.join(programDir, folder, 'temas.json'));

  ProgramThemes? themesFor(String programDir) {
    if (_cache.containsKey(programDir)) return _cache[programDir];
    ProgramThemes? t;
    try {
      final f = _file(programDir);
      if (f.existsSync()) t = ProgramThemes.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (e) {
      errorLog.info('Podcasts', 'Arquivo de temas ilegível', e);
    }
    return _cache[programDir] = t;
  }

  File? gifFile(String programDir, EpisodeTheme t) {
    if (t.gif.isEmpty) return null;
    final f = File(p.join(programDir, folder, t.gif));
    return f.existsSync() ? f : null;
  }

  Future<void> _save(String programDir, ProgramThemes t) async {
    _cache[programDir] = t;
    final f = _file(programDir);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(t.toJson()));
    _cleanGifs(programDir, t);
    notifyListeners();
  }

  /// Apaga GIFs de temas que não existem mais (a IA renomeou, episódio saiu...).
  void _cleanGifs(String programDir, ProgramThemes t) {
    try {
      final keep = {for (final x in t.themes) x.gif};
      final dir = Directory(p.join(programDir, folder));
      if (!dir.existsSync()) return;
      for (final f in dir.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (name.startsWith('gif_') && !keep.contains(name)) f.deleteSync();
      }
    } catch (e) {
      errorLog.info('Podcasts', 'Não deu para apagar GIFs de temas antigos', e);
    }
  }

  /// Agrupa (ou reagrupa, se os episódios mudaram) e busca os GIFs que faltam. Em segundo plano.
  Future<void> ensure(String programDir, String program, List<Track> episodes, EpisodeInfo? Function(String path) infoFor, {bool force = false}) async {
    if (episodes.length < minEpisodes) return;
    final sig = signatureOf(episodes);
    var have = themesFor(programDir);
    // 1) na hora, sem internet: temas pelos títulos e capítulos (quando ainda não tem, ou chegou episódio
    //    e os temas atuais também são locais). Temas da IA ficam; episódio novo cai em "Outros" até ela refazer.
    if ((have == null || (!have.byAi && (have.signature != sig || have.source != LocalThemes.source))) && _localTried[programDir] != sig) {
      _localTried[programDir] = sig;
      final local = LocalThemes.build(program, episodes, infoFor, previous: have?.themes ?? const []);
      if (local.isNotEmpty) {
        await Future<void>.delayed(Duration.zero); // chamado de dentro do build da tela: salva/avisa depois
        have = ProgramThemes(sig, local, source: LocalThemes.source).withManual(have?.manual ?? const {});
        await _save(programDir, have);
      }
    }
    unawaited(_fetchGifs(programDir));
    // 2) a IA melhora (nomes e agrupamento) quando estiver disponível
    final needsAi = have == null || !have.byAi || have.signature != sig;
    if (!needsAi && !force) return;
    if (geminiKey().isEmpty) return;
    final failKey = 'themesFails:$programDir';
    final lastKey = 'themesTried3:$programDir';
    final fails = prefs.getInt(failKey) ?? 0;
    final last = prefs.getInt(lastKey) ?? 0;
    // falhou: espera cada vez mais (30 min, 2 h, 1 dia) para não gastar a cota grátis nem a bateria
    if (!force && fails > 0 && DateTime.now().millisecondsSinceEpoch - last < retryWait(fails).inMilliseconds) return;
    if (!_working.add(programDir)) return;
    await Future<void>.delayed(Duration.zero);
    notifyListeners();
    try {
      await prefs.setInt(lastKey, DateTime.now().millisecondsSinceEpoch);
      final ai = await GeminiClient(client, geminiKey()).generateJson(promptFor(program, episodes, infoFor), timeout: const Duration(minutes: 3));
      final themes = parseThemes(ai, episodes, previous: have?.themes ?? const []);
      if (themes.isEmpty) throw const GeminiException('A IA não achou temas em comum entre os episódios');
      await _save(programDir, ProgramThemes(sig, themes).withManual(have?.manual ?? const {}));
      await prefs.remove(failKey);
      await prefs.remove('themesError:$programDir');
      await _fetchGifs(programDir);
    } catch (e) {
      await prefs.setInt(failKey, fails + 1);
      await prefs.setString('themesError:$programDir', '$e');
      errorLog.info('Podcasts', 'A IA não melhorou os temas de "$program" (fica com os temas pelos títulos)', e);
    } finally {
      _working.remove(programDir);
      notifyListeners();
    }
  }

  /// Espera depois de [fails] falhas seguidas da IA.
  static Duration retryWait(int fails) => switch (fails) {
    <= 1 => const Duration(minutes: 30),
    2 => const Duration(hours: 2),
    _ => const Duration(days: 1),
  };

  /// Motivo da última falha ao separar por tema (null = sem falha guardada).
  String? errorFor(String programDir) => prefs.getString('themesError:$programDir');

  /// Pedido curto: só o título limpo e até 6 capítulos de cada episódio (84 episódios cabem em poucos KB).
  static String promptFor(String program, List<Track> episodes, EpisodeInfo? Function(String path) infoFor) {
    final b = StringBuffer()
      ..writeln('Programa de podcast: "$program".')
      ..writeln('Agrupe os episódios abaixo em temas em comum pelo ASSUNTO da conversa (séries e quadros fixos também valem).')
      ..writeln('- tema de convidado só se os episódios não tiverem outro assunto em comum, e com nome e sobrenome;')
      ..writeln('Regras:')
      ..writeln('- de 2 a ${LocalThemes.maxThemes} temas; cada tema com pelo menos 2 episódios; cada episódio em no máximo 1 tema;')
      ..writeln('- episódio que não combina com nenhum fica de fora (vai para "Outros");')
      ..writeln('- "nome": curto, em português, até 3 palavras, sem repetir o nome do programa;')
      ..writeln(
        '- "gif": 2 a 4 palavras EM INGLÊS para buscar um GIF que mostre o tema com algo concreto e visual '
        '(ex.: "wheat field sunset", "old library books", "football stadium"); nada de nomes de pessoas.',
      )
      ..writeln('Responda só JSON: {"temas":[{"nome":"...","gif":"...","eps":[1,2]}]}')
      ..writeln('Episódios (título | capítulos):');
    for (var i = 0; i < episodes.length; i++) {
      final info = infoFor(episodes[i].path);
      final caps = [
        for (final c in info?.chapters ?? const <Chapter>[])
          if (c.title.trim().isNotEmpty && !LocalThemes.isWaitingChapter(c.title)) c.title.trim(),
      ].take(6).toList();
      final title = shortTitle(episodes[i].title, program);
      b.writeln('${i + 1}. $title${caps.isEmpty ? '' : ' | ${caps.join('; ')}'}');
    }
    return b.toString();
  }

  /// "FULANO (ASSUNTO) - Programa. Podcast #108" -> "FULANO (ASSUNTO)".
  static String shortTitle(String title, String program) {
    final cut = title.lastIndexOf(' - ');
    final t = cut > 0 && title.substring(cut).toLowerCase().contains(program.toLowerCase().split(' ').first) ? title.substring(0, cut) : title;
    return t.length > 120 ? t.substring(0, 120) : t;
  }

  /// Lê a resposta da IA. Mantém o GIF de um tema que já existia com o mesmo nome.
  static List<EpisodeTheme> parseThemes(Map<String, dynamic> ai, List<Track> episodes, {List<EpisodeTheme> previous = const []}) {
    final used = <int>{};
    final out = <EpisodeTheme>[];
    for (final t in (ai['temas'] as List? ?? const []).whereType<Map>()) {
      final name = '${t['nome'] ?? ''}'.trim();
      if (name.isEmpty || name.toLowerCase() == 'outros') continue;
      final idx = <int>[
        for (final n in [for (final x in (t['eps'] as List? ?? const [])) x is num ? x.toInt() : int.tryParse('$x'.trim())])
          if (n != null && n >= 1 && n <= episodes.length && used.add(n - 1)) n - 1,
      ];
      if (idx.length < 2) {
        used.removeAll(idx);
        continue;
      }
      final old = previous.where((x) => x.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      out.add(
        EpisodeTheme(
          name: name.length > 40 ? name.substring(0, 40) : name,
          gifQuery: '${t['gif'] ?? ''}'.trim().isEmpty ? name : '${t['gif']}'.trim(),
          files: [for (final i in idx) p.basename(episodes[i].path)],
          gif: old?.gif ?? '',
        ),
      );
      if (out.length == LocalThemes.maxThemes) break;
    }
    return out;
  }

  /// Um GIF por tema (uma vez; fica guardado). Sem chave do GIPHY: os temas ficam com o quadro colorido.
  Future<void> _fetchGifs(String programDir) async {
    var t = themesFor(programDir);
    if (t == null || t.themes.every((x) => gifFile(programDir, x) != null)) return;
    // a tela redesenha muitas vezes: uma tentativa a cada 10 min por programa
    final last = _gifTried[programDir];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 10)) return;
    _gifTried[programDir] = DateTime.now();
    final giphy = this.giphy();
    if ((giphy.apiKey ?? '').trim().isEmpty) return;
    final taken = <String>{for (final x in t.themes) x.gif};
    var changed = false;
    for (var i = 0; i < t!.themes.length; i++) {
      final th = t.themes[i];
      if (gifFile(programDir, th) != null) continue;
      try {
        final found = await giphy.search(th.gifQuery, limit: 6);
        for (final g in found) {
          final name = 'gif_${g.id}.webp';
          if (taken.contains(name) || taken.contains('gif_${g.id}.gif')) continue; // dois temas com o mesmo GIF confundem
          final url = g.tileUrl.isNotEmpty ? g.tileUrl : g.previewUrl;
          final saved = g.tileUrl.isNotEmpty ? name : 'gif_${g.id}.gif';
          final res = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
          if (res.statusCode != 200 || res.bodyBytes.length < 500) continue;
          await File(p.join(programDir, folder, saved)).writeAsBytes(res.bodyBytes, flush: true);
          taken.add(saved);
          t = ProgramThemes(
            t!.signature,
            [...t.themes]..[i] = th.copyWith(gif: saved),
            manual: t.manual,
            source: t.source,
          );
          changed = true;
          break;
        }
      } catch (e) {
        errorLog.info('Podcasts', 'GIF do tema "${th.name}" não veio', e);
        break; // sem internet / GIPHY fora: tenta de novo na próxima vez
      }
    }
    if (changed) await _save(programDir, t!);
  }

  /// Muda um episódio de tema (null = "Outros"). Fica guardado até o próximo reagrupamento.
  Future<void> move(String programDir, String file, String? toTheme) async {
    final t = themesFor(programDir);
    if (t == null) return;
    await _save(programDir, t.withManual({...t.manual, file: toTheme ?? ''}));
  }

  /// Pasta do programa foi movida/renomeada.
  void forget(String programDir) => _cache.remove(programDir);
}
