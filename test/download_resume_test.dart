import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/download_service.dart';
import 'package:player_nostalgico/youtube_names.dart';

void main() {
  test('a fila guardada volta igual quando o app abre de novo', () {
    final e = YtEntry(
      id: 'kXYiU_JCYtU',
      url: 'https://www.youtube.com/watch?v=kXYiU_JCYtU',
      originalTitle: 'Linkin Park - Numb (Official Video)',
      names: const YtNames(artist: 'Linkin Park', title: 'Numb', album: 'Meteora'),
      thumbnail: 'https://i.ytimg.com/vi/kXYiU_JCYtU/hq.jpg',
      durationSec: 187,
      channel: 'Linkin Park',
    )..podcast = false;
    // passa pelo texto, como fica guardado no celular
    final j = jsonDecode(jsonEncode(DownloadService.pendingToJson(e, 'Rock 2000'))) as Map<String, dynamic>;
    expect(j['playlist'], 'Rock 2000');
    final back = DownloadService.pendingFromJson(j);
    expect(back.id, e.id);
    expect(back.url, e.url);
    expect(back.originalTitle, e.originalTitle);
    expect(back.names.artist, 'Linkin Park');
    expect(back.names.title, 'Numb');
    expect(back.names.album, 'Meteora');
    expect(back.thumbnail, e.thumbnail);
    expect(back.durationSec, 187);
    expect(back.channel, 'Linkin Park');
    expect(back.podcast, isFalse);
    expect(back.edited, isTrue, reason: 'os nomes já tinham sido decididos; a busca de álbum não troca');
  });

  test('episódio de podcast continua como podcast e sem campos opcionais', () {
    final e = YtEntry(
      id: 'abc',
      url: 'https://youtu.be/abc',
      originalTitle: 'Episódio 12',
      names: const YtNames(artist: 'Programa', title: 'Episódio 12', album: 'Programa'),
    )..podcast = true;
    final j = DownloadService.pendingToJson(e, null);
    expect(j.containsKey('playlist'), isFalse);
    expect(j.containsKey('thumb'), isFalse);
    final back = DownloadService.pendingFromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
    expect(back.podcast, isTrue);
    expect(back.thumbnail, isNull);
    expect(back.durationSec, isNull);
  });
}
