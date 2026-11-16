import 'dart:convert';
import 'dart:io';

import 'visual_tags.dart';

/// O que o usuário ensinou sobre os GIFs, guardado em `GIFs/.preferencias.json` (vai junto com a pasta).
///
/// - 👎 "não combina": o GIF nunca mais volta sozinho para aquela música nem para o artista,
///   e o termo (ou categoria de anime) que trouxe ele perde força.
/// - ⬇ baixar da tela "GIFs pela vibe": o termo que achou o GIF ganha força.
///
/// Nada de aprendizado complexo: só contagens locais, previsíveis.
class GifFeedback {
  final File file;
  Map<String, dynamic>? _data;
  GifFeedback(this.file);

  static String songKey(String artist, String title) => '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';
  static String artistKey(String artist) => artist.trim().toLowerCase();

  Map<String, dynamic> get _map {
    if (_data != null) return _data!;
    try {
      _data = file.existsSync() ? (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>() : {};
    } catch (_) {
      _data = {};
    }
    return _data!;
  }

  Map<String, dynamic> _section(String name) => (_map[name] ??= <String, dynamic>{}) as Map<String, dynamic>;

  void _save() {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_map));
    } catch (_) {}
  }

  // ---------- rejeitados ----------

  /// [ids]: tudo que identifica o GIF (endereço, id do GIPHY, hash do arquivo).
  void reject(String artist, String title, Iterable<String> ids) {
    final rej = _section('rejeitados');
    for (final k in [songKey(artist, title), artistKey(artist)]) {
      final list = ((rej[k] as List?) ?? []).map((e) => '$e').toSet()..addAll(ids.where((i) => i.isNotEmpty));
      rej[k] = list.toList();
    }
    _save();
  }

  /// Rejeitados para esta música (os da música e os do artista).
  Set<String> rejected(String artist, String title) {
    final rej = _section('rejeitados');
    return {
      for (final k in [songKey(artist, title), artistKey(artist)]) ...((rej[k] as List?) ?? const []).map((e) => '$e'),
    };
  }

  // ---------- força dos termos ----------

  /// +1 (baixou) ou -1 (não combina) para o termo, na música e (com metade do peso) no artista.
  void vote(String artist, String title, String term, int delta) {
    final t = VisualTagMapper.normalize(term);
    if (t.isEmpty) return;
    final w = _section('termos');
    for (final k in [songKey(artist, title), artistKey(artist)]) {
      final m = ((w[k] as Map?) ?? {}).cast<String, dynamic>();
      m[t] = (((m[t] as num?) ?? 0) + delta).clamp(-5, 5);
      w[k] = m;
    }
    _save();
  }

  /// Multiplicador do termo para a música: 1 = neutro; menor que 1 = o usuário não gosta; maior = gosta.
  double weight(String artist, String title, String term) {
    final t = VisualTagMapper.normalize(term);
    final w = _section('termos');
    final song = (((w[songKey(artist, title)] as Map?) ?? const {})[t] as num?) ?? 0;
    final art = (((w[artistKey(artist)] as Map?) ?? const {})[t] as num?) ?? 0;
    return (1 + 0.3 * song + 0.12 * art).clamp(0.15, 2.5).toDouble();
  }

  /// Aplica as preferências ao plano: reordena pesquisas e categorias de anime pela força de cada uma.
  VisualPlan apply(VisualPlan plan, String artist, String title) {
    final all = [
      for (final q in plan.all) VisualQuery(q.text, q.group, q.score * weight(artist, title, q.text)),
    ]..sort((a, b) => b.score.compareTo(a.score));
    final animeW = {for (final c in plan.anime) c: weight(artist, title, 'anime:$c')};
    final anime = plan.anime.where((c) => animeW[c]! > 0.4).toList()..sort((a, b) => animeW[b]!.compareTo(animeW[a]!));
    return VisualPlan(
      all: all,
      anime: anime.isEmpty ? plan.anime : anime,
      matchedTags: plan.matchedTags,
      fromTags: plan.fromTags,
      clipScenes: plan.clipScenes,
    );
  }
}

/// Categoria do nekos.best a partir do endereço do GIF (ex.: `https://nekos.best/api/v2/cry/abc.gif` -> `cry`).
String? nekosCategory(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !u.host.contains('nekos.best')) return null;
  final segs = u.pathSegments;
  final i = segs.indexOf('v2');
  return i >= 0 && i + 2 < segs.length ? segs[i + 1] : null;
}

/// GIF que estraga a vibe: meme, reação, texto escrito, figurinha.
final _memeWords = RegExp(
    r'\b(reaction|reacts?|meme|memes|lol|lmao|funny|omg|wtf|text|quote|caption|subscribe|sticker|emoji|happy birthday|good morning|good night|thank you|thanks|congrats|yes|no|ok|bye|hello|hi)\b',
    caseSensitive: false);

bool looksLikeMeme(String title) => _memeWords.hasMatch(title);

/// Nota de um resultado do GIPHY para a vibe: termo forte, anime (preferido, mas não obrigatório),
/// título que fala da música/artista; memes perdem muito.
double resultScore({required double termScore, required bool anime, required String title, String artist = '', String song = ''}) {
  var s = termScore;
  if (anime) s *= 1.35;
  final t = VisualTagMapper.normalize(title);
  if (artist.length > 2 && t.contains(VisualTagMapper.normalize(artist))) s *= 1.15;
  if (song.length > 2 && t.contains(VisualTagMapper.normalize(song))) s *= 1.2;
  if (looksLikeMeme(title)) s *= 0.05;
  return s;
}
