import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

/// Animação da janela "Copiando…" do XP, em pixel art e aos passinhos (sem movimento liso):
/// três notinhas saem do globo, que gira, e caem na pasta aberta, que fica de perfil na diagonal.
class CopyAnimation extends StatefulWidget {
  final bool running;
  final double height;

  /// Tamanho de cada "pixel" na tela e quadros por segundo.
  final double pixel;
  final int fps;
  const CopyAnimation({super.key, this.running = true, this.height = 108, this.pixel = 3, this.fps = 8});

  @override
  State<CopyAnimation> createState() => _CopyAnimationState();
}

class _CopyAnimationState extends State<CopyAnimation> {
  Timer? _timer;
  int _frame = 0;

  int get _cycle => widget.fps * 3; // um ciclo de 3 segundos (cada nota leva 1 s)

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(CopyAnimation old) {
    super.didUpdateWidget(old);
    if (old.running != widget.running || old.fps != widget.fps) _sync();
  }

  void _sync() {
    _timer?.cancel();
    _timer = widget.running
        ? Timer.periodic(Duration(milliseconds: 1000 ~/ widget.fps), (_) => setState(() => _frame = (_frame + 1) % _cycle))
        : null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(painter: _CopyPainter(_frame / _cycle, widget.pixel, widget.fps)),
      );
}

const _k = Color(0xFF0A246A), _b = Color(0xFF3B8CF5), _l = Color(0xFF9CC8FF), _g = Color(0xFF49A83C), _gd = Color(0xFF2A6A20);
const _y = Color(0xFFE8B830), _f = Color(0xFFFFD96A), _fl = Color(0xFFFFF2B0), _o = Color(0xFF8A6410), _n = Color(0xFF1D3C78);
const _paperLine = Color(0xFFB8C4D8), _paperEdge = Color(0xFF888888);

const _note = [
  '...nnnnnnn',
  '...nnnnnnn',
  '...n.....n',
  '...n.....n',
  '...n.....n',
  '...n.....n',
  '.bbn...bbn',
  'bbbn..bbbn',
  'bbbb..bbbb',
  '.bb....bb.',
];

// mapa dos continentes (dá a volta: 24 colunas)
const _land = [
  '...gggg.......ggg.......',
  '..gggggg....ggggg.......',
  '..ggggggg...gggggg....g.',
  '...gggggg....gggg....ggg',
  '....ggggg.....gg....gggg',
  '.....gggg..........ggggg',
  '......ggg...gg.....gggg.',
  '.......g...gggg.....gg..',
  '...........ggggg........',
  '............ggg.....gg..',
  '....g...............ggg.',
  '...ggg...............g..',
];

class _CopyPainter extends CustomPainter {
  final double t, px;
  final int fps;
  _CopyPainter(this.t, this.px, this.fps);

  late Canvas _c;
  final _p = Paint()..isAntiAlias = false;

  void _dot(int x, int y, Color c) {
    _p.color = c;
    _c.drawRect(Rect.fromLTWH(x * px, y * px, px, px), _p);
  }

  void _sprite(List<String> rows, int x, int y) {
    for (var j = 0; j < rows.length; j++) {
      for (var i = 0; i < rows[j].length; i++) {
        final ch = rows[j][i];
        if (ch != '.') _dot(x + i, y + j, ch == 'n' ? _n : _b);
      }
    }
  }

  void _globe(int x, int y, int s, int shift) {
    final r = s / 2 - .5, cx = x + s / 2 - .5, cy = y + s / 2 - .5;
    for (var j = 0; j < s; j++) {
      for (var i = 0; i < s; i++) {
        final dx = x + i - cx, dy = y + j - cy, d = sqrt(dx * dx + dy * dy);
        if (d > r + .5) continue;
        Color col;
        if (d > r - .7) {
          col = _k;
        } else {
          final rr = sqrt(max(r * r - dy * dy, 1.0));
          final u = (asin((dx / rr).clamp(-1.0, 1.0)) / pi + .5) * 12;
          final row = _land[min(((dy / r + 1) / 2 * _land.length).floor(), _land.length - 1)];
          final land = row[((u + shift).floor() % 24 + 24) % 24] == 'g';
          col = land ? (dx > r * .45 ? _gd : _g) : (dx < -r * .3 && dy < -r * .3 ? _l : _b);
        }
        _dot(x + i, y + j, col);
      }
    }
  }

  /// Preenche um polígono (em coordenadas 0..1 da caixa) pixel a pixel, sem suavizar a borda.
  void _poly(List<(double, double)> pts, Color col, double x, double y, double w, double h) {
    final pp = [for (final (u, v) in pts) (x + u * w, y + v * h)];
    for (var j = (y - 1).floor(); j < y + h + 1; j++) {
      for (var i = (x - 1).floor(); i < x + w + 1; i++) {
        final px = i + .5, py = j + .5;
        var inside = false;
        for (var a = 0, b = pp.length - 1; a < pp.length; b = a++) {
          final (xa, ya) = pp[a];
          final (xb, yb) = pp[b];
          if ((ya > py) != (yb > py) && px < (xb - xa) * (py - ya) / (yb - ya) + xa) inside = !inside;
        }
        if (inside) _dot(i, j, col);
      }
    }
  }

  List<(double, double)> _shrink(List<(double, double)> pts, double k) {
    final cx = pts.fold(0.0, (a, p) => a + p.$1) / pts.length, cy = pts.fold(0.0, (a, p) => a + p.$2) / pts.length;
    return [for (final (u, v) in pts) (cx + (u - cx) * k, cy + (v - cy) * k)];
  }

  void _outlined(List<(double, double)> pts, Color fill, double x, double y, double w, double h, int s) {
    _poly(pts, _o, x, y, w, h);
    _poly(_shrink(pts, 1 - 2.4 / s), fill, x, y, w, h);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _c = canvas;
    final w = (size.width / px).floor(), h = (size.height / px).floor();
    final s = max(14, (64 / px).round());
    final gx = 2, gy = h - s - 1;
    final fw = (s * 1.25).roundToDouble(), fh = (s * 1.05).roundToDouble();
    final fx = (w - s - 2) - (fw - s), fy = (h - s - 1).toDouble();

    _globe(gx, gy, s, (t * 48).floor() % 24);

    // posição de cada nota, andando em passos
    final steps = fps;
    final notes = <(int, int, double)>[];
    var arriving = false;
    for (var i = 0; i < 3; i++) {
      final p = (((t * 3) + i / 3) % 1 * steps).floor() / steps;
      final x0 = gx + s * .7, y0 = gy + s * .2, x1 = fx + (fw - s) + s * .15, y1 = fy + s * .12;
      final x = (x0 + (x1 - x0) * p).round(), y = (y0 + (y1 - y0) * p - h * .38 * 4 * p * (1 - p)).round();
      if (p > .8) arriving = true;
      if (p < .04 || p > .92) continue;
      notes.add((x, y, p));
    }

    // pasta aberta na diagonal: fundo, papel, nota chegando, frente (que baixa um pouco ao receber)
    _outlined(const [(0.10, 0.22), (0.30, 0.13), (0.37, 0.18), (0.80, 0.04), (0.90, 0.68), (0.18, 0.88)], _y, fx, fy, fw, fh, s);
    final paper = const [(0.28, 0.20), (0.72, 0.10), (0.77, 0.60), (0.33, 0.72)];
    _poly(paper, _paperEdge, fx, fy, fw, fh);
    _poly(_shrink(paper, 1 - 2.4 / s), Colors.white, fx, fy, fw, fh);
    for (var k = 0; k < 3; k++) {
      _poly([(0.36, 0.30 + k * .1), (0.66, 0.23 + k * .1), (0.66, 0.25 + k * .1), (0.36, 0.32 + k * .1)], _paperLine, fx, fy, fw, fh);
    }
    for (final (x, y, p) in notes) {
      if (p > .8) _sprite(_note, x, y);
    }
    final d = arriving ? .08 : 0.0;
    _outlined([(0.03, 0.50 + d), (0.76, 0.36 + d), (0.99, 0.93), (0.16, 1.0)], _f, fx, fy, fw, fh, s);
    _poly([(0.07, 0.53 + d), (0.76, 0.40 + d), (0.78, 0.44 + d), (0.08, 0.57 + d)], _fl, fx, fy, fw, fh);
    for (final (x, y, p) in notes) {
      if (p <= .8) _sprite(_note, x, y);
    }
  }

  @override
  bool shouldRepaint(_CopyPainter old) => old.t != t || old.px != px;
}
