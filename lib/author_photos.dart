import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'audiobooks.dart';
import 'error_log.dart';
import 'library_search.dart' show normalizeText;
import 'organizer.dart' show safeFolderName;

/// O que a Wikipedia diz do autor (nome completo e uma linha sobre ele).
class AuthorFacts {
  final String name;
  final String about;

  /// Procurou e não achou foto (não tenta de novo antes de 30 dias).
  final bool missing;
  final DateTime? when;
  const AuthorFacts({this.name = '', this.about = '', this.missing = false, this.when});

  Map<String, Object?> toJson() => {'nome': name, 'sobre': about, 'nada': missing, 'quando': when?.toIso8601String()};
  static AuthorFacts fromJson(Map<String, dynamic> m) => AuthorFacts(
        name: '${m['nome'] ?? ''}',
        about: '${m['sobre'] ?? ''}',
        missing: m['nada'] == true,
        when: DateTime.tryParse('${m['quando'] ?? ''}'),
      );
}

/// Foto de cada autor de audiolivro, pela Wikipedia (português, senão inglês). Baixada uma vez (~50 KB)
/// e guardada em Audiolivros/.autores/, então funciona off-line depois.
class AuthorPhotoService extends ChangeNotifier {
  final http.Client client;
  String? Function() root;
  bool Function() allowNet;
  AuthorPhotoService({required this.client, required this.root, required this.allowNet});

  static const _ua = {'User-Agent': 'NostalgicMPlayer/1.0 (app pessoal de audiolivros offline)'};
  final Map<String, AuthorFacts?> _facts = {};
  final Set<String> _tried = {};
  bool _running = false;

  String? _base(String author) {
    final r = root();
    if (r == null || r.isEmpty) return null;
    return p.join(r, audiobooksFolder, '.autores', safeFolderName(author));
  }

  /// Foto já baixada (null = sem foto: a tela usa a capa de um livro dele).
  File? photoFor(String author) {
    final b = _base(author);
    if (b == null) return null;
    final f = File('$b.jpg');
    return f.existsSync() ? f : null;
  }

  AuthorFacts? factsFor(String author) {
    if (_facts.containsKey(author)) return _facts[author];
    final b = _base(author);
    AuthorFacts? out;
    try {
      final f = File('$b.json');
      if (b != null && f.existsSync()) out = AuthorFacts.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {}
    return _facts[author] = out;
  }

  /// Procura a foto dos autores que ainda não têm (um de cada vez, uma vez por abertura do app).
  Future<void> fetchMissing(Iterable<String> authors) async {
    if (_running || !allowNet()) return;
    final todo = [
      for (final a in authors)
        if (a.trim().isNotEmpty && a != unknownAuthor && !_tried.contains(a) && photoFor(a) == null && !_recentlyMissing(a)) a,
    ];
    if (todo.isEmpty) return;
    _running = true;
    try {
      for (final a in todo) {
        _tried.add(a);
        if (!allowNet()) break;
        await _fetch(a);
      }
    } finally {
      _running = false;
    }
  }

  bool _recentlyMissing(String a) {
    final f = factsFor(a);
    return f != null && f.missing && f.when != null && DateTime.now().difference(f.when!).inDays < 30;
  }

  Future<void> _fetch(String author) async {
    final base = _base(author);
    if (base == null) return;
    try {
      ({String title, String about, String image})? hit;
      for (final lang in ['pt', 'en']) {
        final r = await client
            .get(
                Uri.https('$lang.wikipedia.org', '/w/api.php', {
                  'action': 'query',
                  'format': 'json',
                  'generator': 'search',
                  'gsrsearch': author,
                  'gsrlimit': '6',
                  'prop': 'pageimages|description',
                  'piprop': 'thumbnail',
                  'pithumbsize': '400',
                  'redirects': '1',
                }),
                headers: _ua)
            .timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) continue;
        hit = pickAuthorPage(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>, author);
        if (hit != null) break;
      }
      await Directory(p.dirname(base)).create(recursive: true);
      if (hit == null) {
        await _saveFacts(author, base, AuthorFacts(missing: true, when: DateTime.now()));
        return;
      }
      final img = await client.get(Uri.parse(hit.image), headers: _ua).timeout(const Duration(seconds: 30));
      if (img.statusCode != 200 || img.bodyBytes.length < 500) return;
      await File('$base.jpg').writeAsBytes(img.bodyBytes);
      await _saveFacts(author, base, AuthorFacts(name: hit.title, about: hit.about, when: DateTime.now()));
      notifyListeners();
    } catch (e) {
      errorLog.info('Audiolivros', 'Não deu para buscar a foto de $author', e);
    }
  }

  Future<void> _saveFacts(String author, String base, AuthorFacts f) async {
    _facts[author] = f;
    await File('$base.json').writeAsString(jsonEncode(f.toJson()));
  }

  static final _writer = RegExp(
      r'escrit|romancist|poet|dramaturg|fil[oó]sof|ensa[ií]st|novelist|contist|cronist|jornalist|historiador|te[oó]log|'
      r'writer|author|poet|philosoph|playwright|essayist|journalist|historian',
      caseSensitive: false);

  /// Página do autor na busca da Wikipedia: título com o nome dele (em qualquer grafia), descrição de escritor
  /// e com foto. Evita pôr a foto de outra pessoa com o mesmo nome (ou de um canal do YouTube).
  @visibleForTesting
  static ({String title, String about, String image})? pickAuthorPage(Map<String, dynamic> json, String author) {
    final pages = (json['query']?['pages'] as Map?)?.values.whereType<Map>().toList() ?? const [];
    pages.sort((a, b) => ((a['index'] as num?) ?? 99).compareTo((b['index'] as num?) ?? 99));
    final words = [for (final w in normalizeText(author).split(RegExp(r'[^a-z]+'))) if (w.length > 2) w];
    final last = surnameVariants(author);
    if (words.isEmpty) return null;
    final others = words.where((w) => !last.contains(w)).toList();
    // 1ª volta: nome inteiro no título; 2ª: só o sobrenome (o prenome muda de grafia: Liev/Leo, Fiódor/Fyodor)
    for (final strict in [true, false]) {
      for (final pg in pages) {
        final title = '${pg['title'] ?? ''}';
        final about = '${pg['description'] ?? ''}';
        final img = '${(pg['thumbnail'] as Map?)?['source'] ?? ''}';
        if (img.isEmpty || !_writer.hasMatch(about)) continue;
        final t = normalizeText(title);
        if (!last.any(t.contains) || (strict && !others.every(t.contains))) continue;
        return (title: title, about: about, image: img);
      }
    }
    return null;
  }
}
