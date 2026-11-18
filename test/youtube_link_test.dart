import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/download_service.dart';

void main() {
  test('reconhece vídeo, playlist ou os dois pelo link', () {
    LinkKind k(String s) => DownloadService.linkKind(s);
    expect(k('https://www.youtube.com/watch?v=8xg3vE8Ie_E'), LinkKind.video);
    expect(k('youtu.be/8xg3vE8Ie_E'), LinkKind.video);
    expect(k('https://youtube.com/shorts/abc123'), LinkKind.video);
    expect(k('https://m.youtube.com/watch?v=abc&t=30s'), LinkKind.video);
    expect(k('https://www.youtube.com/playlist?list=PLx0sYbCqOb8Q'), LinkKind.playlist);
    expect(k('https://music.youtube.com/playlist?list=OLAK5uy_abc'), LinkKind.playlist);
    expect(k('https://www.youtube.com/watch?v=abc&list=PLx0sYbCqOb8Q&index=3'), LinkKind.both);
    expect(k('https://youtu.be/abc?list=PLx0sYbCqOb8Q'), LinkKind.both);
    // Mix automático do YouTube não tem fim: baixa só o vídeo
    expect(k('https://www.youtube.com/watch?v=abc&list=RDabc&start_radio=1'), LinkKind.video);
    expect(k('Olha essa: https://youtu.be/abc?si=xyz muito boa'), LinkKind.video);
    expect(k(''), LinkKind.unknown);
    // como o app do YouTube manda pelo "Compartilhar"
    expect(k('https://music.youtube.com/playlist?list=OLAK5uy_kXyZ&si=AbC123'), LinkKind.playlist);
    expect(k('https://music.youtube.com/watch?v=abc123&si=AbC123'), LinkKind.video);
    expect(k('https://music.youtube.com/browse/MPREb_AbCdEf'), LinkKind.playlist);
    expect(k('https://youtube.com/playlist?list=PLx0sYbCqOb8Q&si=AbC123'), LinkKind.playlist);
    expect(k('https://youtu.be/8xg3vE8Ie_E?si=AbC123'), LinkKind.video);
    expect(k('Assista "Numb" no YouTube\nhttps://youtu.be/kXYiU_JCYtU?si=x'), LinkKind.video);
  });
}
