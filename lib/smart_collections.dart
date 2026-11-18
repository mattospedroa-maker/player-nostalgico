import 'models.dart';
import 'mood.dart';
import 'play_stats.dart';
import 'recommender.dart';
import 'xp_icons.dart';

/// Coleção automática: não é guardada no banco, é recalculada a partir da biblioteca e do histórico
/// sempre que eles mudam. Convive com as playlists normais, sem mexer nelas.
class SmartCollection {
  final String id;
  final String title;
  final String hint;
  final XpIcons icon;
  final List<Track> tracks;
  const SmartCollection(this.id, this.title, this.hint, this.icon, this.tracks);
}

const _day = 86400000;

/// Monta as coleções. Só cálculo na memória (a biblioteca já está carregada; o histórico vem resumido).
List<SmartCollection> buildSmartCollections(List<Track> tracks, PlayStats stats, {Track? current, DateTime? now}) {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final out = <SmartCollection>[];

  final top = tracks.where((t) => stats.count(t.id) > 0).toList()
    ..sort((a, b) {
      final c = stats.count(b.id).compareTo(stats.count(a.id));
      return c != 0 ? c : stats.last(b.id).compareTo(stats.last(a.id));
    });
  out.add(SmartCollection('top', 'Mais tocadas', 'as 50 que você mais ouviu', XpIcons.star, top.take(50).toList()));

  // pouco ou nunca tocadas: primeiro as nunca tocadas (mais novas antes), depois as que tocaram 1–2 vezes
  final rare = tracks.where((t) => stats.count(t.id) <= 2).toList()
    ..sort((a, b) {
      final c = stats.count(a.id).compareTo(stats.count(b.id));
      return c != 0 ? c : b.addedAt.compareTo(a.addedAt);
    });
  out.add(SmartCollection('rare', 'Pouco ou nunca tocadas', 'tocaram no máximo 2 vezes', XpIcons.note, rare.take(100).toList()));

  final sorted = [...tracks]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
  var recent = sorted.where((t) => nowMs - t.addedAt <= 30 * _day).toList();
  if (recent.isEmpty) recent = sorted.take(25).toList();
  out.add(SmartCollection('added', 'Adicionadas recentemente', 'nos últimos 30 dias', XpIcons.disc, recent.take(100).toList()));

  out.add(SmartCollection('fav', 'Favoritas', 'as que têm ♥', XpIcons.heart, tracks.where((t) => t.favorite).toList()));

  if (current != null) {
    final sim = Recommender.similar(current, tracks).map((r) => r.track).toList();
    if (sim.isNotEmpty) out.add(SmartCollection('similar', 'Parecidas com a que está tocando', current.title, XpIcons.list, sim));
  }

  final byMood = <Mood, List<Track>>{};
  for (final t in tracks) {
    final m = t.effectiveMood;
    if (m != null) (byMood[m] ??= []).add(t);
  }
  for (final m in Mood.values) {
    final list = byMood[m];
    if (list != null) out.add(SmartCollection('mood:${m.name}', 'Clima ${m.emoji} ${m.label}', 'escolhido por você ou automático', XpIcons.cassette, list));
  }
  return out;
}
