import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/thumbnails.dart';

Track t(int id, String album) => Track(id: id, path: '/m/$id.mp3', title: 't$id', artist: 'A', album: album, addedAt: 0, modifiedAt: 0);

void main() {
  test('miniatura sem capa: o GIF que mais aparece nas músicas do grupo', () {
    final group = [t(1, 'X'), t(2, 'X'), t(3, 'X')];
    final pinned = {
      1: ['/g/a.gif', '/g/b.gif'],
      2: ['/g/b.gif'],
      3: ['/g/b.gif', '/g/c.gif'],
      9: ['/g/a.gif', '/g/a.gif'], // outra música, fora do grupo
    };
    expect(mostFrequentGif(group, pinned), '/g/b.gif');
    expect(mostFrequentGif(group, pinned, exists: (p) => p != '/g/b.gif'), '/g/a.gif');
    expect(mostFrequentGif([t(5, 'Y')], pinned), isNull);
  });

  test('foto do artista usa o álbum com mais faixas', () {
    final g = [t(1, 'Single'), t(2, 'Disco'), t(3, 'Disco')];
    expect(byMainAlbum(g).first.album, 'Disco');
  });

  test('índice A–Z ignora acentos, aspas e símbolos; números vão para #', () {
    expect(indexLetter('"NADA-IZED!"'), 'N');
    expect(indexLetter('-ERROR 2018ver'), 'E');
    expect(indexLetter('Álbum Branco'), 'A');
    expect(indexLetter('1988-12-28 The Underground'), '#');
    final names = ['Zé', '05.13.90 Lincoln', 'Évora', 'abba', '"NADA"']..sort(compareForIndex);
    expect(names, ['05.13.90 Lincoln', 'abba', 'Évora', '"NADA"', 'Zé']);
    expect(firstIndexForLetter(names, 'N'), 3);
    expect(firstIndexForLetter(names, 'O'), 4); // sem "O": vai para a próxima letra que existe
    expect(firstIndexForLetter(names, '#'), 0);
  });
}
