# Player Nostálgico

Player de música offline para Android, com visual inspirado no Windows Media Player do XP, no iPod e no Walkman.

## O que já funciona (fase 1)

- **Biblioteca**: escolhe uma pasta do celular, lê as músicas (mp3, flac, m4a, ogg, opus, wav) e as tags. Navega por artistas, álbuns, gêneros e pastas, e tem busca.
- **Buscar novas músicas** (na Biblioteca, que é a tela inicial): lê cada música da pasta, descobre o artista e o álbum (pelas tags; se faltar, pesquisa o título no [MusicBrainz](https://musicbrainz.org)) e move para `Pasta/Artista/Álbum/`. Antes de mover, mostra a lista para conferir e desmarcar. Dá para **desfazer** a última organização. Favoritas, playlists e histórico continuam valendo depois de mover.
- **Tocando agora**: a "capa" é uma sequência de GIFs que trocam a cada 8 s, com miniaturas dos próximos. Controles redondos prateados na barra azul, aleatório e repetir. Toca em segundo plano, com controles na notificação.
- **GIFs offline**: ficam na pasta `GIFs/` dentro da pasta de músicas. Uma subpasta com o nome do artista, álbum ou gênero (ex.: `GIFs/Hatsune Miku/`) faz os GIFs aparecerem nas músicas que combinam. GIFs soltos em `GIFs/` aparecem em qualquer música. Em "GIFs desta" dá para adicionar GIFs do celular e fixar na música.
- **Favoritas**, **Playlists** (criar, renomear, reordenar arrastando, remover deslizando) e **Para você** (mix, rádio da música atual e "Redescobrir", tudo calculado no aparelho).

## Como testar

### No celular (mais fácil)
1. Gere o APK: com o Flutter instalado, rode `flutter build apk` nesta pasta. O arquivo sai em `build/app/outputs/flutter-apk/app-release.apk`. Copie esse arquivo para o celular e abra. O Android vai pedir para permitir "instalar apps desconhecidos".
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
| `lib/recommender.dart` | Recomendação offline |
| `lib/theme.dart` | Visual XP: barras de título, botões prateados, listas estilo iPod |
| `lib/screens/` | As telas |

## Próximos passos
- Receber GIFs pelo "Compartilhar" do Android (ex.: direto do Pinterest).
- Temas de moldura iPod e Walkman.
- Busca automática de GIFs, se alguma fonte permitir guardar os arquivos.
