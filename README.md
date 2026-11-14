# Player Nostálgico

Player de música offline para Android, com visual inspirado no Windows Media Player do XP, no iPod e no Walkman.

## O que já funciona

- **Biblioteca**: escolhe uma pasta do celular, lê as músicas (mp3, flac, m4a, ogg, opus, wav) e as tags. Navega por artistas, álbuns, gêneros e pastas, e tem busca.
- **Buscar novas músicas** (na Biblioteca, que é a tela inicial): lê cada música da pasta, descobre o artista e o álbum (pelas tags; se faltar, pesquisa o título no [MusicBrainz](https://musicbrainz.org)) e move para `Pasta/Artista/Álbum/`. Antes de mover, mostra a lista para conferir e desmarcar. Dá para **desfazer** a última organização. Favoritas, playlists e histórico continuam valendo depois de mover.
- **Tocando agora**: a "capa" é uma sequência de GIFs que trocam a cada 8 s, com miniaturas dos próximos. Controles redondos prateados na barra azul, aleatório e repetir. Toca em segundo plano, com controles na notificação.
- **GIFs offline**: ficam na pasta `GIFs/` dentro da pasta de músicas. Uma subpasta com o nome do artista, álbum ou gênero (ex.: `GIFs/Hatsune Miku/`) faz os GIFs aparecerem nas músicas que combinam. GIFs soltos em `GIFs/` aparecem em qualquer música. Em "GIFs desta" dá para adicionar GIFs do celular e fixar na música.
- **GIFs automáticos**: quando uma música começa a tocar, o app procura GIFs em fontes de licença livre ([Openverse](https://openverse.org), [Wikimedia Commons](https://commons.wikimedia.org) e, para anime, [nekos.best](https://nekos.best), que só é usada música a música, nunca em massa, como pedem os termos dela) pelo título e artista (ex.: "Sonne Rammstein", depois "Rammstein", depois "Sonne", depois o gênero), baixa **no máximo 9 por música** e guarda em `GIFs/Artista/Título/` com um `creditos.txt`. Na Biblioteca, **Baixar GIFs para todas** faz isso de uma vez.
- **Palavras extras** (em "GIFs desta"): associações para a busca, ex.: "rock lee vs gaara" para Numb. Ficam em `GIFs/palavras.json`.
- **Buscar na web** (em "GIFs desta"): abre Google, Tenor, GIPHY ou Pinterest com a busca pronta; com o **Modo salvar** ligado, tocar num GIF guarda na música. É o caminho para GIFs de anime e filmes, que não existem nas fontes livres.
- **Nomes limpos**: "00 - 002 - 【Hatsune Miku】 World is Mine 【Legenda PT-BR】" vira artista "Hatsune Miku", título "World is Mine". O organizador também renomeia o arquivo para o título limpo.
- **Favoritas**, **Playlists** (criar, renomear, reordenar arrastando, remover deslizando) e **Para você** (mix, rádio da música atual e "Redescobrir", tudo calculado no aparelho).

## Como testar

### No celular (mais fácil)
1. Baixe o APK mais recente: https://github.com/mattospedroa-maker/player-nostalgico/releases/latest/download/player-nostalgico.apk (cada mudança gera uma versão nova em *Releases*). Abra o arquivo no celular. O Android vai pedir para permitir "instalar apps desconhecidos".
2. Na primeira abertura, toque em **Escolher pasta de músicas** e permita o **acesso a todos os arquivos** (necessário para ler e mover as músicas).

### No computador, durante o desenvolvimento
1. Instale o [Flutter](https://docs.flutter.dev/get-started/install) e o [Android Studio](https://developer.android.com/studio).
2. No Android Studio, crie um celular virtual em *Device Manager*.
3. Nesta pasta: `flutter pub get` e depois `flutter run`. Com o emulador aberto, o app abre nele; com o celular ligado por USB (depuração USB ativada), abre no celular. Salvar um arquivo atualiza o app na hora (*hot reload*).
4. Para colocar músicas no emulador, arraste os arquivos para a janela dele (vão para `Download/`).

### Testes automáticos
`flutter test` roda os testes do organizador (MusicBrainz simulado, mover e desfazer), da biblioteca, dos GIFs e da recomendação.

## Estrutura

| Arquivo | O que faz |
| --- | --- |
| `lib/organizer.dart` | Botão "Buscar novas músicas": identifica artista/álbum e move os arquivos |
| `lib/library_scanner.dart` | Varre a pasta e atualiza o banco |
| `lib/db.dart` | Banco SQLite: faixas, playlists, histórico, GIFs fixados |
| `lib/player_service.dart` | Fila e reprodução (just_audio), registra o histórico |
| `lib/gif_service.dart` | Acervo local de GIFs e combinação com as músicas |
| `lib/gif_fetcher.dart`, `lib/gif_providers.dart` | Busca e download automático de GIFs (Openverse, Wikimedia) |
| `lib/recommender.dart` | Recomendação offline |
| `lib/theme.dart` | Visual XP: barras de título, botões prateados, listas estilo iPod |
| `lib/screens/` | As telas |

## Próximos passos
- Receber GIFs pelo "Compartilhar" do Android (ex.: direto do Pinterest).
- Temas de moldura iPod e Walkman.
