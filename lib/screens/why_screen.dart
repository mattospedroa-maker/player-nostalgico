import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../mood.dart';
import '../player_service.dart';
import '../recommender.dart';
import '../styles.dart';
import '../theme.dart';
import 'edit_track_screen.dart';

/// Abre a janela "Por que esta música?" para [track], com a fila e o mix de agora.
Future<void> showWhyWindow(BuildContext context, Track track) {
  final ps = context.read<PlayerService>();
  final app = context.read<AppState>();
  final t = app.byId(track.id) ?? track;
  return showDialog<void>(
    context: context,
    builder: (_) => WhyWindow(
      track: t,
      seed: ps.isFromMix(t) ? ps.mixSeed : null,
      userQueued: ps.isUserQueued(t),
      byArtist: ps.mixMode == MixMode.artist,
      library: app.tracks,
    ),
  );
}

/// Tudo o que fez [track] entrar no mix, em relação à música que guia o mix ([seed]).
/// Só lê o que já está no celular: não usa internet.
class WhyWindow extends StatelessWidget {
  final Track track;

  /// A música que guia o mix, quando [track] veio do mix; senão null (você escolheu).
  final Track? seed;
  final bool userQueued;

  /// Mix "Do mesmo artista" (guia = a que está tocando) ou "Da mesma vibe" (guia = início do mix).
  final bool byArtist;
  final List<Track> library;
  const WhyWindow({super.key, required this.track, this.seed, this.userQueued = false, this.byArtist = false, this.library = const []});

  /// Posição de [t] entre as músicas mais parecidas com [seed] (1 = a mais parecida).
  static int rankOf(Track seed, Track t, List<Track> library, double score) {
    var better = 0;
    for (final o in library) {
      if (o.id == seed.id || o.id == t.id) continue;
      if (Recommender.affinity(seed, o) > score) better++;
    }
    return better + 1;
  }

  static String _pts(double v) {
    final s = v.toStringAsFixed(1).replaceAll('.', ',');
    return s.endsWith(',0') ? s.substring(0, s.length - 2) : s;
  }

  @override
  Widget build(BuildContext context) {
    final t = track, seed = this.seed;
    final sections = <Widget>[];

    if (seed != null && seed.id != t.id) {
      final e = Recommender.explain(seed, t);
      final top = e.parts.isEmpty ? 1.0 : e.parts.first.$2;
      final rank = rankOf(seed, t, library, e.score);
      final guide = byArtist ? 'a que está tocando' : 'início do mix';
      sections.add(
        XpGroupBox(
          key: const Key('why-points'),
          title: 'Parecida com "${seed.title}" ($guide)',
          background: Xp.beige,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (e.parts.isEmpty)
                const Text('Nada em comum: entrou para variar um pouco, porque as parecidas já tocaram.', style: TextStyle(fontSize: 13))
              else
                for (final (why, v) in e.parts) _bar(why, v / (top < 3 ? 3 : top), '+${_pts(v)}'),
              const SizedBox(height: 6),
              Text('Total ${_pts(e.score)} pontos: a $rankª mais parecida da biblioteca.', style: const TextStyle(fontSize: 12, color: Xp.blueMuted)),
            ],
          ),
        ),
      );
    } else {
      sections.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            userQueued
                ? 'Você pôs esta música na fila ("Tocar a seguir" ou "Adicionar à fila").'
                : 'Você escolheu esta música (álbum, playlist ou busca): ela não veio do mix.',
            style: const TextStyle(fontSize: 13.5),
          ),
        ),
      );
    }

    // clima
    final mood = t.effectiveMood;
    final guess = t.chosenMood == null ? MoodClues.forTrack(t) : null;
    sections.add(
      XpGroupBox(
        title: mood == null ? 'Clima: neutro' : 'Clima: ${mood.emoji} ${mood.label}',
        background: Xp.beige,
        child: Text(
          t.chosenMood != null
              ? 'Escolhido por você.'
              : (guess!.reasons.isEmpty ? 'Sem pistas fortes: fica neutro em vez de chutar.' : 'Pistas: ${guess.reasons.join(' · ')}'),
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );

    // estilos e réguas
    final styles = Styles.of(t);
    final vibe = Styles.hasVibe(t) ? Styles.vibeOf(t) : null;
    sections.add(
      XpGroupBox(
        title: 'Estilo',
        background: Xp.beige,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (styles.isEmpty)
              Text(t.genre.isEmpty ? 'Sem estilo nem gênero ainda.' : 'Gênero: ${t.genre}', style: const TextStyle(fontSize: 13))
            else
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final s in styles)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDCE7FB),
                        border: Border.all(color: const Color(0xFF8DB2F3)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(s, style: const TextStyle(fontSize: 12.5, color: Xp.navy)),
                    ),
                ],
              ),
            if (vibe != null) ...[
              const SizedBox(height: 8),
              _bar('Energia', vibe.energy / 100, '${vibe.energy}'),
              _bar('Humor', vibe.humor / 100, '${vibe.humor}'),
              if (vibe.manual) const Text('Réguas arrastadas por você.', style: TextStyle(fontSize: 11, color: Xp.blueMuted)),
            ],
          ],
        ),
      ),
    );

    return XpAlertDialog(
      title: const Text('Por que esta música?'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            t.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy),
          ),
          Text(
            t.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Xp.blueMuted),
          ),
          ...sections,
        ],
      ),
      actions: [
        XpButton(
          key: const Key('why-fix'),
          label: 'Corrigir estilo…',
          onTap: () {
            final nav = Navigator.of(context);
            nav.pop();
            nav.push(MaterialPageRoute<void>(builder: (_) => EditTrackScreen(track: t, initialTab: 1)));
          },
        ),
        XpButton(label: 'OK', primary: true, onTap: () => Navigator.of(context).pop()),
      ],
    );
  }

  static Widget _bar(String label, double frac, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(
          flex: 5,
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 4,
          child: Container(
            height: 10,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFF7F9DB9)),
            ),
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: frac.clamp(0.0, 1.0),
              child: Container(
                decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF3B8CF5), Color(0xFF1C5FD8)])),
              ),
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, color: Xp.navy),
          ),
        ),
      ],
    ),
  );
}

/// Linha curta "↳ motivo" debaixo de uma música do mix. Tocar abre a janela "Por que esta música?".
class WhyLine extends StatelessWidget {
  final String reason;
  final VoidCallback? onTap;

  /// Em cima do azul da música que está tocando.
  final bool light;
  const WhyLine(this.reason, {super.key, this.onTap, this.light = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Text(
      '↳ $reason',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 10.5, fontStyle: FontStyle.italic, color: light ? const Color(0xFFFFE9A8) : const Color(0xFF8A7A3A)),
    ),
  );
}
