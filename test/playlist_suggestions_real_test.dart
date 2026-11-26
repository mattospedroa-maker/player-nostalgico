import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/lastfm.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/mood.dart';
import 'package:player_nostalgico/recommender.dart';
import 'package:player_nostalgico/styles.dart';

var _id = 0;
final _tags = <String, List<MusicTag>>{};
Track tr(String title, String artist, String genre, [List<String> tags = const []]) {
  final t = Track(id: ++_id, path: '/m/$artist/$title.mp3', title: title, artist: artist, album: unknownAlbum, genre: genre, addedAt: 0, modifiedAt: 0);
  _tags[t.path] = [for (var i = 0; i < tags.length; i++) MusicTag(tags[i], 100 - i * 6)];
  return t;
}

void main() {
  setUp(() {
    MoodClues.tagsOf = (t) => _tags[t.path];
    Styles.trackTags = (t) => _tags[t.path];
    MoodClues.invalidate();
    Styles.invalidate();
  });
  tearDown(() {
    MoodClues.tagsOf = (_) => null;
    Styles.trackTags = (_) => null;
    Styles.invalidate();
  });
  final pl = [
    tr('When the Sun Hits', 'Slowdive', 'Shoegaze', ['shoegaze', 'dream pop', '90s', 'alternative', 'dreamy', 'ethereal', 'indie', 'beautiful']),
    tr('Starting Over', 'lsdnthesearchforgod', 'Shoegaze', ['shoegaze', 'dream pop', 'lo-fi', 'indie', 'dreamy']),
    tr('Спокойная ночь', 'Группа КИНО', 'Post-Punk', ['post-punk', 'russian rock', 'new wave', 'russian', '80s', 'rock']),
    tr('Cico Buff', 'Cocteau Twins', 'Dream Pop', ['dream pop', 'ethereal', '4ad', 'shoegaze', '80s', 'female vocalists', 'ethereal wave']),
  ];
  final lib = [
    ...pl,
    tr('Intro', 'The xx', 'Indie', ['indie', 'instrumental', 'electronic', 'dream pop', 'chillout', 'ambient', 'minimal', 'atmospheric']),
    tr('A Quick One Before the Eternal Worm Devours Connecticut', 'Have a Nice Life', 'Post-Punk', ['shoegaze', 'post-punk', 'experimental', 'drone', 'lo-fi', 'noise rock', 'darkwave']),
    tr('Disorder', 'Joy Division', 'Post-Punk', ['post-punk', 'new wave', '80s', 'classic rock', 'british']),
    tr('Myth', 'Beach House', 'Dream Pop', ['dream pop', 'indie', 'shoegaze', 'dreamy', 'female vocalists']),
    tr('Sudno', 'Molchat Doma', 'Post-Punk', ['post-punk', 'coldwave', 'darkwave', 'russian', 'synthpop']),
    tr('Let It Happen', 'Tame Impala', 'Psychedelic Rock', ['psychedelic', 'indie', 'psychedelic rock', 'dreamy', 'electronic']),
    tr('Creep', 'Radiohead', 'Alternative Rock', ['alternative', 'alternative rock', 'rock', '90s', 'sad']),
    tr('Numb', 'Linkin Park', 'Nu Metal', ['nu metal', 'rock', 'alternative rock', 'metal']),
    tr('Smells Like Teen Spirit', 'Nirvana', 'Grunge', ['grunge', 'rock', '90s', 'alternative']),
    tr('Bad Romance', 'Lady Gaga', 'Pop', ['pop', 'dance', 'female vocalists', 'electronic']),
    tr('One More Time', 'Daft Punk', 'House', ['house', 'electronic', 'dance', 'french house']),
    tr('Unravel', 'TK from Ling tosite sigure', 'J-Rock', ['anime', 'j-rock', 'japanese', 'rock']),
    tr('Só os Loucos Sabem', 'Charlie Brown Jr.', 'Rock', ['rock', 'brazilian', 'rock nacional']),
    tr('Washing Machine Heart', 'Mitski', 'Indie Rock', ['indie', 'indie rock', 'indie pop', 'female vocalists']),
    tr('Sweater Weather', 'The Neighbourhood', 'Alternative', ['alternative', 'indie', 'indie rock']),
  ];
  // playlist de teste de Cuseko (difícil de ver o que há em comum) e as duas que ele acha que deveriam aparecer
  test('playlist "looking for god": acha The xx e Have a Nice Life pelas tags, sem metal/pop/dance', () {
    MoodClues.invalidate();
    final r = Recommender.forPlaylist(pl, lib, playlistName: 'looking for god', limit: 6);
    final names = [for (final s in r) s.track.artist];
    expect(names, containsAll(['The xx', 'Have a Nice Life', 'Beach House']));
    expect(names, isNot(anyOf(contains('Linkin Park'), contains('Lady Gaga'), contains('Daft Punk'), contains('Nirvana'))));
    // The xx tem gênero "Indie", mas entra pelo "dream pop" das tags (é o que aparece na etiqueta)
    expect(r.firstWhere((s) => s.track.artist == 'The xx').genre, 'Dream Pop');
    expect(r.firstWhere((s) => s.track.artist == 'Have a Nice Life').genre, 'Shoegaze');
    // e passa à frente de uma música só "calma" e "indie"
    expect(names.indexOf('The xx'), lessThan(names.indexOf('Tame Impala')));
  });

  test('sem tags guardadas: só o gênero, e nada quebra', () {
    MoodClues.invalidate();
    Styles.trackTags = (_) => null;
    Styles.invalidate();
    final r = Recommender.forPlaylist(pl, lib, tagsOf: (_) => null);
    expect([for (final s in r) s.track.artist], contains('Have a Nice Life')); // Post-Punk igual ao do КИНО
  });
}
