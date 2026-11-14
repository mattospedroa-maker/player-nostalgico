import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'db.dart';
import 'models.dart';
import 'organizer.dart' show safeFolderName;

const gifExtensions = {'.gif', '.webp', '.png', '.jpg', '.jpeg'};

/// Acervo local de GIFs: a pasta "GIFs" dentro da pasta-fonte.
/// Subpastas viram tags (ex.: GIFs/Hatsune Miku/ combina com músicas da Miku).
class GifService {
  final AppDb db;
  String? sourceRoot;
  List<File> _cache = const [];

  GifService(this.db);

  String? get gifRoot => sourceRoot == null ? null : p.join(sourceRoot!, 'GIFs');

  Future<void> refresh() async {
    final root = gifRoot;
    if (root == null) return;
    final d = Directory(root);
    if (!d.existsSync()) {
      await d.create(recursive: true);
      _cache = const [];
      return;
    }
    _cache = d
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => gifExtensions.contains(p.extension(f.path).toLowerCase()))
        .toList();
  }

  int get count => _cache.length;

  /// GIFs para a música: fixados primeiro, depois os que batem com artista/álbum/título/gênero, depois gerais.
  Future<List<String>> gifsFor(Track t, {int max = 30}) async {
    final pinned = t.id == null ? <String>[] : (await db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    final keys = [t.artist, t.album, t.title, t.genre].map(_norm).where((k) => k.length >= 2).toList();
    final matching = <String>[];
    final general = <String>[];
    for (final f in _cache) {
      if (pinned.contains(f.path)) continue;
      final tags = p.split(p.relative(p.dirname(f.path), from: gifRoot!)).where((s) => s != '.').map(_norm).toList()
        ..add(_norm(p.basenameWithoutExtension(f.path)));
      final hit = tags.any((tag) => tag.length >= 2 && keys.any((k) => k.contains(tag) || tag.contains(k)));
      if (hit) {
        matching.add(f.path);
      } else if (p.equals(p.dirname(f.path), gifRoot!)) {
        general.add(f.path);
      }
    }
    final rnd = Random(t.path.hashCode);
    matching.shuffle(rnd);
    general.shuffle(rnd);
    return [...pinned, ...matching, ...general].take(max).toList();
  }

  /// Copia GIFs escolhidos pelo usuário para `GIFs/Artista/` e fixa na música.
  Future<int> importForTrack(Track t, List<String> files) async {
    final root = gifRoot;
    if (root == null || t.id == null) return 0;
    final dest = Directory(p.join(root, safeFolderName(t.artist)));
    await dest.create(recursive: true);
    var n = 0;
    for (final src in files) {
      var target = p.join(dest.path, p.basename(src));
      var i = 2;
      while (File(target).existsSync()) {
        target = p.join(dest.path, '${p.basenameWithoutExtension(src)} ($i)${p.extension(src)}');
        i++;
      }
      await File(src).copy(target);
      await db.pinGif(t.id!, target);
      n++;
    }
    await refresh();
    return n;
  }
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9À-ɏ぀-ヿ一-鿿]+'), '');
