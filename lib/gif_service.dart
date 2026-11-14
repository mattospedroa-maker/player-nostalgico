import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'models.dart';
import 'organizer.dart' show safeFolderName;

const gifExtensions = {'.gif', '.webp', '.png', '.jpg', '.jpeg'};

/// Acervo local de GIFs: a pasta "GIFs" dentro da pasta-fonte.
/// Subpastas viram tags (ex.: GIFs/Hatsune Miku/ combina com músicas da Miku).
class GifService extends ChangeNotifier {
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
      notifyListeners();
      return;
    }
    _cache = d
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => gifExtensions.contains(p.extension(f.path).toLowerCase()))
        .toList();
    notifyListeners();
  }

  // ---------- palavras extras de busca ----------
  // Guardadas em GIFs/palavras.json (vão junto com a pasta). Chave "artista|título" ou só "artista".

  /// Associações que já vêm prontas (o usuário pode trocar).
  static const defaultExtras = {
    'linkin park|numb': 'rock lee vs gaara',
    'eminem|till i collapse': 'real steel gigante de aço',
  };

  static String extrasKey(String artist, [String? title]) =>
      [artist, ?title].map((s) => s.toLowerCase().trim()).join('|');

  Map<String, String> _readExtras() {
    final root = gifRoot;
    final f = root == null ? null : File(p.join(root, 'palavras.json'));
    if (f == null || !f.existsSync()) return Map.of(defaultExtras);
    try {
      return (jsonDecode(f.readAsStringSync()) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return Map.of(defaultExtras);
    }
  }

  /// Palavras extras para a música (da música e do artista).
  List<String> extrasFor(String artist, String title) {
    final m = _readExtras();
    return [m[extrasKey(artist, title)], m[extrasKey(artist)]].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  }

  String songExtras(String artist, String title) => _readExtras()[extrasKey(artist, title)] ?? '';

  Future<void> setSongExtras(String artist, String title, String words) async {
    final root = gifRoot;
    if (root == null) return;
    final m = _readExtras();
    final k = extrasKey(artist, title);
    words.trim().isEmpty ? m.remove(k) : m[k] = words.trim();
    await Directory(root).create(recursive: true);
    await File(p.join(root, 'palavras.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(m));
  }

  /// Avisa as telas (ex.: começou ou terminou um download).
  void changed() => notifyListeners();

  int get count => _cache.length;

  /// Procura um GIF já guardado pelo nome do arquivo (os baixados têm nome = hash do conteúdo).
  String? findByName(String name) {
    for (final f in _cache) {
      if (p.basename(f.path) == name && f.existsSync()) return f.path;
    }
    return null;
  }

  /// Registra um arquivo novo sem reler a pasta inteira.
  void addToCache(String path) => _cache = [..._cache, File(path)];

  /// GIFs para a música: fixados primeiro, depois os que batem com artista/álbum/título/gênero, depois gerais.
  Future<List<String>> gifsFor(Track t, {int max = 9}) async {
    final pinned = t.id == null ? <String>[] : (await db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    final keys = [t.artist, t.album, t.title, t.genre].map(_norm).where((k) => k.length >= 2).toList();
    final matching = <String>[];
    final general = <String>[];
    for (final f in _cache) {
      if (pinned.contains(f.path) || !f.existsSync()) continue;
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
    // não mostra o mesmo GIF duas vezes (arquivos baixados têm o nome = hash do conteúdo)
    final seen = <String>{};
    return [...pinned, ...matching, ...general].where((g) => seen.add(p.basename(g))).take(max).toList();
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

  /// Salva bytes de um GIF escolhido na web em `GIFs/Artista/Título/` e fixa na música.
  Future<String?> saveForTrack(Track t, List<int> bytes, {required String artistDir, required String titleDir, String credit = ''}) async {
    final root = gifRoot;
    if (root == null || t.id == null) return null;
    final ext = imageExtensionFor(bytes);
    if (ext == null) return null;
    final dest = Directory(p.join(root, artistDir, titleDir));
    await dest.create(recursive: true);
    final target = p.join(dest.path, 'web_${DateTime.now().millisecondsSinceEpoch}$ext');
    await File(target).writeAsBytes(bytes, flush: true);
    await db.pinGif(t.id!, target);
    if (credit.isNotEmpty) {
      await File(p.join(dest.path, 'creditos.txt')).writeAsString('${p.basename(target)} · $credit\n', mode: FileMode.append);
    }
    await refresh();
    return target;
  }

  /// Tira o GIF da música; o arquivo só é apagado do celular se nenhuma outra música usa.
  Future<void> deleteGif(String path, {int? trackId}) async {
    if (trackId != null) {
      await db.unpinGif(trackId, path);
      if (await db.gifUsers(path) > 0) return refresh();
    }
    await db.deleteGifEverywhere(path);
    final f = File(path);
    if (f.existsSync()) await f.delete();
    await refresh();
  }
}

/// Descobre o tipo da imagem pelos primeiros bytes. Null se não for imagem.
String? imageExtensionFor(List<int> b) {
  if (b.length < 12) return null;
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return '.gif';
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return '.webp';
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return '.png';
  if (b[0] == 0xFF && b[1] == 0xD8) return '.jpg';
  return null;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9À-ɏ぀-ヿ一-鿿]+'), '');
