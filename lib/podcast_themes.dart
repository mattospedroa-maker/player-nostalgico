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
  const ProgramThemes(this.signature, this.themes, {this.manual = const {}});

  Map<String, dynamic> toJson() => {
    'assinatura': signature,
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
    return ProgramThemes(signature, out, manual: moves);
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
    notifyListeners();
  }

  /// Agrupa (ou reagrupa, se os episódios mudaram) e busca os GIFs que faltam. Em segundo plano.
  Future<void> ensure(String programDir, String program, List<Track> episodes, EpisodeInfo? Function(String path) infoFor) async {
    if (episodes.length < minEpisodes || geminiKey().isEmpty) return;
    final sig = signatureOf(episodes);
    final have = themesFor(programDir);
    if (have != null && have.signature == sig) {
      await _fetchGifs(programDir);
      return;
    }
    if (!_working.add(programDir)) return;
    final key = 'themesTried:$programDir';
    try {
      // falhou há pouco (sem internet, limite do plano grátis): não insiste a cada vez que abre
      final last = prefs.getInt(key) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - last < const Duration(hours: 6).inMilliseconds) return;
      notifyListeners();
      final ai = await GeminiClient(client, geminiKey()).generateJson(promptFor(program, episodes, infoFor), timeout: const Duration(minutes: 1));
      final themes = parseThemes(ai, episodes, previous: have?.themes ?? const []);
      await _save(programDir, ProgramThemes(sig, themes).withManual(have?.manual ?? const {}));
      await prefs.remove(key);
      await _fetchGifs(programDir);
    } catch (e) {
      await prefs.setInt(key, DateTime.now().millisecondsSinceEpoch);
      errorLog.warn('Podcasts', 'Não deu para separar "$program" por tema', error: e);
    } finally {
      _working.remove(programDir);
      notifyListeners();
    }
  }

  static String promptFor(String program, List<Track> episodes, EpisodeInfo? Function(String path) infoFor) {
    final b = StringBuffer()
      ..writeln('Programa de podcast: "$program".')
      ..writeln('Agrupe os episódios abaixo em temas em comum (séries, assuntos, convidados que voltam, quadros fixos).')
      ..writeln('Regras:')
      ..writeln('- de 2 a 8 temas; cada tema com pelo menos 2 episódios; cada episódio em no máximo 1 tema;')
      ..writeln('- episódio que não combina com nenhum fica de fora (vai para "Outros");')
      ..writeln('- "nome": curto, em português, até 3 palavras, sem repetir o nome do programa;')
      ..writeln(
        '- "gif": 2 a 4 palavras EM INGLÊS para buscar um GIF que mostre o tema com algo concreto e visual '
        '(ex.: "wheat field sunset", "old library books", "football stadium"); nada de nomes de pessoas.',
      )
      ..writeln('Responda só JSON: {"temas":[{"nome":"...","gif":"...","eps":[1,2]}]}')
      ..writeln('Episódios:');
    for (var i = 0; i < episodes.length; i++) {
      final info = infoFor(episodes[i].path);
      final extra = [
        if (info != null && info.topics.isNotEmpty) 'temas: ${info.topics.take(5).join(', ')}',
        if (info != null && info.subject.isNotEmpty) 'assunto: ${info.subject}',
      ];
      b.writeln('${i + 1}. ${episodes[i].title}${extra.isEmpty ? '' : ' — ${extra.join(' — ')}'}');
    }
    return b.toString();
  }

  /// Lê a resposta da IA. Mantém o GIF de um tema que já existia com o mesmo nome.
  static List<EpisodeTheme> parseThemes(Map<String, dynamic> ai, List<Track> episodes, {List<EpisodeTheme> previous = const []}) {
    final used = <int>{};
    final out = <EpisodeTheme>[];
    for (final t in (ai['temas'] as List? ?? const []).whereType<Map>()) {
      final name = '${t['nome'] ?? ''}'.trim();
      if (name.isEmpty || name.toLowerCase() == 'outros') continue;
      final idx = <int>[
        for (final n in (t['eps'] as List? ?? const []))
          if (n is num && n >= 1 && n <= episodes.length && used.add(n.toInt() - 1)) n.toInt() - 1,
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
      if (out.length == 8) break;
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
          t = ProgramThemes(t!.signature, [...t.themes]..[i] = th.copyWith(gif: saved), manual: t.manual);
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
    await _save(programDir, ProgramThemes(t.signature, t.themes, manual: t.manual).withManual({...t.manual, file: toTheme ?? ''}));
  }

  /// Pasta do programa foi movida/renomeada.
  void forget(String programDir) => _cache.remove(programDir);
}
