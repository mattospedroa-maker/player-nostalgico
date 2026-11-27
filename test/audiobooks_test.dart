import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player_nostalgico/audiobooks.dart';
import 'package:player_nostalgico/author_photos.dart';
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

    test('letra do Android maior: mede com ela e cada página cabe inteira', () {
      final ch = BookChapter('Introdução', [for (var i = 0; i < 6; i++) 'Parágrafo $i ${'palavra ' * 40}'.trim()]);
      PageSpec spec(double scale) => PageSpec(
            size: const Size(320, 300),
            body: const TextStyle(fontSize: 14, height: 1.4),
            title: const TextStyle(fontSize: 12),
            padding: const EdgeInsets.all(10),
            artHeight: 100,
            scaler: TextScaler.linear(scale),
          );
      final normal = paginate(0, ch, spec(1), hasArt: true);
      final big = paginate(0, ch, spec(1.4), hasArt: true);
      expect(big.length, greaterThan(normal.length));
      // altura de cada página medida como a tela desenha (com a escala) nunca passa do espaço
      final sp = spec(1.4);
      for (final pg in big) {
        var used = pg.first ? 100 + sp.gap + 30 : 0.0;
        for (final sg in pg.segs) {
          final tp = TextPainter(
              text: TextSpan(text: (sg.start == 0 ? '  ' : '') + ch.paragraphs[sg.para].substring(sg.start, sg.end), style: sp.body),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.justify,
              textScaler: sp.scaler)
            ..layout(maxWidth: sp.width);
          used += tp.height + sp.gap;
          tp.dispose();
        }
        expect(used - sp.gap, lessThanOrEqualTo(sp.height + 30));
      }
      // ilustração enorme que não deixa nem uma linha: o texto vai para a página seguinte, não é despejado inteiro
      final full = PageSpec(size: const Size(320, 300), body: const TextStyle(fontSize: 14), title: const TextStyle(fontSize: 12), padding: const EdgeInsets.all(10), artHeight: 250);
      final pages = paginate(0, ch, full, hasArt: true);
      expect(pages.first.segs, isEmpty);
      expect(pages.length, greaterThan(2));
    });

    test('tempo digitado no ajuste do capítulo', () {
      expect(parseClock('1:02:10'), const Duration(hours: 1, minutes: 2, seconds: 10));
      expect(parseClock('12:05'), const Duration(minutes: 12, seconds: 5));
      expect(parseClock('abc'), isNull);
    });
  });

  group('texto pela transcrição do vídeo', () {
    // legenda de audiolivro: um trecho a cada ~3 s, sem pontuação
    List<(int, String)> segs(int n, {int every = 3000, int startMs = 0}) =>
        [for (var i = 0; i < n; i++) (startMs + i * every, 'palavra um dois três quatro cinco seis sete oito número $i')];

    test('parágrafos pelas pausas, com maiúscula, ponto e tempo de início', () {
      final s = [
        (0, 'era uma vez'),
        (2000, 'um sonhador em são petersburgo'),
        (4000, '[Música]'),
        (60000, 'outra noite chegou'), // pausa longa só conta com parágrafo comprido; aqui segue junto
      ];
      final p = roughParagraphs(s);
      expect(p.length, 1);
      expect(p.first.$1, 0);
      expect(p.first.$2, startsWith('Era uma vez um sonhador'));
      expect(p.first.$2, isNot(contains('Música')));
      expect(p.first.$2, endsWith('.'));
      final long = roughParagraphs(segs(40)); // ~400 palavras: corta a cada ~120
      expect(long.length, greaterThanOrEqualTo(3));
      expect(long[1].$1, greaterThan(0));
    });

    test('divide pelos capítulos do áudio; sem capítulos, partes de 30 min', () {
      final pars = [(0, 'A.'), (65000, 'B.'), (130000, 'C.')];
      final c = splitByTime(pars, const [Chapter(startMs: 0, title: 'Primeira noite'), Chapter(startMs: 120000, title: 'Segunda noite')]);
      expect(c.map((x) => x.title), ['Primeira noite', 'Segunda noite']);
      expect(c[0].paragraphs, ['A.', 'B.']);
      expect(c[1].times, [130000]);
      final parts = splitByTime([(0, 'A.'), (2000000, 'B.')], const []);
      expect(parts.map((x) => x.title), ['Parte 1', 'Parte 2']);
      // capítulo do áudio começando depois do 1º parágrafo: o começo fica no 1º capítulo
      expect(splitByTime([(0, 'Intro.'), (5000, 'X.')], const [Chapter(startMs: 3000, title: 'I')]).first.paragraphs, ['Intro.', 'X.']);
    });

    test('posição exata pelo tempo de cada parágrafo', () {
      final text = BookText(chapters: [
        BookChapter('I', const ['aaaa', 'bbbb'], const [0, 10000]),
        BookChapter('II', const ['cccc'], const [20000]),
      ]);
      expect(text.timed, isTrue);
      var at = textPosition(text: text, audio: const [], match: const [], pos: const Duration(seconds: 15), total: const Duration(seconds: 30));
      expect(at.chapter, 0);
      expect(at.fraction, closeTo((5 + 2) / 10, .01)); // 2º parágrafo, metade dele
      at = textPosition(text: text, audio: const [], match: const [], pos: const Duration(seconds: 25), total: const Duration(seconds: 30));
      expect(at.chapter, 1);
      expect(at.fraction, closeTo(.4, .01));
      // ida e volta no JSON mantém os tempos; EPUB (sem tempos) não grava nada a mais
      final back = BookText.fromJson(jsonDecode(jsonEncode(text.toJson())) as Map<String, dynamic>);
      expect(back.chapters[0].times, [0, 10000]);
      expect(const BookChapter('x', ['y']).toJson().containsKey('ms'), isFalse);
    });

    test('resposta do Gemini: aceita pontuada, recusa resumo, ordem errada ou número fora do pedaço', () {
      final s = [(1000, 'era uma vez um sonhador'), (4000, 'que morava sozinho'), (7000, 'em são petersburgo')];
      final ok = polishedFromAi({
        'p': [
          {'i': 10, 't': 'Era uma vez um sonhador que morava sozinho'},
          {'i': 12, 't': 'em São Petersburgo.'},
        ],
      }, s, 10)!;
      expect(ok, [(1000, 'Era uma vez um sonhador que morava sozinho'), (7000, 'em São Petersburgo.')]);
      expect(polishedFromAi({'p': [{'i': 10, 't': 'Um sonhador.'}]}, s, 10), isNull); // resumiu
      expect(
          polishedFromAi({
            'p': [
              {'i': 12, 't': 'em São Petersburgo era uma vez'},
              {'i': 10, 't': 'um sonhador que morava sozinho.'},
            ],
          }, s, 10),
          isNull);
      expect(polishedFromAi({'p': [{'i': 99, 't': 'era uma vez um sonhador que morava sozinho em são petersburgo'}]}, s, 10), isNull);
      expect(polishedFromAi('lixo', s, 10), isNull);
      expect(polishPrompt(title: 'Noites Brancas', author: 'Dostoiévski', segs: s, firstIndex: 10), contains('[12] em são petersburgo'));
    });

    test('transcrição guardada: pedaços arrumados + resto pelas pausas', () {
      final all = segs(Transcript.chunk + 20);
      var tr = Transcript(all);
      expect(tr.chunks, 2);
      expect(tr.finished, isFalse);
      tr = Transcript(all, polished: const [(0, 'Primeiro pedaço arrumado.')], done: 1);
      final pars = tr.paragraphs();
      expect(pars.first, (0, 'Primeiro pedaço arrumado.'));
      expect(pars[1].$1, all[Transcript.chunk].$1); // o resto começa no 1º trecho do pedaço seguinte
      final back = Transcript.fromJson(jsonDecode(jsonEncode(tr.toJson())) as Map<String, dynamic>);
      expect(back.done, 1);
      expect(back.segs.length, all.length);
      final book = back.toBook(title: 'T', author: 'A', audio: const []);
      expect(book.timed, isTrue);
    });

    test('ordem da busca: texto livre só na língua da narração primeiro; busca nova tenta de novo', () {
      final json = {
        'results': [
          {
            'id': 7,
            'title': 'Noites Brancas',
            'authors': [{'name': 'Dostoyevsky, Fyodor'}],
            'languages': ['en'],
            'formats': {'application/epub+zip': 'x'},
          },
        ],
      };
      expect(BookService.pickGutenberg(json, 'Noites Brancas', 'Dostoiévski', lang: 'pt'), isNull);
      expect(BookService.pickGutenberg(json, 'Noites Brancas', 'Dostoiévski')?.id, 7);
      final s = BookService(client: _NoNet(), geminiKey: () => '');
      expect(s.shouldSearchText(const BookInfo(textStatus: TextStatus.notFound)), isTrue);
      expect(s.shouldSearchText(const BookInfo(textStatus: TextStatus.notFound, searchVersion: BookService.searchVersion)), isFalse);
      expect(s.shouldSearchText(const BookInfo(textStatus: TextStatus.ok, textSource: 'Projeto Gutenberg #1 (em inglês)')), isTrue);
      expect(s.shouldSearchText(const BookInfo(textStatus: TextStatus.ok, textSource: 'Projeto Gutenberg #1')), isFalse);
      final info = BookInfo.fromJson(jsonDecode(jsonEncode(const BookInfo(language: 'pt', searchVersion: 2).toJson())) as Map<String, dynamic>);
      expect((info.language, info.searchVersion), ('pt', 2));
    });
  });
  group('foto do autor', () {
    Map<String, dynamic> wiki(List<Map<String, Object>> pages) => {
          'query': {
            'pages': {for (var i = 0; i < pages.length; i++) '$i': {'index': i + 1, ...pages[i]}},
          },
        };
    const img = {'source': 'https://upload.wikimedia.org/x.jpg'};

    test('acha o escritor certo e ignora homônimos e páginas sem foto', () {
      final r = AuthorPhotoService.pickAuthorPage(
          wiki([
            {'title': 'Noites Brancas', 'description': 'novela de Fiódor Dostoiévski', 'thumbnail': img},
            {'title': 'Fiódor Dostoiévski', 'description': 'escritor russo'},
            {'title': 'Fiódor Dostoiévski', 'description': 'escritor e filósofo russo', 'thumbnail': img},
          ]),
          'Dostoiévski')!;
      expect(r.title, 'Fiódor Dostoiévski');
      expect(r.about, 'escritor e filósofo russo');
      // prenome em outra grafia (Leo/Liev) vale pelo sobrenome
      expect(AuthorPhotoService.pickAuthorPage(wiki([{'title': 'Leo Tolstoy', 'description': 'Russian writer (1828–1910)', 'thumbnail': img}]), 'Liev Tolstói')?.title,
          'Leo Tolstoy');
      // mesmo nome, mas não é escritor; ou nome de canal sem página
      expect(AuthorPhotoService.pickAuthorPage(wiki([{'title': 'George Lewis', 'description': 'jogador de futebol', 'thumbnail': img}]), 'C.S Lewis'), isNull);
      expect(AuthorPhotoService.pickAuthorPage(wiki([{'title': 'Livros Falados', 'description': 'escritor', 'thumbnail': img}]), 'Canal Audiolivros BR'), isNull);
    });
  });

  group('destaque da frase lida', () {
    test('legenda json3: tempo de cada palavra', () {
      final body = jsonEncode({
        'events': [
          {
            'tStartMs': 1000,
            'segs': [
              {'utf8': 'era'},
              {'utf8': ' uma', 'tOffsetMs': 300},
              {'utf8': ' vez', 'tOffsetMs': 650},
            ],
          },
          {'tStartMs': 2000, 'aAppend': 1, 'segs': [{'utf8': '\n'}]},
          {
            'tStartMs': 2500,
            'segs': [
              {'utf8': 'um'},
              {'utf8': ' sonhador', 'tOffsetMs': 200},
            ],
          },
        ],
      });
      final r = parseJson3Words(body);
      expect(r.segs, [(1000, 'era uma vez'), (2500, 'um sonhador')]);
      expect(r.offsets, [[0, 300, 650], [0, 200]]);
      final tr = Transcript(r.segs, offsets: r.offsets);
      expect(tr.hasWordTimes, isTrue);
      expect(tr.wordStream(), [('era', 1000), ('uma', 1300), ('vez', 1650), ('um', 2500), ('sonhador', 2700)]);
      final back = Transcript.fromJson(jsonDecode(jsonEncode(tr.toJson())) as Map<String, dynamic>);
      expect(back.offsets, r.offsets);
      // texto feito agora sabe que os trechos já vão até a vírgula (livros antigos são cortados de novo)
      final book = tr.toBook(title: 'x', author: 'y', audio: const []);
      expect(book.pieces, BookText.piecesVersion);
      expect(BookText.fromJson(jsonDecode(jsonEncode(book.toJson())) as Map<String, dynamic>).pieces, BookText.piecesVersion);
      expect(BookText.fromJson(const {'capitulos': []}).pieces, 0);
      expect(Transcript(r.segs).hasWordTimes, isFalse);
    });

    test('frases do texto do Gemini casam com as palavras da legenda, mesmo com palavra trocada', () {
      final stream = [
        for (final (i, w) in 'era uma vez um sonhador que morava sozinho em são petersburgo ele andava pelas ruas toda noite'.split(' ').indexed)
          (wordKey(w), 10000 + i * 400),
      ];
      final pars = [(10000, 'Era uma vez um sonhador que morava sozinho em São Petersburgo. Ele caminhava pelas ruas toda noite.')];
      final f = sentenceTimes(pars, stream).single;
      expect(f.length, 4); // duas frases: [letra, ms, letra, ms]
      expect(f[0], 0);
      expect(f[1], 10000);
      expect(pars.single.$2.substring(f[2]), startsWith('Ele caminhava'));
      expect(f[3], 10000 + 11 * 400); // "ele" é a 12ª palavra da legenda
      // sem legenda com tempos: nada de destaque
      expect(sentenceTimes(pars, const []).single, isEmpty);
    });

    test('destaque vai até a vírgula ou o ponto, sem trechos minúsculos', () {
      const t = 'Mostrava simplesmente um rosto enorme, mais de 1 m de largura. O rosto de um homem de cerca de 45 anos, '
          'com um bigode preto farto e traços acidentalmente bonitos. Winston, porém, alcançou as escadas.';
      List<String> pieces(String s) {
        final st = pieceStarts(s);
        return [for (var i = 0; i < st.length; i++) s.substring(st[i], i + 1 < st.length ? st[i + 1] : s.length).trim()];
      }

      expect(pieces(t), [
        'Mostrava simplesmente um rosto enorme,',
        'mais de 1 m de largura.',
        'O rosto de um homem de cerca de 45 anos,',
        'com um bigode preto farto e traços acidentalmente bonitos.',
        'Winston, porém, alcançou as escadas.', // "Winston," e "porém," sozinhos piscariam
      ]);
      expect(pieces('Ele parou — e olhou para trás; ninguém vinha: estava só.'), ['Ele parou — e olhou para trás;', 'ninguém vinha: estava só.']);
      expect(pieces('Sim.'), ['Sim.']);
      expect(pieces('Era uma frase longa sem vírgula nenhuma'), ['Era uma frase longa sem vírgula nenhuma']);
    });

    test('frase lida pelo tempo e a página onde ela está', () {
      final text = BookText(chapters: [
        BookChapter('I', const ['Primeira frase. Segunda frase.', 'Outro parágrafo.'], const [0, 8000], const [
          [0, 0, 16, 4000],
          [0, 8000],
        ]),
      ]);
      expect(text.chapters.first.hasSentences, isTrue);
      expect(sentenceAt(text, 1000), (chapter: 0, para: 0, start: 0, end: 16));
      expect(sentenceAt(text, 5000), (chapter: 0, para: 0, start: 16, end: 30));
      expect(sentenceAt(text, 9000), (chapter: 0, para: 1, start: 0, end: 16));
      expect(sentenceAt(BookText(chapters: [BookChapter('x', const ['y'])]), 1000), isNull); // EPUB: sem tempos
      final back = BookText.fromJson(jsonDecode(jsonEncode(text.toJson())) as Map<String, dynamic>);
      expect(back.chapters.first.sentences, text.chapters.first.sentences);
      const pages = [
        BookPage(0, 0, [PageSeg(0, 0, 20)], 0),
        BookPage(0, 1, [PageSeg(0, 21, 30), PageSeg(1, 0, 16)], 20),
      ];
      expect(pageForChar(pages, 0, 16), 0);
      expect(pageForChar(pages, 0, 20), 1); // espaço pulado no corte
      expect(pageForChar(pages, 1, 0), 1);
      // frase dividida entre as páginas 0 e 1 (letras 16 a 30, lida de 4 s a 8 s): vira no meio dela
      expect(readingAt(text, 4000), (chapter: 0, para: 0, char: 16));
      expect(pageForChar(pages, 0, readingAt(text, 4500)!.char), 0); // começo da frase, ainda na página 0
      expect(pageForChar(pages, 0, readingAt(text, 7000)!.char), 1); // narração já na parte de baixo: página 1
      expect(readingAt(text, 7999)!.char, lessThan(30));
      expect(readingAt(text, 8000), (chapter: 0, para: 1, char: 0));
      expect(readingAt(text, 9000)!.char, 14); // fim do livro, sem próximo tempo: ~14 letras por segundo
    });

    test('transcrição é o padrão: livro com texto do Gutenberg e vídeo tenta de novo', () {
      final s = BookService(client: _NoNet(), geminiKey: () => '');
      expect(s.shouldSearchText(const BookInfo(videoId: 'abc', textStatus: TextStatus.ok, textSource: 'Projeto Gutenberg #1', searchVersion: 2)), isTrue);
      expect(s.shouldSearchText(const BookInfo(textStatus: TextStatus.ok, textSource: 'Projeto Gutenberg #1', searchVersion: 2)), isFalse); // sem vídeo
      expect(s.shouldSearchText(const BookInfo(videoId: 'abc', textStatus: TextStatus.ok, textSource: 'EPUB anexado (x.epub)', searchVersion: 2)), isFalse);
      expect(s.shouldSearchText(const BookInfo(videoId: 'abc', textStatus: TextStatus.ok, textSource: 'Projeto Gutenberg #1', searchVersion: BookService.searchVersion)), isFalse);
    });
  });

  group('pinturas e pranchas das cenas', () {
    test('uma prancha a cada ~10 min, com o que sobra do teto', () {
      final t = BookService.sceneTimes(totalMs: 150 * 60000, chapterArt: 5);
      expect(t.length, 15);
      expect(t.first, greaterThan(0));
      expect(t.last, lessThan(150 * 60000));
      expect(BookService.sceneTimes(totalMs: 600 * 60000, chapterArt: 5).length, BookService.maxArt - 5); // teto
      expect(BookService.sceneTimes(totalMs: 5 * 60000, chapterArt: 2), isEmpty); // livro curto
      expect(BookService.sceneTimes(totalMs: 150 * 60000, chapterArt: BookService.maxArt), isEmpty);
      const info = BookInfo(scenes: {1000: (60000, 'O encontro na ponte')}, artVersion: 2);
      final back = BookInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>);
      expect(back.scenes, {1000: (60000, 'O encontro na ponte')});
      expect(back.artVersion, 2);
    });

    test('com destaque, cada página deixa uma linha livre e cabe mesmo com a frase em negrito e itálico', () {
      final ch = BookChapter('I', [for (var i = 0; i < 8; i++) 'Parágrafo $i, ${'palavra larga, ' * 30}fim.'.trim()]);
      const body = TextStyle(fontSize: 14, height: 1.4);
      const plain = PageSpec(size: Size(320, 400), body: body, title: TextStyle(fontSize: 12), padding: EdgeInsets.all(10));
      const spec = PageSpec(size: Size(320, 400), body: body, title: TextStyle(fontSize: 12), padding: EdgeInsets.all(10), reserveLine: true);
      expect(plain.height - spec.height, closeTo(14 * 1.4, .01));
      expect(spec == plain, isFalse); // muda a opção: divide de novo
      final pages = paginate(0, ch, spec);
      for (final pg in pages.skip(1)) {
        // pior caso: a página inteira destacada (letras mais largas) ainda cabe na altura sem a folga
        final tp = TextPainter(
          text: TextSpan(style: body, children: [
            for (final s in pg.segs)
              TextSpan(
                  text: '${s.start == 0 ? '  ' : ''}${ch.paragraphs[s.para].substring(s.start, s.end)}\n',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
          ]),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: spec.width);
        expect(tp.height, lessThanOrEqualTo(plain.height + pg.segs.length * spec.gap + 1));
        tp.dispose();
      }
    });

    test('busca de pintura vai simplificando até achar; livro sem nenhuma imagem tenta de novo', () {
      final q = BookService.artQueries('20th century English painting London street rain');
      expect(q.first, '20th century English painting London street rain');
      expect(q, contains('20th century English painting'));
      expect(q, contains('London street painting'));
      expect(q.last, 'rain painting');
      expect(BookService.artQueries('Big Brother poster'), ['Big Brother poster', 'Big Brother painting', 'poster painting', 'Big Brother poster painting']);
      expect(BookService.artQueries('  '), isEmpty);
      expect(BookService.needsArt(const BookInfo()), isTrue);
      expect(BookService.needsArt(const BookInfo(artDone: true, artVersion: 2)), isTrue); // v2 sem nenhuma imagem
      expect(BookService.needsArt(const BookInfo(artDone: true, artVersion: 2, art: {0: 'cap_0.jpg'})), isFalse);
      expect(BookService.needsArt(const BookInfo(artDone: true, artVersion: BookService.artVersion)), isFalse); // não insiste
    });

    test('com destaque, a página acaba no fim de um trecho (nenhum trecho dividido)', () {
      final pars = [for (var i = 0; i < 6; i++) List.generate(12, (k) => 'trecho $i.$k com algumas palavras a mais,').join(' ')];
      final sentences = [for (final t in pars) [for (final st in pieceStarts(t)) ...[st, 0]]];
      final ch = BookChapter('I', pars, [for (var i = 0; i < pars.length; i++) i * 1000], sentences);
      const spec = PageSpec(size: Size(320, 400), body: TextStyle(fontSize: 14, height: 1.4), title: TextStyle(fontSize: 12), padding: EdgeInsets.all(10), reserveLine: true);
      final pages = paginate(0, ch, spec);
      expect(pages.length, greaterThan(3));
      var splits = 0;
      for (final pg in pages) {
        final last = pg.segs.last;
        if (last.end >= pars[last.para].length) continue;
        splits++;
        expect(pieceStarts(pars[last.para]), contains(last.end)); // corta bem no começo de um trecho
      }
      expect(splits, greaterThan(0));
      int letters(List<BookPage> ps) => ps.fold(0, (a, p) => a + p.segs.fold(0, (b, s) => b + s.end - s.start));
      expect(letters(pages), greaterThan(pars.fold<int>(0, (a, t) => a + t.length) - pages.length * 2)); // nada some
      // sem destaque: corta onde a linha acabar, como antes
      const plain = PageSpec(size: Size(320, 400), body: TextStyle(fontSize: 14, height: 1.4), title: TextStyle(fontSize: 12), padding: EdgeInsets.all(10));
      expect(paginate(0, ch, plain).any((pg) => pg.segs.last.end < pars[pg.segs.last.para].length && !pieceStarts(pars[pg.segs.last.para]).contains(pg.segs.last.end)), isTrue);
    });

    test('pintura aparece com uma frase só (começo do capítulo e prancha)', () {
      final pars = [for (var i = 0; i < 6; i++) 'Frase $i de abertura, ${'e depois vem mais texto, ' * 12}fim.'];
      const spec = PageSpec(size: Size(320, 400), body: TextStyle(fontSize: 14, height: 1.4), title: TextStyle(fontSize: 12), padding: EdgeInsets.all(10), artHeight: 140);
      final ch = BookChapter('I', pars);
      final pages = paginate(0, ch, spec, hasArt: true, plates: const [(3, 1000)]);
      // 1ª página: pintura + 'Frase 0 de abertura,' e mais nada
      expect(pages.first.spotlight, isTrue);
      expect(pages.first.segs, hasLength(1));
      expect(pars[0].substring(pages.first.segs.single.start, pages.first.segs.single.end).trim(), 'Frase 0 de abertura,');
      expect(pages[1].segs.first.para, 0); // o resto do parágrafo segue
      // prancha: pintura + 1ª frase do parágrafo da cena
      final plate = pages.firstWhere((p) => p.plate != null);
      expect(plate.spotlight, isTrue);
      expect(pars[3].substring(plate.segs.single.start, plate.segs.single.end).trim(), 'Frase 3 de abertura,');
      expect(pages[pages.indexOf(plate) + 1].segs.first, isA<PageSeg>().having((s) => s.para, 'para', 3).having((s) => s.start, 'start', greaterThan(0)));
      int letters(List<BookPage> ps) => ps.fold(0, (a, p) => a + p.segs.fold(0, (b, s) => b + s.end - s.start));
      expect(letters(pages), greaterThan(pars.fold<int>(0, (a, t) => a + t.length) - pages.length * 2)); // nada some
      // sem pintura: começa direto no texto
      expect(paginate(0, ch, spec).first.spotlight, isFalse);
    });

    test('prancha vira uma página inteira antes do parágrafo, sem perder texto', () {
      final ch = BookChapter('I', [for (var i = 0; i < 6; i++) 'Parágrafo $i ${'palavra ' * 30}'.trim()]);
      const spec = PageSpec(size: Size(320, 400), body: TextStyle(fontSize: 14, height: 1.4), title: TextStyle(fontSize: 12), padding: EdgeInsets.all(10));
      final plain = paginate(0, ch, spec);
      final withPlate = paginate(0, ch, spec, plates: const [(3, 1000)]);
      final plates = withPlate.where((p) => p.plate != null).toList();
      expect(plates.length, 1);
      expect(plates.single.plate, 1000);
      expect(plates.single.segs, isEmpty);
      final i = withPlate.indexOf(plates.single);
      expect(withPlate[i + 1].segs.first.para, 3); // o texto segue do parágrafo da cena
      expect(withPlate[i - 1].segs.last.para, 2);
      int letters(List<BookPage> ps) => ps.fold(0, (a, p) => a + p.segs.fold(0, (b, s) => b + s.end - s.start));
      expect(letters(withPlate), letters(plain));
      expect(paginate(0, ch, spec, plates: const [(0, 1000)]).any((p) => p.plate != null), isFalse); // nunca antes do 1º
    });
  });
}

class _NoNet extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => throw UnimplementedError();
}
