import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player_nostalgico/list_search.dart';
import 'package:player_nostalgico/models.dart';

Track _t(String title, {String artist = 'Linkin Park', String album = 'Meteora'}) =>
    Track(path: '/m/$title.mp3', title: title, artist: artist, album: album, addedAt: 0, modifiedAt: 0);

/// Tela mínima com a lupa, para testar o campo e o teclado.
class _Harness extends StatefulWidget {
  final List<Track> tracks;
  const _Harness(this.tracks);
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with InListSearch {
  @override
  Widget build(BuildContext context) {
    final shown = searching ? InListIndex(widget.tracks).filter(widget.tracks, searchQuery) : widget.tracks;
    return Column(children: [
      searchButton(),
      searchBox('Pesquisar'),
      Expanded(
        child: searching && shown.isEmpty
            ? noMatches()
            : ListView(children: [for (final t in shown) Text(t.title, key: ValueKey(t.path))]),
      ),
    ]);
  }
}

void main() {
  final album = [_t('Foreword'), _t("Don't Stay"), _t('Somewhere I Belong'), _t('Numb'), _t('Breaking the Habit'), _t('Numb / Encore', album: 'Collision Course')];

  test('filtra na ordem da lista (não por relevância)', () {
    final idx = InListIndex(album);
    expect(idx.filter(album, 'numb').map((t) => t.title), ['Numb', 'Numb / Encore']);
    expect(idx.filter(album, '').length, album.length);
    // pelo álbum também
    expect(idx.filter(album, 'collision').map((t) => t.title), ['Numb / Encore']);
  });

  test('aceita acento, maiúscula e erro de digitação', () {
    final l = [_t('Coração Valente', artist: 'Ivete'), _t('Outra')];
    final idx = InListIndex(l);
    expect(idx.filter(l, 'CORACAO').single.title, 'Coração Valente');
    expect(idx.filter(l, 'valnete').single.title, 'Coração Valente');
  });

  test('textMatches para nomes de álbum/artista/playlist', () {
    expect(textMatches('hybr', ['Hybrid Theory', 'Linkin Park']), isTrue);
    expect(textMatches('linkin hyb', ['Hybrid Theory', 'Linkin Park']), isTrue);
    expect(textMatches('meteora', ['Hybrid Theory', 'Linkin Park']), isFalse);
    expect(textMatches('acao', ['Ação!']), isTrue);
    expect(textMatches('', ['qualquer']), isTrue);
  });

  test('marca o trecho certo, mesmo com acento', () {
    expect(matchRanges('Numb / Encore', 'numb'), [(0, 4)]);
    expect(matchRanges('Coração', 'cora'), [(0, 4)]);
    expect(matchRanges('Coração', 'acao'), [(3, 7)]);
    // letra solta só marca começo de palavra
    expect(matchRanges('Banana Azul', 'a'), [(7, 8)]);
    expect(matchRanges('qualquer', 'xyz'), isEmpty);
  });

  testWidgets('lupa abre o campo; digitar e apagar tudo não fecha o teclado', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _Harness(album))));
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.widget.focusNode.hasFocus, isTrue, reason: 'teclado abre ao tocar na lupa');

    await tester.enterText(field, 'n');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(field, 'numb');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Numb'), findsOneWidget);
    expect(find.text('Foreword'), findsNothing);

    await tester.enterText(field, 'zzzz');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Nada encontrado'), findsOneWidget);

    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Foreword'), findsOneWidget);
    // mesmo campo, ainda com foco
    expect(identical(tester.state<EditableTextState>(find.byType(EditableText)), editable), isTrue);
    expect(editable.widget.focusNode.hasFocus, isTrue);

    // fechar pela lupa limpa e mostra tudo
    await tester.enterText(field, 'numb');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Foreword'), findsOneWidget);
  });
}
