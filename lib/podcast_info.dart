import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'error_log.dart';

/// Informações de um episódio de podcast: descrição e capítulos do YouTube, mais o resumo feito pela IA
/// (Gemini) lendo a legenda automática. Ficam num arquivo .json ao lado do .mp3, então funcionam offline
/// e acompanham o episódio se a pasta for copiada para outro celular.

/// Um capítulo (do YouTube, ou criado pela IA quando o vídeo não tem).
class Chapter {
  final int startMs;
  final String title;

  /// O que acontece neste trecho (uma ou duas frases da IA). Vazio sem IA.
  final String summary;

  /// 3 a 5 palavras visuais para os GIFs deste trecho ("espaço", "oceano"...). Usadas na fase dos GIFs.
  final List<String> visual;
  const Chapter({required this.startMs, required this.title, this.summary = '', this.visual = const []});

  Map<String, Object> toJson() => {'s': startMs, 't': title, if (summary.isNotEmpty) 'r': summary, if (visual.isNotEmpty) 'v': visual};
  static Chapter fromJson(Map<String, dynamic> m) => Chapter(
        startMs: (m['s'] as num?)?.toInt() ?? 0,
        title: '${m['t'] ?? ''}',
        summary: '${m['r'] ?? ''}',
        visual: [for (final v in (m['v'] as List?) ?? const []) '$v'],
      );
}

/// Quem fala no episódio.
class Participant {
  final String name;

  /// "apresentador", "convidado", "convidada"...
  final String role;
  const Participant(this.name, this.role);
  Map<String, String> toJson() => {'n': name, 'p': role};
  static Participant fromJson(Map<String, dynamic> m) => Participant('${m['n'] ?? ''}', '${m['p'] ?? ''}');
}

/// Situação do resumo (mostrada no download e no balão).
enum SummaryStatus {
  none(''),
  working('fazendo resumo…'),
  ok('resumo pronto'),
  noKey('sem chave do Gemini'),
  noCaptions('vídeo sem legenda: só a descrição'),
  failed('não deu para fazer o resumo');

  final String label;
  const SummaryStatus(this.label);
}

/// Assuntos fixos (a "vibe" do podcast): o mix "Da mesma vibe" procura outro episódio do mesmo assunto.
const podcastSubjects = [
  'religião/bíblico', 'ciência', 'tecnologia', 'humor', 'crime real', 'esporte', 'política', 'saúde', 'games',
  'negócios', 'história de vida', 'história', 'cultura pop', 'música', 'educação', 'outro',
];

class EpisodeInfo {
  final String videoId;
  final String url;
  final String description;
  final List<Chapter> chapters;
  final String summary;
  final List<Participant> people;
  final List<String> topics;
  final String subject;
  final List<String> tags;
  final SummaryStatus status;

  /// Motivo técnico quando falhou (vai para o registro de erros; a tela mostra só [status]).
  final String? error;

  const EpisodeInfo({
    this.videoId = '',
    this.url = '',
    this.description = '',
    this.chapters = const [],
    this.summary = '',
    this.people = const [],
    this.topics = const [],
    this.subject = '',
    this.tags = const [],
    this.status = SummaryStatus.none,
    this.error,
  });

  bool get hasSummary => summary.trim().isNotEmpty;

  /// Texto extra para a busca de episódios: participantes (não viram artistas, mas acham o episódio), temas e assunto.
  String get searchText => [for (final x in people) x.name, ...topics, subject, ...tags].join(' ');

  /// Capítulo tocando em [pos] (null antes do primeiro ou sem capítulos).
  Chapter? chapterAt(Duration pos) {
    Chapter? cur;
    for (final c in chapters) {
      if (c.startMs <= pos.inMilliseconds) {
        cur = c;
      } else {
        break;
      }
    }
    return cur;
  }

  EpisodeInfo copyWith({
    List<Chapter>? chapters,
    String? summary,
    List<Participant>? people,
    List<String>? topics,
    String? subject,
    List<String>? tags,
    SummaryStatus? status,
    String? error,
  }) =>
      EpisodeInfo(
        videoId: videoId,
        url: url,
        description: description,
        chapters: chapters ?? this.chapters,
        summary: summary ?? this.summary,
        people: people ?? this.people,
        topics: topics ?? this.topics,
        subject: subject ?? this.subject,
        tags: tags ?? this.tags,
        status: status ?? this.status,
        error: error ?? this.error,
      );

  Map<String, Object?> toJson() => {
        'versao': 1,
        'id': videoId,
        'url': url,
        'descricao': description,
        'capitulos': [for (final c in chapters) c.toJson()],
        'resumo': summary,
        'participantes': [for (final x in people) x.toJson()],
        'temas': topics,
        'assunto': subject,
        'etiquetas': tags,
        'status': status.name,
        if (error != null) 'erro': error,
      };

  static EpisodeInfo fromJson(Map<String, dynamic> m) => EpisodeInfo(
        videoId: '${m['id'] ?? ''}',
        url: '${m['url'] ?? ''}',
        description: '${m['descricao'] ?? ''}',
        chapters: [for (final c in (m['capitulos'] as List?) ?? const []) Chapter.fromJson((c as Map).cast<String, dynamic>())],
        summary: '${m['resumo'] ?? ''}',
        people: [for (final x in (m['participantes'] as List?) ?? const []) Participant.fromJson((x as Map).cast<String, dynamic>())],
        topics: [for (final t in (m['temas'] as List?) ?? const []) '$t'],
        subject: '${m['assunto'] ?? ''}',
        tags: [for (final t in (m['etiquetas'] as List?) ?? const []) '$t'],
        status: SummaryStatus.values.asNameMap()[m['status']] ?? SummaryStatus.none,
        error: m['erro'] as String?,
      );

  /// Começa pelo que o yt-dlp devolve (-J): descrição e capítulos do canal.
  static EpisodeInfo fromYoutube(Map<String, dynamic> info) {
    final id = '${info['id'] ?? ''}';
    final chapters = <Chapter>[];
    for (final c in (info['chapters'] as List?) ?? const []) {
      if (c is! Map) continue;
      final start = (c['start_time'] as num?)?.toDouble() ?? 0;
      chapters.add(Chapter(startMs: (start * 1000).round(), title: '${c['title'] ?? ''}'.trim()));
    }
    return EpisodeInfo(
      videoId: id,
      url: '${info['webpage_url'] ?? (id.isEmpty ? '' : 'https://www.youtube.com/watch?v=$id')}',
      description: '${info['description'] ?? ''}',
      chapters: chapters,
    );
  }

  /// Junta a resposta da IA (JSON pedido em [summaryPrompt]). Campos que faltam ficam como estavam.
  EpisodeInfo withAi(Map<String, dynamic> ai) {
    List<String> strs(Object? v) => [for (final x in (v as List?) ?? const []) if ('$x'.trim().isNotEmpty) '$x'.trim()];
    final aiChapters = <Chapter>[];
    for (final c in (ai['capitulos'] as List?) ?? const []) {
      if (c is! Map) continue;
      final s = (c['inicio_s'] as num?)?.toDouble();
      if (s == null) continue;
      aiChapters.add(Chapter(
        startMs: (s * 1000).round(),
        title: '${c['titulo'] ?? ''}'.trim(),
        summary: '${c['resumo'] ?? ''}'.trim(),
        visual: strs(c['palavras_visuais']).take(5).toList(),
      ));
    }
    aiChapters.sort((a, b) => a.startMs.compareTo(b.startMs));
    // capítulos do canal mandam nos horários e títulos; a IA completa o resumo e as palavras de cada um
    List<Chapter> merged;
    if (chapters.isEmpty) {
      merged = aiChapters;
    } else {
      merged = [
        for (final c in chapters)
          () {
            final near = _closest(aiChapters, c.startMs);
            return Chapter(startMs: c.startMs, title: c.title, summary: near?.summary ?? '', visual: near?.visual ?? const []);
          }(),
      ];
    }
    final subject = '${ai['assunto'] ?? ''}'.trim().toLowerCase();
    return copyWith(
      summary: '${ai['resumo'] ?? ''}'.trim(),
      people: [
        for (final x in (ai['participantes'] as List?) ?? const [])
          if (x is Map && '${x['nome'] ?? ''}'.trim().isNotEmpty) Participant('${x['nome']}'.trim(), '${x['papel'] ?? ''}'.trim()),
      ],
      topics: strs(ai['temas']),
      subject: podcastSubjects.contains(subject) ? subject : (subject.isEmpty ? '' : 'outro'),
      tags: strs(ai['etiquetas']),
      chapters: merged,
      status: SummaryStatus.ok,
    );
  }

  static Chapter? _closest(List<Chapter> list, int ms) {
    Chapter? best;
    for (final c in list) {
      if (best == null || (c.startMs - ms).abs() < (best.startMs - ms).abs()) best = c;
    }
    return best;
  }
}

/// Arquivo de informações ao lado do episódio: "Episódio.mp3" -> "Episódio.json".
String sidecarPath(String audioPath) => '${p.withoutExtension(audioPath)}.json';

// ---------------------------------------------------------------------------
// Legenda automática

/// Endereço da legenda (formato json3) no idioma original do vídeo. Prefere a legenda feita pelo canal.
Uri? captionUrl(Map<String, dynamic> info) {
  final lang = '${info['language'] ?? ''}'.toLowerCase();
  Uri? pick(Object? group, {bool autoOnly = false}) {
    if (group is! Map || group.isEmpty) return null;
    final keys = group.keys.map((k) => '$k').toList();
    final order = <String>[
      if (lang.isNotEmpty) ...['$lang-orig', lang],
      ...keys.where((k) => k.endsWith('-orig')),
      if (!autoOnly) ...keys.where((k) => k.startsWith('pt') || k.startsWith('en')),
      if (!autoOnly && keys.length == 1) keys.first,
    ];
    for (final k in order) {
      final formats = group[k];
      if (formats is! List) continue;
      for (final f in formats) {
        if (f is Map && f['ext'] == 'json3' && f['url'] != null) return Uri.tryParse('${f['url']}');
      }
    }
    return null;
  }

  return pick(info['subtitles']) ?? pick(info['automatic_captions'], autoOnly: true) ?? pick(info['automatic_captions']);
}

/// Trechos da legenda json3: (início em ms, texto).
List<(int, String)> parseJson3(String body) {
  final out = <(int, String)>[];
  final m = jsonDecode(body);
  if (m is! Map) return out;
  for (final e in (m['events'] as List?) ?? const []) {
    if (e is! Map) continue;
    final segs = e['segs'];
    if (segs is! List) continue;
    final text = segs.map((s) => s is Map ? '${s['utf8'] ?? ''}' : '').join().replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    out.add(((e['tStartMs'] as num?)?.toInt() ?? 0, text));
  }
  return out;
}

/// Texto corrido com marcas de tempo [h:mm:ss] a cada minuto (a IA usa para marcar os capítulos).
/// Corta em [maxChars] (um episódio de 3h tem ~170 mil letras; o limite deixa folga para episódios enormes).
String transcriptText(List<(int, String)> segs, {int maxChars = 600000}) {
  final b = StringBuffer();
  var nextMark = 0;
  for (final (ms, text) in segs) {
    if (ms >= nextMark) {
      final s = ms ~/ 1000;
      b.write('\n[${s ~/ 3600}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}] ');
      nextMark = ms + 60000;
    }
    b
      ..write(text)
      ..write(' ');
    if (b.length > maxChars) break;
  }
  return b.toString().trim();
}

// ---------------------------------------------------------------------------
// IA (Gemini)

/// Pedido para a IA. Resposta em JSON, em português, mesmo quando o episódio é em outra língua.
String summaryPrompt({required String title, required String program, required String description, required List<Chapter> chapters, required String transcript}) {
  final chap = chapters.isEmpty
      ? 'O vídeo não tem capítulos: crie de 4 a 10 capítulos seguindo as mudanças de assunto, usando as marcas [h:mm:ss] da transcrição para o início (inicio_s em segundos).'
      : 'Capítulos do canal (use exatamente estes inícios, em segundos):\n${chapters.map((c) => '- ${c.startMs ~/ 1000}: ${c.title}').join('\n')}';
  return '''
Você resume episódios de podcast para um player de música. Responda SÓ com um JSON válido, em português do Brasil, neste formato:
{
  "resumo": "3 a 5 frases dizendo do que se trata a conversa",
  "participantes": [{"nome": "Nome", "papel": "apresentador | convidado | convidada | co-apresentador"}],
  "temas": ["3 a 6 temas curtos"],
  "assunto": "um destes: ${podcastSubjects.join(', ')}",
  "etiquetas": ["5 a 10 palavras-chave para achar episódios parecidos"],
  "capitulos": [{"inicio_s": 0, "titulo": "título curto", "resumo": "1 ou 2 frases", "palavras_visuais": ["3 a 5 coisas concretas que dariam boas imagens ou GIFs, em português"]}]
}
Use nomes de pessoas só se aparecerem no título, na descrição ou na conversa. Não invente.
$chap

Programa: $program
Título: $title
Descrição do vídeo:
${description.length > 4000 ? description.substring(0, 4000) : description}

Transcrição (legenda automática):
$transcript
''';
}

class GeminiException implements Exception {
  final String message;
  const GeminiException(this.message);
  @override
  String toString() => message;
}

/// Chama a API do Gemini (plano gratuito do Google AI Studio).
class GeminiClient {
  final http.Client client;
  final String apiKey;
  GeminiClient(this.client, this.apiKey);

  /// Modelos tentados em ordem (o primeiro é o apelido que o Google mantém apontando para o Flash atual).
  static const models = ['gemini-flash-latest', 'gemini-2.5-flash'];

  static Uri urlFor(String model, String key) =>
      Uri.https('generativelanguage.googleapis.com', '/v1beta/models/$model:generateContent', {'key': key});

  /// Devolve o JSON que a IA escreveu.
  Future<Map<String, dynamic>> generateJson(String prompt, {Duration timeout = const Duration(minutes: 3)}) async {
    if (apiKey.trim().isEmpty) throw const GeminiException('Sem chave do Gemini');
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {'responseMimeType': 'application/json', 'temperature': 0.3},
    });
    GeminiException? last;
    for (final model in models) {
      final http.Response r;
      try {
        r = await client.post(urlFor(model, apiKey), headers: {'Content-Type': 'application/json'}, body: body).timeout(timeout);
      } on TimeoutException {
        throw const GeminiException('O Gemini demorou demais para responder');
      } on SocketException {
        throw const GeminiException('Sem conexão com o Gemini');
      }
      if (r.statusCode == 404) {
        last = GeminiException('Modelo $model não encontrado');
        continue; // tenta o próximo modelo
      }
      if (r.statusCode == 400 && r.body.contains('API_KEY_INVALID')) throw const GeminiException('Chave do Gemini inválida');
      if (r.statusCode == 429) throw const GeminiException('Limite do plano grátis do Gemini atingido (tente mais tarde)');
      if (r.statusCode != 200) throw GeminiException('Gemini respondeu ${r.statusCode}');
      final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final parts = ((((m['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?) ?? const [];
      final text = parts.map((x) => x is Map ? '${x['text'] ?? ''}' : '').join().trim();
      if (text.isEmpty) throw const GeminiException('O Gemini não devolveu texto');
      return parseAiJson(text);
    }
    throw last ?? const GeminiException('Nenhum modelo do Gemini respondeu');
  }
}

/// Lê o JSON da IA, mesmo se vier dentro de ```json ... ```.
Map<String, dynamic> parseAiJson(String text) {
  var t = text.trim();
  final start = t.indexOf('{');
  final end = t.lastIndexOf('}');
  if (start < 0 || end <= start) throw const GeminiException('Resposta do Gemini sem JSON');
  t = t.substring(start, end + 1);
  final m = jsonDecode(t);
  if (m is! Map) throw const GeminiException('Resposta do Gemini em formato estranho');
  return m.cast<String, dynamic>();
}

// ---------------------------------------------------------------------------
// Serviço

/// Monta, guarda e lê as informações dos episódios.
class PodcastInfoService extends ChangeNotifier {
  final http.Client client;
  String Function() apiKey;

  /// Informações completas do vídeo (yt-dlp -J), para episódios que ainda não têm o arquivo .json.
  Future<Map<String, dynamic>> Function(String url)? fetchInfo;

  PodcastInfoService({required this.client, required this.apiKey, this.fetchInfo});

  final Map<String, EpisodeInfo?> _cache = {};
  final Set<String> _working = {};

  bool isWorking(String audioPath) => _working.contains(audioPath);

  /// Informações guardadas do episódio (null = nenhuma).
  EpisodeInfo? infoFor(String audioPath) {
    if (_cache.containsKey(audioPath)) return _cache[audioPath];
    EpisodeInfo? info;
    try {
      final f = File(sidecarPath(audioPath));
      if (f.existsSync()) info = EpisodeInfo.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (e) {
      errorLog.info('Podcasts', 'Arquivo de informações do episódio ilegível', e);
    }
    return _cache[audioPath] = info;
  }

  Future<void> save(String audioPath, EpisodeInfo info) async {
    _cache[audioPath] = info;
    try {
      await File(sidecarPath(audioPath)).writeAsString(const JsonEncoder.withIndent('  ').convert(info.toJson()));
    } catch (e) {
      errorLog.warn('Podcasts', 'Não deu para salvar as informações do episódio ${p.basename(audioPath)}', error: e);
    }
    notifyListeners();
  }

  /// O episódio mudou de lugar: o .json vai junto.
  void moved(String from, String to) {
    try {
      final f = File(sidecarPath(from));
      if (f.existsSync()) f.renameSync(sidecarPath(to));
    } catch (e) {
      errorLog.info('Podcasts', 'Não deu para mover o arquivo de informações junto com o episódio', e);
    }
    _cache.remove(from);
    _cache.remove(to);
  }

  /// Monta tudo a partir das informações do yt-dlp: descrição, capítulos, legenda e resumo da IA.
  /// [onStatus] avisa cada etapa (a tela de download mostra). Nunca lança: falhas viram [SummaryStatus].
  Future<EpisodeInfo> build(Map<String, dynamic> ytInfo, {required String title, required String program, void Function(SummaryStatus)? onStatus}) async {
    var info = EpisodeInfo.fromYoutube(ytInfo);
    final key = apiKey();
    if (key.trim().isEmpty) return info.copyWith(status: SummaryStatus.noKey);
    onStatus?.call(SummaryStatus.working);
    try {
      var transcript = '';
      final url = captionUrl(ytInfo);
      if (url != null) {
        final r = await client.get(url).timeout(const Duration(seconds: 40));
        if (r.statusCode == 200) transcript = transcriptText(parseJson3(utf8.decode(r.bodyBytes)));
      }
      if (transcript.isEmpty && info.description.trim().length < 80) {
        return info.copyWith(status: SummaryStatus.noCaptions);
      }
      final ai = await GeminiClient(client, key).generateJson(summaryPrompt(
        title: title,
        program: program,
        description: info.description,
        chapters: info.chapters,
        transcript: transcript.isEmpty ? '(sem legenda: use só o título e a descrição)' : transcript,
      ));
      info = info.withAi(ai);
      if (transcript.isEmpty) info = info.copyWith(status: SummaryStatus.noCaptions);
      return info;
    } catch (e) {
      errorLog.add(ErrorLog.isNetwork(e) ? LogLevel.info : LogLevel.warning, 'Podcasts', 'Resumo do episódio "$title" não saiu', error: e);
      return info.copyWith(status: SummaryStatus.failed, error: '$e');
    }
  }

  /// Faz (ou refaz) o resumo de um episódio já salvo, buscando as informações do vídeo pelo [url].
  Future<EpisodeInfo?> summarize(String audioPath, String url, {required String title, required String program}) async {
    final fetch = fetchInfo;
    if (fetch == null || url.isEmpty || !_working.add(audioPath)) return infoFor(audioPath);
    notifyListeners();
    try {
      final yt = await fetch(url);
      final info = await build(yt, title: title, program: program);
      await save(audioPath, info);
      return info;
    } catch (e) {
      errorLog.warn('Podcasts', 'Não deu para buscar as informações do vídeo de "$title"', error: e);
      return infoFor(audioPath);
    } finally {
      _working.remove(audioPath);
      notifyListeners();
    }
  }
}
