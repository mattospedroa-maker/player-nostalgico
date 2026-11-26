# Nostalgic MPlayer (Player Nostálgico)

Player de música para Android com visual do Windows Media Player 9 do XP: janelas Luna azuis, botões redondos prateados, visor LCD e barra de status. Toca tudo off-line; a internet só serve para enfeitar (GIFs, capas, fotos, letras, gênero) e para baixar do YouTube.

Projeto pessoal, sem fim comercial.

## Instalar

- **Versão estável** (a que foi testada e não incomoda): https://github.com/mattospedroa-maker/player-nostalgico/releases/download/estavel/player-nostalgico.apk
- **Última versão** (cada mudança gera uma nova, `v2.0.N`): https://github.com/mattospedroa-maker/player-nostalgico/releases/latest/download/player-nostalgico.apk

Abra o APK no celular e permita "instalar apps desconhecidos". Na primeira abertura, escolha a pasta de músicas e permita o **acesso a todos os arquivos** (para ler, organizar e mover as músicas).

Para marcar outra versão como estável: *Actions → Marcar versão estável → Run workflow* com o número da versão (ex.: `2.0.161`). A release "estavel" passa a apontar para ela sem mexer na última.

## O que o app faz

### Biblioteca
- Lê mp3, flac, m4a, ogg, opus e wav da pasta escolhida. Navega por artistas, álbuns, gêneros, estilos e pastas, com busca geral e busca dentro de qualquer lista (lupa na barra azul).
- **Buscar novas músicas**: limpa nomes ("00 - 002 - 【Hatsune Miku】 World is Mine" vira "World is Mine", de Hatsune Miku), descobre artista e álbum pelas tags ou pelo [MusicBrainz](https://musicbrainz.org) e move para `Fonte/Artista/Álbum/`. Mostra a lista antes, e dá para desfazer.
- Parcerias ("A feat. B") ficam no artista principal. Músicas repetidas: fica a original e só uma versão de cada tipo (uma ao vivo, um remix, uma acústica).
- **Estilo e clima automáticos**: estilos vindos das tags do Last.fm e do gênero, réguas de energia e humor, e um clima (triste, calmo, épico...) somando pistas. Tudo pode ser corrigido à mão na aba *Estilo* de Editar, e o app aprende com as suas playlists.
- Favoritas, playlists (com cópia de segurança na pasta `Playlists/`), coleções inteligentes e sugestões no fim de cada playlist.

### Tocando agora
- A capa é um carrossel de GIFs, capa do álbum e fotos do artista. Ele para quando o app sai da tela, para não gastar bateria.
- **Depois desta, tocar:** *Da mesma vibe* ou *Do mesmo artista*. Cada música que o mix colocou mostra uma linha curta com o motivo ("↳ mesmo estilo (Shoegaze)"). Tocar na linha, ou segurar a música, abre a janela **Por que esta música?** com os pontos de cada parecença, o clima e o estilo.
- Fila (Lista de reprodução) com *Tocar a seguir* e *Adicionar à fila*, transição ajustável entre músicas (dois players se revezando), pular música que não abre e controles na notificação e na tela de bloqueio.

### GIFs
- Baixa até 9 GIFs por música quando ela toca, escolhidos pelo clima, pelo ritmo e pela letra. Mistura anime ([nekos.best](https://nekos.best)) com GIFs gerais (GIPHY, Openverse, Wikimedia). Um GIF usado por várias músicas é guardado uma vez só.
- Ficam em `GIFs/` dentro da pasta de músicas. Subpastas com o nome do artista, álbum ou gênero valem para as músicas que combinam. Em *GIFs desta* dá para escolher GIFs do celular ou buscar na web.

### Downloads e podcasts
- **Baixar do YouTube** (também pelo *Compartilhar* do Android, "Baixar MP3"): baixa o áudio em M4A sem converter, com capa, em segundo plano e com fila que continua depois.
- **Podcasts**: episódios agrupados por programa e por tema, imagem por programa, e resumo do episódio por IA (botão *Resumo*).

### Opções
- **Armazenamento**: pizza "deitada" estilo Propriedades do disco do XP com o espaço de GIFs, fotos e capas. Tem um teto (padrão 1 GB) e **Limpar agora**. A limpeza automática apaga GIFs que nenhuma música usa e, passando do teto, os GIFs automáticos das músicas ouvidas há mais tempo. Nunca apaga favoritas, a que está tocando ou GIFs escolhidos por você.
- **Internet**: *Trabalhar off-line*, *Só no Wi-Fi* e uma caixa para cada serviço (GIFs, fotos, capas, letras, gênero/artista/álbum, resumo por IA). O modo aparece na barra de status de cada tela, como a zona do Internet Explorer. O YouTube e o que você pede na hora sempre funcionam.
- **Reprodução**: tempo da transição entre músicas e outras preferências de tocar.

## Serviços on-line usados
MusicBrainz e Cover Art Archive (artista, álbum, capas), Last.fm (tags e gênero), Deezer (fotos de artista), LRCLIB (letras), nekos.best, GIPHY, Openverse e Wikimedia (GIFs), YouTube via yt-dlp (downloads) e Gemini/Mistral (resumo e temas de podcast). Todos podem ser desligados na aba Internet, menos o YouTube.

As chaves `LASTFM_KEY`, `GIPHY_KEY`, `GEMINI_KEY` e `MISTRAL_KEY` ficam nos *secrets* do GitHub e entram no APK na hora do build.

## Desenvolvimento

1. Instale o [Flutter](https://docs.flutter.dev/get-started/install) e o [Android Studio](https://developer.android.com/studio).
2. `flutter pub get` e depois `flutter run` (com emulador aberto ou celular ligado por USB com depuração ativada).
3. `flutter test` roda os testes; `flutter analyze` precisa sair limpo (o build do GitHub falha até com avisos).

Cada push na `main` gera um APK novo em *Releases* (`.github/workflows/apk.yml`).

### Onde fica cada coisa

| Arquivo | O que faz |
| --- | --- |
| `lib/app_state.dart` | Estado do app: biblioteca, buscas automáticas, limpeza |
| `lib/player_service.dart`, `lib/crossfade.dart` | Fila, mix automático e transição entre músicas |
| `lib/recommender.dart`, `lib/styles.dart`, `lib/mood.dart` | Parecença entre músicas, estilos, réguas e clima |
| `lib/organizer.dart`, `lib/library_scanner.dart` | Organizar e varrer a pasta de músicas |
| `lib/gif_fetcher.dart`, `lib/gif_providers.dart`, `lib/gif_service.dart` | Escolha, download e acervo de GIFs |
| `lib/storage_service.dart` | Espaço usado, teto e limpeza |
| `lib/net_policy.dart` | Modo off-line, Só Wi-Fi e serviços ligados |
| `lib/download_service.dart`, `lib/ytdlp.dart` | Download do YouTube em segundo plano |
| `lib/podcasts.dart`, `lib/podcast_info.dart` | Podcasts, temas e resumo |
| `lib/db.dart` | Banco SQLite: faixas, playlists, histórico, GIFs fixados |
| `lib/theme.dart`, `lib/xp_icons.dart`, `lib/widgets.dart` | Visual do XP e peças da interface |
| `lib/screens/` | As telas |

## Fontes
- `fonts/tahoma.ttf`, `fonts/tahomabd.ttf`: "Wine Tahoma" do projeto Wine (LGPL 2.1), parecida com a Tahoma do XP.
- `fonts/VT323-Regular.ttf`: VT323 (SIL Open Font License, ver `fonts/VT323-OFL.txt`), usada no visor LCD.
