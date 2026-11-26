import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/recommender.dart';
import 'package:player_nostalgico/screens/why_screen.dart';
import 'package:player_nostalgico/style_learning.dart';
import 'package:player_nostalgico/styles.dart';

var _id = 0;
final _tags = <String, List<MusicTag>>{};
Track tr(String title, String artist, {String genre = '', Mood? mood, List<String> tags = const [], String album = unknownAlbum}) {
  final t = Track(
      id: ++_id, path: '/m/$artist/$title.mp3', title: title, artist: artist, album: album, genre: genre,
      mood: mood?.name ?? '', addedAt: 0, modifiedAt: 0);
  _tags[t.path] = [for (var i = 0; i < tags.length; i++) MusicTag(tags[i], 100 - i * 8)];
  return t;
}

void main() {
  setUp(() {
    Styles.trackTags = (t) => _tags[t.path];
    MoodClues.tagsOf = (t) => _tags[t.path];
    Styles.artistTags = (_) => null;
    StyleLearning.current = StyleLearning.build(const {}, const {}, const []);
    Styles.learnedPair = (_, _) => 0;
    Styles.invalidate();
    MoodClues.invalidate();
  });
  tearDown(() {
    Styles.trackTags = (_) => null;
    MoodClues.tagsOf = (_) => null;
    Styles.invalidate();
  });

  test('explain: cada termo, do maior para o menor, somando o total', () {
    final a = tr('a', 'X', album: 'Disco', mood: Mood.triste, tags: ['dreamy', 'rainy']);
    final b = tr('b', 'X', album: 'Disco', mood: Mood.triste, tags: ['dreamy', 'rainy']);
    final e = Recommender.explain(a, b);
    expect(e.parts.first.$1, 'mesmo artista');
    expect(e.parts.map((p) => p.$1), containsAll(['mesmo álbum', 'mesmo clima (triste)']));
    for (var i = 1; i < e.parts.length; i++) {
      expect(e.parts[i].$2, lessThanOrEqualTo(e.parts[i - 1].$2));
    }
    expect(e.parts.fold<double>(0, (s, p) => s + p.$2), closeTo(e.score, 1e-9));
    expect(e.reason, Recommender.affinityWhy(a, b).$2);
  });

  test('rankOf: posição entre as mais parecidas da biblioteca', () {
    final seed = tr('s', 'X', tags: ['dreamy']);
    final same = tr('mesmo', 'X', tags: ['dreamy']);
    final kin = tr('parente', 'Y', tags: ['dreamy']);
    final far = tr('longe', 'Z', tags: ['party']);
    final lib = [seed, same, kin, far];
    expect(WhyWindow.rankOf(seed, same, lib, Recommender.affinity(seed, same)), 1);
    expect(WhyWindow.rankOf(seed, kin, lib, Recommender.affinity(seed, kin)), 2);
  });

  testWidgets('janela: pontos, clima, estilo e botões; música escolhida por você não mostra pontos', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final seed = tr('Começo', 'X', mood: Mood.triste, tags: ['dreamy']);
    final song = tr('Escolhida', 'X', mood: Mood.triste, tags: ['dreamy']);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: WhyWindow(track: song, seed: seed, library: [seed, song]))));
    expect(t.takeException(), isNull);
    expect(find.text('Por que esta música?'), findsOneWidget);
    expect(find.byKey(const Key('why-points')), findsOneWidget);
    expect(find.text('mesmo artista'), findsOneWidget);
    expect(find.textContaining('a 1ª mais parecida'), findsOneWidget);
    expect(find.textContaining('Escolhido por você'), findsOneWidget);
    expect(find.byKey(const Key('why-fix')), findsOneWidget);

    await t.pumpWidget(MaterialApp(home: Scaffold(body: WhyWindow(track: song, userQueued: true))));
    expect(find.byKey(const Key('why-points')), findsNothing);
    expect(find.textContaining('Você pôs esta música na fila'), findsOneWidget);
  });

  testWidgets('linha curta: mostra o motivo e abre ao tocar', (t) async {
    var opened = 0;
    await t.pumpWidget(MaterialApp(home: Scaffold(body: WhyLine('mesmo estilo (Shoegaze)', onTap: () => opened++))));
    expect(find.text('↳ mesmo estilo (Shoegaze)'), findsOneWidget);
    await t.tap(find.byType(WhyLine));
    expect(opened, 1);
  });
}
