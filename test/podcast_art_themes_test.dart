import 'package:flutter_test/flutter_test.dart';
import 'package:player_nostalgico/gif_providers.dart';
import 'package:player_nostalgico/models.dart';
import 'package:player_nostalgico/podcast_themes.dart';
import 'package:player_nostalgico/program_art.dart';

Track _ep(int i, String title) =>
    Track(id: i, path: '/m/Podcasts/Café/ep$i.m4a', title: title, artist: 'Café', album: 'Café', durationMs: 3600000, addedAt: i, modifiedAt: 0);

void main() {
  group('ícone do canal', () {
    test('acha o ícone do dono do vídeo na página (ignora a lista de nomes no começo)', () {
      const html =
          'x "videoOwnerRenderer","metadataBadgeRenderer" y ... '
          '"videoOwnerRenderer":{"thumbnail":{"thumbnails":[{"url":"https://yt3.ggpht.com/abc-DEF=s48-c-k-c0x00ffffff-no-rj","width":48}]}} '
          '"externalChannelId":"UC4QobU6STFB0P71PMvOGN5A"';
      expect(ProgramArtService.avatarFromWatchPage(html), 'https://yt3.ggpht.com/abc-DEF=s48-c-k-c0x00ffffff-no-rj');
      expect(ProgramArtService.channelIdFromPage(html), 'UC4QobU6STFB0P71PMvOGN5A');
      expect(ProgramArtService.avatarFromWatchPage('<html>nada</html>'), isNull);
    });

    test('página do canal: og:image', () {
      const html = '<meta property="og:image" content="https://yt3.googleusercontent.com/xyz=s900-c-k-c0x00ffffff-no-rj">';
      expect(ProgramArtService.avatarFromChannelPage(html), 'https://yt3.googleusercontent.com/xyz=s900-c-k-c0x00ffffff-no-rj');
      expect(ProgramArtService.avatarFromChannelPage('<meta property="og:image" content="https://i.ytimg.com/vi/a/hq.jpg">'), isNull);
    });

    test('miniatura do vídeo fica ao lado do episódio', () {
      expect(ProgramArtService.episodeThumbPath('/m/Podcasts/JRE/Ep 1.m4a'), '/m/Podcasts/JRE/Ep 1.jpg');
    });

    test('pede a versão pequena (176 px)', () {
      expect(ProgramArtService.smallAvatar('https://yt3.ggpht.com/abc=s900-c-k-no'), 'https://yt3.ggpht.com/abc=s176-c-k-no');
      expect(ProgramArtService.smallAvatar('https://yt3.ggpht.com/abc'), 'https://yt3.ggpht.com/abc=s176');
    });
  });

  group('temas do programa', () {
    final eps = [
      _ep(1, 'O livro de Rute, parte 1'),
      _ep(2, 'O livro de Rute, parte 2'),
      _ep(3, 'Salmos para dias difíceis'),
      _ep(4, 'Salmo 23 explicado'),
      _ep(5, 'Especial de Natal'),
    ];

    test('lê a resposta da IA: ignora tema com 1 episódio, número inválido e episódio repetido', () {
      final themes = PodcastThemesService.parseThemes({
        'temas': [
          {
            'nome': 'Livro de Rute',
            'gif': 'wheat field',
            'eps': [1, 2],
          },
          {
            'nome': 'Salmos',
            'gif': 'harp music',
            'eps': [3, 4, 2, 99],
          },
          {
            'nome': 'Natal',
            'gif': 'christmas tree',
            'eps': [5],
          },
          {
            'nome': 'Outros',
            'eps': [5, 1],
          },
        ],
      }, eps);
      expect(themes.map((t) => t.name), ['Livro de Rute', 'Salmos']);
      expect(themes[1].files, ['ep3.m4a', 'ep4.m4a']);
      expect(themes[0].gifQuery, 'wheat field');
    });

    test('aceita os números dos episódios vindo como texto', () {
      final themes = PodcastThemesService.parseThemes({
        'temas': [
          {'nome': 'Rute', 'gif': 'wheat', 'eps': ['1', ' 2 ']},
        ],
      }, eps);
      expect(themes.single.files, ['ep1.m4a', 'ep2.m4a']);
    });

    test('mantém o GIF de um tema que já existia', () {
      final themes = PodcastThemesService.parseThemes(
        {
          'temas': [
            {
              'nome': 'Salmos',
              'gif': 'x',
              'eps': [3, 4],
            },
          ],
        },
        eps,
        previous: const [EpisodeTheme(name: 'salmos', gifQuery: 'y', files: [], gif: 'gif_1.webp')],
      );
      expect(themes.single.gif, 'gif_1.webp');
    });

    test('mudança feita pelo usuário vale depois de reagrupar', () {
      const t = ProgramThemes('s', [
        EpisodeTheme(name: 'Rute', gifQuery: '', files: ['ep1.m4a', 'ep2.m4a']),
        EpisodeTheme(name: 'Salmos', gifQuery: '', files: ['ep3.m4a']),
      ]);
      final moved = t.withManual({'ep2.m4a': 'Salmos', 'ep1.m4a': '', 'ep9.m4a': 'Sumiu'});
      expect(moved.themes[0].files, isEmpty);
      expect(moved.themes[1].files, ['ep3.m4a', 'ep2.m4a']);
      final back = ProgramThemes.fromJson(moved.toJson());
      expect(back.manual['ep2.m4a'], 'Salmos');
      expect(back.themes[1].files, ['ep3.m4a', 'ep2.m4a']);
    });

    test('assinatura muda quando chega episódio novo', () {
      expect(PodcastThemesService.signatureOf(eps), PodcastThemesService.signatureOf(eps.reversed.toList()));
      expect(PodcastThemesService.signatureOf(eps), isNot(PodcastThemesService.signatureOf(eps.take(4).toList())));
    });

    test('pedido para a IA lista os episódios numerados', () {
      final prompt = PodcastThemesService.promptFor('Café', eps, (_) => null);
      expect(prompt, contains('1. O livro de Rute, parte 1'));
      expect(prompt, contains('5. Especial de Natal'));
    });
  });

  test('GIPHY: guarda a versão WebP leve para a miniatura', () {
    const body =
        '{"data":[{"id":"a1","title":"t","url":"u","images":{'
        '"fixed_width_small":{"url":"https://g/s.gif"},"downsized":{"url":"https://g/d.gif"},'
        '"fixed_width":{"url":"https://g/fw.gif","webp":"https://g/fw.webp"}}}]}';
    final g = GiphyProvider.parse(200, body).single;
    expect(g.tileUrl, 'https://g/fw.webp');
  });
}
