import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:player_nostalgico/db.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/screens/options_screen.dart';
import 'package:player_nostalgico/storage_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late AppDb db;
  late Directory tmp;
  late String root;
  late StorageService storage;

  setUp(() async {
    db = await AppDb.open(inMemoryDatabasePath, factory: databaseFactoryFfi);
    tmp = await Directory.systemTemp.createTemp('espaco');
    root = p.join(tmp.path, 'Musicas', 'GIFs');
    storage = StorageService(db: db, gifRoot: () => root, dataDir: p.join(tmp.path, 'dados'));
  });

  tearDown(() async {
    await db.db.close();
    await tmp.delete(recursive: true);
  });

  /// Grava um GIF de [kb] KB; com [hash], nome automático (12 letras hex).
  String gif(String folder, String name, int kb) {
    final f = File(p.join(root, folder, name))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(kb * 1024, 1));
    return f.path;
  }

  Future<Track> track(String name, {bool fav = false}) async {
    final id = await db.upsertTrack(Track(path: p.join(tmp.path, '$name.mp3'), title: name, artist: 'A', album: 'B', addedAt: 0, modifiedAt: 0));
    if (fav) await db.setFavorite(id, true);
    return (await db.allTracks()).firstWhere((t) => t.id == id);
  }

  test('mede GIFs em uso, órfãos, fotos e cache separados', () async {
    final t = await track('um');
    await db.pinGif(t.id!, gif('A/um', 'aaaaaaaaaaaa.gif', 10));
    gif('A/um', 'bbbbbbbbbbbb.gif', 4); // ninguém usa
    gif('Miku', 'meu gif.gif', 2); // do usuário, solto: nunca é órfão
    File(p.join(storage.cacheDir, 'x.png'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(3 * 1024, 1));
    final r = await storage.measure();
    expect(r.gifs, 12 * 1024);
    expect(r.orphans, 4 * 1024);
    expect(r.cache, 3 * 1024);
    expect(r.cleanable, 7 * 1024);
  });

  test('limpar sem teto: apaga só órfãos automáticos e o cache', () async {
    final t = await track('um');
    final used = gif('A/um', 'aaaaaaaaaaaa.gif', 10);
    await db.pinGif(t.id!, used);
    final orphan = gif('A/um', 'bbbbbbbbbbbb.gif', 4);
    final mine = gif('Miku', 'meu gif.gif', 2);
    File(p.join(storage.cacheDir, 'x.png'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final r = await storage.clean(capBytes: 0, tracks: await db.allTracks(), lastPlayed: const {});
    expect(r.deletedGifs, 1);
    expect(File(orphan).existsSync(), isFalse);
    expect(File(used).existsSync(), isTrue);
    expect(File(mine).existsSync(), isTrue);
    expect(Directory(storage.cacheDir).existsSync(), isFalse);
  });

  test('teto: apara primeiro as músicas ouvidas há mais tempo; favorita, tocando e escolhidos ficam', () async {
    final velha = await track('velha');
    final nova = await track('nova');
    final fav = await track('fav', fav: true);
    final tocando = await track('tocando');
    final g1 = gif('A/velha', '111111111111.gif', 100);
    final mine = gif('A/velha', 'escolhido.gif', 100);
    final g2 = gif('A/nova', '222222222222.gif', 100);
    final g3 = gif('A/fav', '333333333333.gif', 100);
    final g4 = gif('A/tocando', '444444444444.gif', 100);
    await db.pinGif(velha.id!, g1);
    await db.pinGif(velha.id!, mine);
    await db.pinGif(nova.id!, g2);
    await db.pinGif(fav.id!, g3);
    await db.pinGif(tocando.id!, g4);
    // 500 KB no total, teto de 420 KB: basta tirar o automático da "velha"
    final r = await storage.clean(
      capBytes: 420 * 1024,
      tracks: await db.allTracks(),
      lastPlayed: {velha.id!: 10, nova.id!: 20, fav.id!: 1, tocando.id!: 0},
      protect: {tocando.id!},
    );
    expect(r.trimmedTracks, 1);
    expect(File(g1).existsSync(), isFalse);
    expect(await db.pinnedGifs(velha.id!), [mine]);
    for (final f in [mine, g2, g3, g4]) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
  });

  test('teto: GIF que outra música também usa só sai do celular quando ninguém mais usa', () async {
    final a = await track('a');
    final b = await track('b');
    final shared = gif('A/a', '555555555555.gif', 300);
    await db.pinGif(a.id!, shared);
    await db.pinGif(b.id!, shared);
    final r = await storage.clean(capBytes: 100 * 1024, tracks: await db.allTracks(), lastPlayed: {a.id!: 1, b.id!: 2});
    expect(r.trimmedTracks, 2);
    expect(File(shared).existsSync(), isFalse);
  });

  test('nomes do teto e tamanhos', () {
    expect(capLabel(500), '500 MB');
    expect(capLabel(1024), '1 GB');
    expect(capLabel(0), 'Sem limite');
    expect(formatBytes(742 * 1024 * 1024), '742 MB');
    expect(formatBytes(1536 * 1024 * 1024), '1,5 GB');
  });

  testWidgets('aba Armazenamento: pizza com usado e livre, troca o teto e limpa', (t) async {
    t.view.physicalSize = const Size(400, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const mb = 1024 * 1024;
    var report = const StorageReport(gifs: 681 * mb, photos: 84 * mb, covers: 52 * mb, orphans: 61 * mb, cache: 38 * mb);
    int? picked;
    var cleaned = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, set) => StorageTab(
            cap: picked,
            savedCap: 1024,
            onCap: (v) => set(() => picked = v),
            measure: () async => report,
            clean: () async {
              cleaned++;
              report = const StorageReport(gifs: 681 * mb, photos: 84 * mb, covers: 52 * mb);
              return const CleanResult(99 * mb, 12, 0);
            },
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('storage-pie')), findsOneWidget);
    expect(find.text('826 MB'), findsOneWidget); // usado: GIFs + órfãos + fotos
    expect(find.text('198 MB'), findsOneWidget); // livre no teto de 1 GB
    expect(find.text('61 MB'), findsOneWidget);
    expect(find.text('38 MB'), findsOneWidget);
    await t.tap(find.byKey(const Key('options-cap')));
    await t.pumpAndSettle();
    await t.tap(find.text('2 GB').last);
    await t.pumpAndSettle();
    expect(picked, 2048);
    await t.tap(find.byKey(const Key('options-clean')));
    await t.pumpAndSettle();
    expect(cleaned, 1);
    expect(find.text('99 MB liberados.'), findsOneWidget);
    expect(find.text('0 B'), findsNWidgets(2)); // órfãos e cache zerados
  });
}
