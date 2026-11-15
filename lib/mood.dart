import 'gif_fetcher.dart' show GifFetcher;
import 'models.dart';

/// Clima que o usuário escolhe para a música (selo no GIF). Muda os GIFs de anime e o mix "da mesma vibe".
enum Mood {
  calmo('Calmo', '🌙', ['sleep', 'yawn', 'cuddle', 'pat', 'smile']),
  triste('Triste', '💧', ['cry', 'hug', 'pat', 'pout', 'sleep']),
  romantico('Romântico', '💗', ['kiss', 'hug', 'cuddle', 'handhold', 'blush']),
  festa('Festa', '🎉', ['dance', 'happy', 'highfive', 'clap', 'laugh']),
  epico('Épico', '🏔️', ['run', 'thumbsup', 'highfive', 'nod', 'wave']),
  acao('Ação', '👊', ['punch', 'kick', 'shoot', 'slap', 'angry', 'yeet']);

  final String label;
  final String emoji;
  final List<String> categories;
  const Mood(this.label, this.emoji, this.categories);

  static Mood? byName(String? name) => name == null || name.isEmpty ? null : Mood.values.asNameMap()[name];

  /// Clima que o gênero sugere (usado quando o usuário não escolheu).
  static Mood? fromGenre(String genre) {
    final cats = GifFetcher.moodCategories(genre);
    if (cats.isEmpty) return null;
    if (cats.contains('punch')) return Mood.acao;
    if (cats.contains('kiss')) return Mood.romantico;
    if (cats.contains('cry')) return Mood.triste;
    if (cats.contains('sleep')) return Mood.calmo;
    if (cats.contains('run') && cats.contains('kick')) return Mood.epico;
    if (cats.contains('dance')) return Mood.festa;
    return null;
  }
}

extension TrackMood on Track {
  /// Clima escolhido pelo usuário (ou null = automático pelo gênero).
  Mood? get chosenMood => Mood.byName(mood);

  /// Clima que vale: o escolhido, senão o do gênero.
  Mood? get effectiveMood => chosenMood ?? Mood.fromGenre(genre);
}
