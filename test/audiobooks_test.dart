import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/audiobooks.dart';
import 'package:player_nostalgico/book_service.dart';
import 'package:player_nostalgico/book_text.dart';
import 'package:player_nostalgico/podcast_info.dart' show Chapter;
import 'package:player_nostalgico/screens/audiobooks_screen.dart' show parseClock;
import 'package:player_nostalgico/screens/book_reader.dart';

Uint8List _epub(Map<String, String> files) {
  final a = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    a.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

const _container = '<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>';

const _opf = '''<?xml version="1.0"?>
<package><metadata><dc:title>Memorias Posthumas de Braz Cubas</dc:title><dc:creator>Machado de Assis</dc:creator></metadata>
<manifest>
<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
<item id="lic" href="lic.xhtml" media-type="application/xhtml+xml"/>
<item id="c1" href="text/cap1.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="text/cap2.xhtml" media-type="application/xhtml+xml"/>
</manifest>
<spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/><itemref idref="lic"/></spine></package>''';

void main() {
  group('detecção', () {
    test('título com "audiolivro" e duração longa = livro', () {
      expect(looksLikeAudiobookVideo({'title': 'Memórias Póstumas de Brás Cubas - Machado de Assis - Audiolivro Completo', 'duration': 22000}), isTrue);
      expect(looksLikeAudiobookVideo({'title': 'Dom Casmurro (Audiobook)', 'duration': 30000}), isTrue);
    });

    test('música e podcast não viram livro', () {
      expect(looksLikeAudiobookVideo({'title': 'blink-182 - Feeling This', 'duration': 180}), isFalse);
      expect(looksLikeAudiobookVideo({'title': 'Podcast #123 com Fulano', 'duration': 7200}), isFalse);
    });

    test('vídeo longo com vários capítulos "Capítulo N" = livro', () {
      final info = {
        'title': 'Dom Casmurro',
        'duration': 25000,
        'chapters': [
          for (var i = 1; i <= 5; i++) {'start_time': i * 600.0, 'title': 'Capítulo $i'},
        ],
      };
      expect(looksLikeAudiobookVideo(info), isTrue);
    });

    test('título e autor pelo nome do vídeo', () {
      final a = guessBookNames('Memórias Póstumas de Brás Cubas - Machado de Assis - Audiolivro Completo', channel: 'Canal X');
      expect(a.title, 'Memórias Póstumas de Brás Cubas');
      expect(a.author, 'Machado de Assis');
      final b = guessBookNames('Machado de Assis | Dom Casmurro [AUDIOLIVRO]');
      expect(b.title, 'Dom Casmurro');
      expect(b.author, 'Machado de Assis');
      final c = guessBookNames('O Alienista (Audiolivro)', channel: 'Livros Falados');
      expect(c.title, 'O Alienista');
      expect(c.author, 'Livros Falados');
      final d = guessBookNames('O Cortiço de Aluísio Azevedo audiolivro');
      expect(d.title, 'O Cortiço');
      expect(d.author, 'Aluísio Azevedo');
    });

    test('título e autor: autor conhecido depois da barra, enfeites e emojis', () {
      final a = guessBookNames('Noites Brancas – Audiolivro Completo com Voz Humana | Dostoiévski', channel: 'Canal');
      expect((a.title, a.author), ('Noites Brancas', 'Dostoiévski'));
      final b = guessBookNames('📕 1984 – George Orwell | Livro I | Audiolivro');
      expect((b.title, b.author), ('1984', 'George Orwell'));
      final c = guessBookNames('A Metamorfose - Franz Kafka - narrado por Fulano de Tal');
      expect((c.title, c.author), ('A Metamorfose', 'Franz Kafka'));
      final d = guessBookNames('🎧 Liev Tolstói | A Morte de Ivan Ilitch (Audiobook)');
      expect((d.title, d.author), ('A Morte de Ivan Ilitch', 'Liev Tolstói'));
      expect(isKnownAuthor('Fiódor Dostoiévski'), isTrue);
      expect(isKnownAuthor('Noites Brancas'), isFalse);
    });

    test('grafias do sobrenome para achar no Gutenberg', () {
      expect(surnameVariants('Fiódor Dostoiévski'), containsAll(['dostoievski', 'dostoyevsky']));
      expect(surnameVariants('Liev Tolstói'), containsAll(['tolstoi', 'tolstoy']));
      expect(surnameVariants('Machado de Assis'), ['assis']);
    });

    test('caminhos da pasta Audiolivros', () {
      expect(isAudiobookPath('/m', '/m/Audiolivros/Machado/Livro.m4a'), isTrue);
      expect(isAudiobookPath('/m', '/m/audiolivros/Livro.m4a'), isTrue);
      expect(isAudiobookPath('/m', '/m/Rock/Livro.m4a'), isFalse);
      expect(audiobookTargetPath('/m', 'Machado de Assis', 'Dom Casmurro.m4a'), '/m/Audiolivros/Machado de Assis/Dom Casmurro.m4a');
      expect(bookInfoPath('/m/a/Livro.m4a'), '/m/a/Livro.livro.json');
      expect(bookTextPath('/m/a/Livro.m4a'), '/m/a/Livro.texto.json');
    });
  });

  group('capítulos', () {
    test('números escritos de qualquer jeito', () {
      expect(chapterNumber('7'), 7);
      expect(chapterNumber('VII'), 7);
      expect(chapterNumber('sete'), 7);
      expect(chapterNumber('vinte e um'), 21);
      expect(chapterNumber('três'), 3);
      expect(chapterNumber('delírio'), isNull);
      expect(romanToInt('xlii'), 42);
    });

    test('marcas de tempo da descrição', () {
      const desc = 'Livro narrado por Fulano\n\n0:00 Ao leitor\n1:12 Capítulo 1 - Óbito do autor\n6:40 Capítulo 2 - O emplasto\n1:02:05 Capítulo 3\n';
      final c = chaptersFromDescription(desc);
      expect(c.map((x) => x.startMs), [0, 72000, 400000, 3725000]);
      expect(c[1].title, 'Capítulo 1 - Óbito do autor');
    });

    test('descrição com menos de 3 marcas não conta', () {
      expect(chaptersFromDescription('Ouça em 1:00 e 2:00'), isEmpty);
    });

    test('"capítulo N" falado na legenda, ignorando citações fora de ordem', () {
      final segs = [
        (5000, 'Memórias póstumas de Brás Cubas. Capítulo um.'),
        (300000, 'como eu disse no capítulo um, o emplasto'),
        (400000, 'capítulo dois, o emplasto'),
        (900000, 'veja o capítulo quarenta'),
        (1200000, 'Capítulo 3. A genealogia'),
      ];
      final c = chaptersFromCaptions(segs);
      expect(c.map((x) => x.title), ['Capítulo 1', 'Capítulo 2', 'Capítulo 3']);
      expect(c.map((x) => x.startMs), [5000, 400000, 1200000]);
    });

    test('ordem: capítulos do vídeo, depois descrição, depois legenda', () {
      final (yt, s1) = detectChapters({
        'chapters': [
          {'start_time': 0.0, 'title': 'Intro'},
          {'start_time': 90.0, 'title': 'Capítulo 1'},
        ],
        'description': '0:00 a\n1:00 b\n2:00 c',
      });
      expect(s1, ChapterSource.youtube);
      expect(yt.length, 2);
      final (_, s2) = detectChapters({'description': '0:00 a\n1:00 b\n2:00 c'});
      expect(s2, ChapterSource.description);
      final (_, s3) = detectChapters({}, captions: [(0, 'capítulo 1'), (60000, 'capítulo 2'), (120000, 'capítulo 3')]);
      expect(s3, ChapterSource.captions);
      final (none, s4) = detectChapters({});
      expect(none, isEmpty);
      expect(s4, ChapterSource.none);
    });

    test('resposta do Gemini vira capítulos limpos (com introdução antes do 1º)', () {
      final c = chaptersFromAi({
        'capitulos': [
          {'inicio_s': 300, 'titulo': 'Capítulo 1'},
          {'inicio_s': 305, 'titulo': 'repetido colado'},
          {'inicio_s': 900, 'titulo': 'Capítulo 2'},
        ],
      });
      expect(c.map((x) => x.title), ['Introdução', 'Capítulo 1', 'Capítulo 2']);
    });

    test('informações do livro vão e voltam do JSON; capítulo pela posição', () {
      const info = BookInfo(
        title: 'Dom Casmurro',
        author: 'Machado de Assis',
        chapters: [Chapter(startMs: 0, title: 'Do título'), Chapter(startMs: 60000, title: 'Do livro')],
        chapterSource: ChapterSource.description,
        textStatus: TextStatus.ok,
        textSource: 'Projeto Gutenberg #55752',
        art: {0: 'cap_0.jpg'},
        artDone: true,
      );
      final back = BookInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>);
      expect(back.title, 'Dom Casmurro');
      expect(back.chapters.length, 2);
      expect(back.chapterSource, ChapterSource.description);
      expect(back.textStatus, TextStatus.ok);
      expect(back.art[0], 'cap_0.jpg');
      expect(back.chapterIndexAt(const Duration(seconds: 61)), 1);
      expect(back.chapterIndexAt(Duration.zero), 0);
      expect(back.chapterEndMs(1, 100000), 100000);
    });
  });

  group('texto da obra (EPUB)', () {
    final epub = _epub({
      'META-INF/container.xml': _container,
      'OEBPS/content.opf': _opf,
      'OEBPS/toc.ncx': '<ncx><navMap><navPoint><navLabel><text>Capítulo I</text></navLabel><content src="text/cap1.xhtml"/></navPoint></navMap></ncx>',
      'OEBPS/text/cap1.xhtml': '<html><body><h2>CAPÍTULO I</h2><h3>Óbito do autor</h3><p>Algum tempo hesitei se devia abrir&nbsp;estas memórias.</p>'
          '<p>Suposto o uso vulgar seja começar pelo nascimento, duas considerações me levaram.</p>'
          '<h2>CAPÍTULO II</h2><p>O emplasto. Com efeito, um dia de manhã…</p></body></html>',
      'OEBPS/text/cap2.xhtml': '<html><body><h2>CAPÍTULO VII</h2><h3>O delírio</h3><p>Que me conste, ainda ninguém relatou o seu próprio delírio.</p></body></html>',
      'OEBPS/lic.xhtml': '<html><body><h2>Project Gutenberg License</h2><p>End of the Project Gutenberg EBook. License terms.</p></body></html>',
    });

    test('lê título, autor e capítulos; tira a licença do Gutenberg', () {
      final b = parseEpub(epub);
      expect(b.title, 'Memorias Posthumas de Braz Cubas');
      expect(b.author, 'Machado de Assis');
      expect(b.chapters.map((c) => c.title), ['CAPÍTULO I · Óbito do autor', 'CAPÍTULO II', 'CAPÍTULO VII · O delírio']);
      expect(b.chapters.first.paragraphs.first, 'Algum tempo hesitei se devia abrir estas memórias.');
      expect(b.chapters.first.paragraphs.length, 2);
      final back = BookText.fromJson(jsonDecode(jsonEncode(b.toJson())) as Map<String, dynamic>);
      expect(back.chapters.length, 3);
    });

    test('arquivo que não é EPUB dá erro claro', () {
      expect(() => parseEpub(Uint8List.fromList([1, 2, 3])), throwsA(isA<EpubException>()));
    });

    test('número no título do capítulo', () {
      expect(numberInTitle('CAPÍTULO VII · O delírio'), 7);
      expect(numberInTitle('7. O delírio'), 7);
      expect(numberInTitle('Capítulo sete'), 7);
      expect(numberInTitle('Ao leitor'), isNull);
    });

    test('liga capítulos do áudio aos do texto pelo número', () {
      const audio = [
        Chapter(startMs: 0, title: 'Ao leitor'),
        Chapter(startMs: 1000, title: 'Capítulo 1'),
        Chapter(startMs: 2000, title: 'Capítulo 2'),
        Chapter(startMs: 3000, title: 'Capítulo 7'),
      ];
      final text = [
        const BookChapter('Ao leitor', ['a']),
        const BookChapter('CAPÍTULO I', ['b']),
        const BookChapter('CAPÍTULO II', ['c']),
        const BookChapter('CAPÍTULO VII', ['d']),
      ];
      expect(matchChapters(audio, text), [0, 1, 2, 3]);
    });

    test('sem números: liga pela ordem, alinhando o fim', () {
      const audio = [Chapter(startMs: 0, title: 'Parte A'), Chapter(startMs: 10, title: 'Parte B')];
      final text = [const BookChapter('Prefácio', ['x']), const BookChapter('Um', ['y']), const BookChapter('Dois', ['z'])];
      expect(matchChapters(audio, text), [1, 2]);
    });

    test('posição no texto: dentro do capítulo e pelo livro inteiro', () {
      final text = BookText(chapters: [BookChapter('I', ['a' * 99]), BookChapter('II', ['b' * 99])]);
      const audio = [Chapter(startMs: 0, title: 'Capítulo 1'), Chapter(startMs: 100000, title: 'Capítulo 2')];
      final m = matchChapters(audio, text.chapters);
      final p = textPosition(text: text, audio: audio, match: m, pos: const Duration(seconds: 150), total: const Duration(seconds: 200));
      expect(p.chapter, 1);
      expect(p.fraction, closeTo(.5, .01));
      final whole = textPosition(text: text, audio: const [], match: const [], pos: const Duration(seconds: 50), total: const Duration(seconds: 200));
      expect(whole.chapter, 0);
      expect(whole.fraction, closeTo(.5, .02));
      expect(audioStartOfText(1, audio, m), const Duration(seconds: 100));
    });
  });

  group('busca do texto e das ilustrações', () {
    test('Gutendex: escolhe o livro certo (grafia antiga, autor, epub)', () {
      final json = {
        'results': [
          {
            'id': 1,
            'title': 'Memórias de um Sargento de Milícias',
            'authors': [{'name': 'Almeida, Manuel Antônio de'}],
            'languages': ['pt'],
            'formats': {'application/epub+zip': 'x'},
          },
          {
            'id': 54829,
            'title': 'Memorias Posthumas de Braz Cubas',
            'authors': [{'name': 'Machado de Assis'}],
            'languages': ['pt'],
            'formats': {'application/epub+zip': 'x'},
          },
        ],
      };
      expect(BookService.pickGutenberg(json, 'Memórias Póstumas de Brás Cubas', 'Machado de Assis')?.id, 54829);
      expect(BookService.pickGutenberg(json, 'Harry Potter', 'J. K. Rowling'), isNull);
    });

    test('Gutendex: autor em grafia inglesa e texto em inglês com aviso', () {
      final json = {
        'results': [
          {
            'id': 36034,
            'title': 'White Nights and Other Stories',
            'authors': [{'name': 'Dostoyevsky, Fyodor'}],
            'languages': ['en'],
            'formats': {'application/epub+zip': 'x'},
          },
        ],
      };
      final r = BookService.pickGutenberg(json, 'White Nights', 'Fiódor Dostoiévski')!;
      expect(r.id, 36034);
      expect(BookService.langLabel(r.lang), ' (em inglês)');
      expect(BookService.bookIdentityFromAi({'titulo_en': 'White Nights', 'autor_en': 'Fyodor Dostoyevsky'}),
          (title: 'White Nights', author: 'Fyodor Dostoyevsky'));
      expect(BookService.bookIdentityFromAi({'titulo_en': ''}), isNull);
      expect(BookService.bookIdentityFromAi('lixo'), isNull);
    });

    test('Wikisource: página da obra, não capítulo solto', () {
      final json = {
        'query': {
          'search': [
            {'title': 'Memórias Póstumas de Brás Cubas/Capítulo VII'},
            {'title': 'Memórias Póstumas de Brás Cubas'},
          ],
        },
      };
      expect(BookService.pickWikisource(json, 'Memórias Póstumas de Brás Cubas'), 'Memórias Póstumas de Brás Cubas');
    });

    test('Commons: só imagem em domínio público', () {
      final json = {
        'query': {
          'pages': {
            '1': {
              'index': 1,
              'title': 'File:Foto moderna.jpg',
              'imageinfo': [
                {'mime': 'image/jpeg', 'thumburl': 'https://u/1.jpg', 'extmetadata': {'LicenseShortName': {'value': 'CC BY-SA 4.0'}}},
              ],
            },
            '2': {
              'index': 2,
              'title': 'File:Gravura 1880.jpg',
              'imageinfo': [
                {
                  'mime': 'image/jpeg',
                  'thumburl': 'https://u/2.jpg',
                  'extmetadata': {'LicenseShortName': {'value': 'Public domain'}, 'Artist': {'value': '<a>Fulano</a>'}},
                },
              ],
            },
          },
        },
      };
      final r = BookService.pickCommons(json)!;
      expect(r.url, 'https://u/2.jpg');
      expect(r.credit, contains('Fulano'));
      expect(BookService.pickCommons(json, skip: {'File:Gravura 1880.jpg'}), isNull);
    });

    test('teto de 30 ilustrações, espalhadas pelo livro', () {
      expect(BookService.artSlots(5), [0, 1, 2, 3, 4]);
      final s = BookService.artSlots(160);
      expect(s.length, BookService.maxArt);
      expect(s.first, 0);
      expect(s.last, greaterThan(150));
    });

    test('títulos parecidos', () {
      expect(BookService.titleSimilarity('Memórias Póstumas de Brás Cubas', 'Memorias Posthumas de Braz Cubas'), 1.0);
      expect(BookService.titleSimilarity('Dom Casmurro', 'Quincas Borba'), 0.0);
    });
  });

  group('leitor', () {
    test('dobra da folha: canto puxado até o meio divide a página', () {
      const c = Curl(Size(100, 200), Offset(100, 200), Offset(0, 200));
      // reta da dobra em x = 50: metade continua deitada, a outra metade vira por cima
      for (final q in c.flat) {
        expect(q.dx, lessThanOrEqualTo(50.001));
      }
      for (final q in c.flap) {
        expect(q.dx, lessThanOrEqualTo(50.001));
      }
      expect(c.flap, isNotEmpty);
      const none = Curl(Size(100, 200), Offset(100, 200), Offset(100, 200));
      expect(none.flap, isEmpty);
      expect(none.flat.length, 4);
    });

    test('divide o capítulo em páginas sem perder letra', () {
      final ch = BookChapter('CAPÍTULO I', [for (var i = 0; i < 30; i++) 'Parágrafo $i ${'palavra ' * 40}'.trim()]);
      const spec = PageSpec(
        size: Size(320, 300),
        body: TextStyle(fontSize: 14, height: 1.4),
        title: TextStyle(fontSize: 12),
        padding: EdgeInsets.all(10),
      );
      final pages = paginate(0, ch, spec);
      expect(pages.length, greaterThan(3));
      var total = 0;
      for (final pg in pages) {
        for (final s in pg.segs) {
          total += s.end - s.start;
        }
      }
      final letters = ch.paragraphs.fold<int>(0, (a, b) => a + b.length);
      // só os espaços entre um pedaço e outro de um parágrafo cortado podem sobrar
      expect(total, greaterThan(letters - pages.length * 2));
      expect(pageForFraction(pages, ch.length, 0), 0);
      expect(pageForFraction(pages, ch.length, 1), pages.length - 1);
      expect(pageForFraction(pages, ch.length, .5), inInclusiveRange(1, pages.length - 2));
    });

    test('tempo digitado no ajuste do capítulo', () {
      expect(parseClock('1:02:10'), const Duration(hours: 1, minutes: 2, seconds: 10));
      expect(parseClock('12:05'), const Duration(minutes: 12, seconds: 5));
      expect(parseClock('abc'), isNull);
    });
  });
}
