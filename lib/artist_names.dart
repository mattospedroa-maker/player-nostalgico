import 'models.dart';

/// Junta parcerias no artista principal: "MC VV & BOFE", "MC VV (ft. LAUNZERA)", "MC VV prod MC VV"
/// e "MC VV, BOFE & JEAN XEROSO" viram todos "MC VV".
///
/// Duas regras:
/// * "feat.", "ft.", "featuring", "prod", "part." sempre separam (ninguém tem isso no nome da banda).
/// * "&", vírgula, " x ", " e ", " and ", "+", "/", " vs " só separam quando a parte da frente também
///   aparece na biblioteca como artista (sozinho, ou em mais de uma parceria). Assim "Simon & Garfunkel"
///   e "Earth, Wind & Fire" continuam inteiros, a não ser que exista "Simon" sozinho na biblioteca.
class ArtistNames {
  /// Grupo atual da biblioteca (a AppState troca a cada leitura). Vazio = só a regra do "feat./prod".
  static ArtistNames current = ArtistNames.from(const []);

  static final _strong = RegExp(r'\s*[\(\[]?\s*\b(feat\.?|ft\.?|featuring|prod\.?|part\.)(?=\s|$|\.)', caseSensitive: false);
  static final _weak = RegExp(r'\s*(,|;|&|\+|/|\s(x|e|and|vs\.?|with)\s)\s*', caseSensitive: false);

  /// chave do texto inteiro (sem o "feat.") -> chave do artista principal
  final Map<String, String> _mainKey = {};

  /// chave do artista principal -> nome mostrado (a grafia mais comum)
  final Map<String, String> _display = {};

  ArtistNames._();

  /// Monta os grupos a partir das músicas da biblioteca.
  factory ArtistNames.fromTracks(List<Track> tracks) => ArtistNames.from([
    for (final t in tracks)
      if (t.artist != unknownArtist) t.artist,
  ]);

  factory ArtistNames.from(Iterable<String> artists) {
    final g = ArtistNames._();
    final heads = <String>{};
    for (final a in artists) {
      final h = stripFeat(a);
      if (h.isNotEmpty) heads.add(h);
    }
    final standalone = {for (final h in heads) _norm(h)};
    // com quantos parceiros diferentes cada trecho aparece logo em seguida ("a & b", "a, c" -> a: {b, c}).
    // "Mumford & Sons" e "Mumford & Sons, Baaba Maal" dão a "Mumford" um parceiro só (Sons): não separa.
    final partners = <String, Set<String>>{};
    for (final k in standalone) {
      final ms = _weak.allMatches(k).where((m) => m.start > 0).toList();
      for (var i = 0; i < ms.length; i++) {
        final end = i + 1 < ms.length ? ms[i + 1].start : k.length;
        (partners[k.substring(0, ms[i].start).trim()] ??= {}).add(k.substring(ms[i].end, end).trim());
      }
    }
    final votes = <String, Map<String, int>>{};
    for (final h in heads) {
      final k = _norm(h);
      final pres = _prefixes(k);
      // 1º: o trecho mais curto que existe sozinho na biblioteca
      String? main;
      for (final pre in pres) {
        if (pre != k && standalone.contains(pre)) {
          main = pre;
          break;
        }
      }
      // 2º: o trecho mais longo que começa duas ou mais parcerias diferentes ("A & B", "A & C" -> "A")
      if (main == null) {
        for (final pre in pres.reversed) {
          if (pre != k && (partners[pre]?.length ?? 0) >= 2) {
            main = pre;
            break;
          }
        }
      }
      main ??= k;
      g._mainKey[k] = main;
      final shown = _cutTo(h, main);
      (votes[main] ??= {})[shown] = ((votes[main]![shown]) ?? 0) + 1;
    }
    for (final e in votes.entries) {
      final best = e.value.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key.length < a.key.length) ? b : a);
      g._display[e.key] = best.key;
    }
    return g;
  }

  /// Tira "feat. X", "(ft. X)", "prod Y" do fim: "MC VV (ft. LAUNZERA)" -> "MC VV".
  static String stripFeat(String artist) {
    final a = artist.trim();
    final m = _strong.firstMatch(a);
    if (m == null || m.start == 0) return a;
    return a.substring(0, m.start).replaceAll(RegExp(r'[\s,&\-–(\[]+$'), '').trim();
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Trechos do começo do nome, em cada separador: "a, b & c" -> ["a", "a, b", "a, b & c"].
  static List<String> _prefixes(String k) {
    final out = <String>[];
    for (final m in _weak.allMatches(k)) {
      if (m.start == 0) continue;
      out.add(k.substring(0, m.start).trim());
    }
    out.add(k);
    return out;
  }

  /// Corta o nome original (com a grafia dele) no tamanho da chave principal.
  static String _cutTo(String original, String mainKey) {
    final o = original.replaceAll(RegExp(r'\s+'), ' ').trim();
    return o.length >= mainKey.length ? o.substring(0, mainKey.length).trim() : o;
  }

  String _keyOf(String artist) {
    final k = _norm(stripFeat(artist));
    return _mainKey[k] ?? (_mainKey[k] = k);
  }

  /// Chave para comparar ("mesmo artista?"): sem diferença de maiúsculas.
  String key(String artist) => artist == unknownArtist ? unknownArtist : _keyOf(artist);

  /// Nome do artista principal, para mostrar.
  String main(String artist) {
    if (artist == unknownArtist) return artist;
    final k = _keyOf(artist);
    return _display[k] ?? _cutTo(stripFeat(artist), k);
  }

  bool same(String a, String b) => key(a) == key(b);
}
