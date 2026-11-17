import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../crossfade.dart';
import '../player_service.dart';
import '../theme.dart';
import '../xp_icons.dart';

/// Janela "Opções" no estilo do Windows Media Player. Por enquanto só a aba Reprodução
/// (transição suave); as outras configurações do app entram aqui como abas novas.
class OptionsScreen extends StatefulWidget {
  /// Só para testes; no app vem o PlayerService.
  final CrossfadeSettings? settings;
  const OptionsScreen({super.key, this.settings});

  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class _OptionsScreenState extends State<OptionsScreen> {
  late final CrossfadeSettings _ps = widget.settings ?? context.read<PlayerService>();
  late bool _on;
  late int _out;
  late int _in;

  @override
  void initState() {
    super.initState();
    _on = _ps.crossfade;
    _out = _ps.fadeOut.inSeconds;
    _in = _ps.fadeIn.inSeconds;
    _ps.addListener(_outside);
  }

  /// Algo mudou fora daqui (ex.: o botão de transição do player): só redesenha o "Aplicar".
  void _outside() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ps.removeListener(_outside);
    super.dispose();
  }

  bool get _changed => _on != _ps.crossfade || _out != _ps.fadeOut.inSeconds || _in != _ps.fadeIn.inSeconds;

  void _apply() {
    _ps.setCrossfadeTimes(Duration(seconds: _out), Duration(seconds: _in));
    _ps.setCrossfade(_on);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(
            children: [
              XpTitleBar(
                title: 'Opções',
                icon: XpIcons.gear,
                actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))],
              ),
              Expanded(
                child: ColoredBox(
                  color: Xp.beige,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      XpTabs(labels: const ['Reprodução'], current: 0, onTap: (_) {}),
                      Expanded(
                        child: XpTabPage(
                          child: ListView(padding: EdgeInsets.zero, children: [_fadeGroup(), _previewGroup()]),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton(
                              key: const Key('options-ok'),
                              onPressed: () {
                                _apply();
                                Navigator.pop(context);
                              },
                              child: const Text('OK'),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                            const SizedBox(width: 6),
                            OutlinedButton(key: const Key('options-apply'), onPressed: _changed ? _apply : null, child: const Text('Aplicar')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fadeGroup() => XpGroupBox(
    title: 'Transição suave',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          key: const Key('options-crossfade'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _on,
          onChanged: (v) => setState(() => _on = v ?? false),
          title: const Text('Ativar transição suave entre músicas', style: TextStyle(fontSize: 14)),
        ),
        _label('Final da música (vai sumindo): ', _out),
        XpSlider(
          key: const Key('options-out'),
          value: _out,
          min: fadeOutRange.$1,
          max: fadeOutRange.$2,
          enabled: _on,
          onChanged: (v) => setState(() => _out = v),
        ),
        const SizedBox(height: 6),
        _label('Começo da próxima (vai aparecendo): ', _in),
        XpSlider(key: const Key('options-in'), value: _in, min: fadeInRange.$1, max: fadeInRange.$2, enabled: _on, onChanged: (v) => setState(() => _in = v)),
        const SizedBox(height: 6),
        const Text(
          'Separado: a música que sai pode demorar mais para sumir do que a próxima para aparecer. '
          'As duas começam juntas; a transição só acontece quando a música chega ao fim sozinha.',
          style: TextStyle(fontSize: 12, color: Color(0xFF555555)),
        ),
      ],
    ),
  );

  Widget _label(String text, int s) => Opacity(
    opacity: _on ? 1 : .5,
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text),
          TextSpan(
            text: '$s s',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Xp.navy),
          ),
        ],
      ),
      style: const TextStyle(fontSize: 14),
    ),
  );

  Widget _previewGroup() => XpGroupBox(
    title: 'Prévia',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FadePreview(out: _out, inn: _in, on: _on),
        const SizedBox(height: 6),
        Text(
          _on ? 'As duas músicas tocam juntas por ${_out}s. A próxima chega ao volume cheio em ${_in}s.' : 'Desligada: uma música termina e a outra começa.',
          style: const TextStyle(fontSize: 12, color: Color(0xFF555555)),
        ),
      ],
    ),
  );
}

/// Controle deslizante do XP: trilho fundo, marquinhas embaixo e o "pegador" com a ponta para baixo.
/// Anda de 1 em 1 (sem meio-termo), tocando ou arrastando.
class XpSlider extends StatelessWidget {
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  const XpSlider({super.key, required this.value, required this.min, required this.max, required this.onChanged, this.enabled = true});

  static const _thumbW = 12.0;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : .5,
    child: LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth - _thumbW;
        void pick(double dx) {
          final v = (min + ((dx - _thumbW / 2) / w * (max - min)).round()).clamp(min, max);
          if (v != value) onChanged(v);
        }

        final x = (value - min) / (max - min) * w;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (d) => pick(d.localPosition.dx) : null,
          onHorizontalDragUpdate: enabled ? (d) => pick(d.localPosition.dx) : null,
          child: SizedBox(
            height: 44,
            child: Stack(
              children: [
                // trilho afundado
                Positioned(
                  left: _thumbW / 2,
                  right: _thumbW / 2,
                  top: 12,
                  child: Container(
                    height: 4,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF0F0EA),
                      border: Border(
                        top: BorderSide(color: Color(0xFF9A9A8C)),
                        left: BorderSide(color: Color(0xFF9A9A8C)),
                        bottom: BorderSide(color: Colors.white),
                        right: BorderSide(color: Colors.white),
                      ),
                    ),
                  ),
                ),
                // marquinhas (uma por segundo)
                Positioned(
                  left: _thumbW / 2,
                  right: _thumbW / 2,
                  top: 30,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [for (var i = min; i <= max; i++) Container(width: 1, height: (i - min) % 5 == 0 ? 7 : 4, color: const Color(0xFF777777))],
                  ),
                ),
                Positioned(
                  left: x,
                  top: 2,
                  child: CustomPaint(size: const Size(_thumbW, 24), painter: _ThumbPainter()),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _ThumbPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(0, 1)
      ..lineTo(1, 0)
      ..lineTo(s.width - 1, 0)
      ..lineTo(s.width, 1)
      ..lineTo(s.width, s.height - 6)
      ..lineTo(s.width / 2, s.height)
      ..lineTo(0, s.height - 6)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Color(0xFFE1E1D8)],
        ).createShader(Offset.zero & s),
    );
    // listra verde de baixo, como o pegador do XP
    canvas.drawLine(
      Offset(1, s.height - 7),
      Offset(s.width - 1, s.height - 7),
      Paint()
        ..color = const Color(0xFF21A121)
        ..strokeWidth = 2,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF1C5180)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter old) => false;
}

/// Visor azul com as duas faixas: a de cima é a música atual (sumindo no fim), a de baixo é a próxima
/// (aparecendo). A parte em que as duas se sobrepõem cresce com o controle "Final da música".
class FadePreview extends StatelessWidget {
  final int out;
  final int inn;
  final bool on;
  const FadePreview({super.key, required this.out, required this.inn, required this.on});

  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    decoration: BoxDecoration(
      color: Xp.navyDeep,
      border: Border.all(color: Xp.lcdDim, width: 2),
    ),
    child: LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth - 8;
        // escala fixa: 30 s de linha do tempo, a troca acontece no meio
        const span = 30.0;
        final mid = w * .62;
        final overlap = on ? out / span * w : 0.0;
        final start = mid - overlap;
        const style = TextStyle(
          fontFamily: 'Lcd',
          fontSize: 15,
          color: Colors.white,
          height: 1,
          shadows: [
            Shadow(color: Xp.navyDeep, blurRadius: 2),
            Shadow(color: Xp.navyDeep, offset: Offset(1, 1)),
          ],
        );
        return Stack(
          children: [
            Positioned(
              left: 4,
              top: 5,
              width: mid,
              height: 17,
              child: _bar('MÚSICA ATUAL', Xp.lcdDim, style, fadeAt: on ? (mid - overlap) / mid : 1, fadeOut: true),
            ),
            Positioned(
              left: 4 + start,
              top: 27,
              width: w - start,
              height: 17,
              child: _bar('PRÓXIMA', Xp.lcdText, style, fadeAt: on ? (inn / span * w / (w - start)).clamp(0.0, 1.0) : 0, fadeOut: false),
            ),
          ],
        );
      },
    ),
  );

  /// Faixa em blocos (pixelada): some aos poucos no fim ([fadeOut]) ou aparece aos poucos no começo.
  Widget _bar(String label, Color color, TextStyle style, {required double fadeAt, required bool fadeOut}) => LayoutBuilder(
    builder: (context, c) {
      const block = 6.0;
      final n = (c.maxWidth / block).floor();
      return Stack(
        children: [
          Row(
            children: [
              for (var i = 0; i < n; i++)
                Container(
                  width: block - 1,
                  margin: const EdgeInsets.only(right: 1),
                  color: color.withValues(alpha: _alpha(i / n, fadeAt, fadeOut)),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 3, top: 1),
            child: Text(label, style: style),
          ),
        ],
      );
    },
  );

  static double _alpha(double p, double fadeAt, bool fadeOut) {
    if (fadeOut) return p <= fadeAt ? 1 : (1 - (p - fadeAt) / (1 - fadeAt)).clamp(.12, 1.0);
    return fadeAt <= 0 || p >= fadeAt ? 1 : (p / fadeAt).clamp(.12, 1.0);
  }
}
