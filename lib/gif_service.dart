import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'error_log.dart';
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

  Future<void>? _refreshing;
  bool _refreshAgain = false;

  /// Relê a pasta de GIFs. A leitura é assíncrona (não trava a tela com acervos grandes), e pedidos que
  /// chegam enquanto uma leitura está em andamento viram uma leitura só, logo depois dela.
  Future<void> refresh() {
    if (_refreshing != null) {
      _refreshAgain = true;
      return _refreshing!;
    }
    return _refreshing = () async {
      try {
        do {
          _refreshAgain = false;
          await _readFolder();
        } while (_refreshAgain);
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<void> _readFolder() async {
    final root = gifRoot;
    if (root == null) return;
    final d = Directory(root);
    if (!await d.exists()) {
      await d.create(recursive: true);
      _cache = const [];
      notifyListeners();
      return;
    }
    final files = <File>[];
    await for (final e in d.list(recursive: true, followLinks: false).handleError((Object e) {
      errorLog.info('GIFs', 'Uma subpasta de GIFs não pôde ser lida', e);
    })) {
      if (e is File && gifExtensions.contains(p.extension(e.path).toLowerCase())) files.add(e);
    }
    // limpa imagens vazias salvas da web por versões antigas
    for (final f in files.where((f) => p.basename(f.path).startsWith('web_')).toList()) {
      try {
        if (await f.length() < 2048) {
          await db.deleteGifEverywhere(f.path);
          await f.delete();
          files.remove(f);
        }
      } catch (e) {
        errorLog.info('GIFs', 'Não deu para limpar uma imagem vazia antiga', e);
      }
    }
    if (gifRoot != root) return; // trocou de pasta no meio da leitura
    _cache = files;
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
    } catch (e) {
      errorLog.warn('GIFs', 'GIFs/palavras.json está com defeito; usando as palavras padrão', error: e);
      return Map.of(defaultExtras);
    }
  }

  /// Palavras extras para a música (da música e do artista).
  List<String> extrasFor(String artist, String title) {
    final m = _readExtras();
    return [m[extrasKey(artist, title)], m[extrasKey(artist)]].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  }

  String songExtras(String artist, String title) => _readExtras()[extrasKey(artist, title)] ?? '';

  /// Palavras do artista (valem para todas as músicas dele).
  String artistExtras(String artist) => _readExtras()[extrasKey(artist)] ?? '';

  Future<void> setArtistExtras(String artist, String words) => _setExtras(extrasKey(artist), words);

  Future<void> setSongExtras(String artist, String title, String words) => _setExtras(extrasKey(artist, title), words);

  Future<void> _setExtras(String k, String words) async {
    final root = gifRoot;
    if (root == null) return;
    final m = _readExtras();
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
  /// Nome dos GIFs que o app baixou sozinho (hash do conteúdo). Os outros foram escolhidos pelo usuário.
  static final autoName = RegExp(r'^[0-9a-f]{12}\.gif$');
  static bool isAuto(String path) => autoName.hasMatch(p.basename(path));

  Future<List<String>> gifsFor(Track t, {int max = 9}) async {
    final pinned = t.id == null ? <String>[] : (await db.pinnedGifs(t.id!)).where((g) => File(g).existsSync()).toList();
    // os escolhidos pelo usuário aparecem primeiro na roda
    final mine = pinned.where((g) => !isAuto(g)).toList();
    pinned
      ..removeWhere((g) => !isAuto(g))
      ..insertAll(0, mine);
    final keys = [t.artist, t.album, t.title, t.genre].map(_norm).where((k) => k.length >= 2).toList();
    final matching = <String>[];
    final general = <String>[];
    final pinnedSet = pinned.toSet();
    for (final f in _cache) {
      // GIF automático de outra música (ex.: do mesmo álbum) não entra: era isso que deixava o álbum todo igual.
      // As conferências baratas vêm antes da consulta ao disco (a maioria do acervo é automática).
      if (isAuto(f.path) || pinnedSet.contains(f.path) || !f.existsSync()) continue;
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
    if (ext == null || isTinyImage(bytes)) return null; // ex.: 1 pixel que o Google usa enquanto carrega
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

/// Imagem pequena demais para ser um GIF de verdade (marcadores de 1 px, ícones).
bool isTinyImage(List<int> b) {
  if (b.length < 2048) return true;
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int be32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  final ext = imageExtensionFor(b);
  if (ext == '.gif') return le16(6) < 64 || le16(8) < 64;
  if (ext == '.png' && b.length > 24) return be32(16) < 64 || be32(20) < 64;
  return false;
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
