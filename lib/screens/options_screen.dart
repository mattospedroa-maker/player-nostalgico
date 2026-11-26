import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../app_version.dart';
import '../crossfade.dart';
import '../net_policy.dart';
import '../player_service.dart';
import '../storage_service.dart';
import '../theme.dart';
import '../xp_icons.dart';

/// Janela "Opções" no estilo do Windows Media Player: aba Reprodução (transição suave) e
/// aba Armazenamento (espaço de cada coisa e teto dos GIFs).
class OptionsScreen extends StatefulWidget {
  /// Só para testes; no app vem o PlayerService.
  final CrossfadeSettings? settings;

  /// Aba que abre primeiro (0 Reprodução, 1 Armazenamento, 2 Internet).
  final int initialTab;
  const OptionsScreen({super.key, this.settings, this.initialTab = 0});

  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class _OptionsScreenState extends State<OptionsScreen> {
  late final CrossfadeSettings _ps = widget.settings ?? context.read<PlayerService>();
  late bool _on;
  late int _out;
  late int _in;
  late int _tab = widget.initialTab;

  /// Teto escolhido na aba Armazenamento (null = não mexeu).
  int? _cap;

  /// Escolhas da aba Internet (null = não mexeu).
  NetMode? _netMode;
  Set<NetFeature>? _netOff;

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

  bool get _capChanged => _cap != null && _cap != context.read<AppState>().storageCapMb;

  bool get _netChanged {
    if (_netMode == null && _netOff == null) return false;
    final net = context.read<AppState>().net;
    return (_netMode ?? net.mode) != net.mode || !setEquals(_netOff ?? net.disabled, net.disabled);
  }

  bool get _changed =>
      _on != _ps.crossfade || _out != _ps.fadeOut.inSeconds || _in != _ps.fadeIn.inSeconds || _capChanged || _netChanged;

  void _apply() {
    _ps.setCrossfadeTimes(Duration(seconds: _out), Duration(seconds: _in));
    _ps.setCrossfade(_on);
    if (_capChanged) context.read<AppState>().setStorageCapMb(_cap!);
    if (_netChanged) {
      final net = context.read<AppState>().net;
      net.set(_netMode ?? net.mode, _netOff ?? net.disabled);
    }
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
                      XpTabs(labels: const ['Reprodução', 'Armazenamento', 'Internet'], current: _tab, onTap: (i) => setState(() => _tab = i)),
                      Expanded(
                        child: XpTabPage(
                          child: switch (_tab) {
                            0 => ListView(padding: EdgeInsets.zero, children: [_fadeGroup(), _previewGroup()]),
                            1 => StorageTab(cap: _cap, onCap: (mb) => setState(() => _cap = mb)),
                            _ => InternetTab(
                                mode: _netMode,
                                off: _netOff,
                                onChanged: (m, off) => setState(() {
                                  _netMode = m;
                                  _netOff = off;
                                }),
                              ),
                          },
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
              const XpStatusBar(['Nostalgic MPlayer', 'Versão $appVersion'], showNet: false),
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

/// Aba "Armazenamento", como as Propriedades do disco do XP: pizza deitada com o usado e o livre
/// no teto, a escolha do teto e o "Limpar agora".
class StorageTab extends StatefulWidget {
  /// Teto escolhido e ainda não aplicado (null = o salvo).
  final int? cap;
  final ValueChanged<int> onCap;

  /// Só para testes; no app vêm do AppState.
  final Future<StorageReport> Function()? measure;
  final Future<CleanResult> Function()? clean;
  final int? savedCap;
  const StorageTab({super.key, this.cap, required this.onCap, this.measure, this.clean, this.savedCap});

  @override
  State<StorageTab> createState() => _StorageTabState();
}

class _StorageTabState extends State<StorageTab> {
  StorageReport? _r;
  bool _cleaning = false;
  String? _done;

  // uma cor por mídia: músicas no azul do disco do XP, podcasts laranja, audiolivros magenta
  static const musicColor = Color(0xFF2E4FE6);
  static const podcastColor = Color(0xFFF29A1F);
  static const bookColor = Color(0xFFE23DE2);

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final r = await (widget.measure ?? context.read<AppState>().storage.measure)();
    if (mounted) setState(() => _r = r);
  }

  Future<void> _clean() async {
    setState(() {
      _cleaning = true;
      _done = null;
    });
    final res = await (widget.clean ?? context.read<AppState>().autoClean)();
    if (!mounted) return;
    setState(() {
      _cleaning = false;
      _done = res.freedBytes == 0
          ? 'Nada para limpar.'
          : '${formatBytes(res.freedBytes)} liberados'
              '${res.trimmedTracks > 0 ? ' (${res.trimmedTracks} músicas voltam a baixar GIFs quando tocarem)' : ''}.';
    });
    await _measure();
  }

  @override
  Widget build(BuildContext context) {
    final cap = widget.cap ?? widget.savedCap ?? context.watch<AppState>().storageCapMb;
    final r = _r;
    final capBytes = cap * 1024 * 1024;
    final used = r?.capped ?? 0;
    final free = cap == 0 ? 0 : math.max(0, capBytes - used);
    const small = TextStyle(fontSize: 12, color: Color(0xFF555555));
    const body = TextStyle(fontSize: 13.5);
    const bold = TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold);
    // a pizza mostra para que mídia foi cada espaço
    final slices = [r?.total ?? 0, r?.podcasts ?? 0, r?.audiobooks ?? 0];
    const labels = ['GIFs e imagens das músicas', 'Podcasts', 'Audiolivros'];
    const colors = [musicColor, podcastColor, bookColor];
    return ListView(padding: EdgeInsets.zero, children: [
      XpGroupBox(
        title: 'Espaço por mídia',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (r == null)
            const Padding(padding: EdgeInsets.all(8), child: Text('Medindo...', style: small))
          else ...[
            Center(
              child: SizedBox(
                width: 170,
                height: 104,
                child: CustomPaint(key: const Key('storage-pie'), painter: DiskPiePainter(slices.map((v) => v.toDouble()).toList(), colors)),
              ),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Container(width: 12, height: 12, decoration: BoxDecoration(color: colors[i], border: Border.all(color: const Color(0xFF555555)))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(labels[i], style: body)),
                  Text(formatBytes(slices[i]), style: bold),
                ]),
              ),
          ],
          const SizedBox(height: 4),
          const Text('Podcasts e audiolivros contam o áudio inteiro. O teto abaixo vale só para os GIFs e as fotos.', style: small),
        ]),
      ),
      XpGroupBox(
        title: 'Teto dos GIFs',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [const Expanded(child: Text('Usado (GIFs e fotos)', style: body)), Text(formatBytes(used), style: bold)]),
          if (cap != 0) ...[
            const SizedBox(height: 4),
            Row(children: [const Expanded(child: Text('Livre no teto', style: body)), Text(formatBytes(free), style: bold)]),
          ],
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('Teto de espaço:', style: body)),
            DropdownButton<int>(
              key: const Key('options-cap'),
              value: cap,
              isDense: true,
              style: const TextStyle(fontFamily: 'XpSans', fontSize: 13.5, color: Colors.black),
              items: [for (final mb in storageCapChoices) DropdownMenuItem(value: mb, child: Text(capLabel(mb)))],
              onChanged: (v) {
                if (v != null) widget.onCap(v);
              },
            ),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Passou do teto: o app apaga primeiro os GIFs que nenhuma música usa, depois os automáticos das músicas '
            'que você não ouve há mais tempo. Eles voltam quando a música tocar. GIFs que você escolheu e os das '
            'favoritas nunca são apagados.',
            style: small,
          ),
        ]),
      ),
      XpGroupBox(
        title: 'Limpeza',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [const Expanded(child: Text('GIFs sem música (órfãos)', style: body)), Text(formatBytes(r?.orphans ?? 0), style: bold)]),
          const SizedBox(height: 4),
          Row(children: [const Expanded(child: Text('Cache da notificação', style: body)), Text(formatBytes(r?.cache ?? 0), style: bold)]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(_done ?? '', style: small)),
            OutlinedButton(
              key: const Key('options-clean'),
              onPressed: _cleaning ? null : _clean,
              child: Text(_cleaning ? 'Limpando...' : 'Limpar agora'),
            ),
          ]),
        ]),
      ),
    ]);
  }
}

/// Pizza "deitada" (de perfil, com a borda grossa embaixo), como a do disco nas Propriedades do XP.
class DiskPiePainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  const DiskPiePainter(this.values, this.colors);

  static Color _shade(Color c, double f) => Color.from(alpha: 1, red: c.r * f, green: c.g * f, blue: c.b * f);

  @override
  void paint(Canvas canvas, Size size) {
    final depth = size.height * .2;
    final top = Rect.fromLTWH(0, 0, size.width, size.height - depth);
    final bottom = top.shift(Offset(0, depth));
    final c = top.center;
    final rx = top.width / 2, ry = top.height / 2;
    Offset at(Offset center, double a) => center + Offset(rx * math.cos(a), ry * math.sin(a));
    final total = values.fold(0.0, (a, b) => a + b);
    final line = Paint()
      ..color = const Color(0xFF333333)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // fatias: começa às 3 horas e vai no sentido do relógio, como no XP
    final parts = <(double, double, Color)>[];
    if (total <= 0) {
      parts.add((0, 2 * math.pi, _shade(colors.last, .9)));
    } else {
      var a = 0.0;
      for (var i = 0; i < values.length; i++) {
        final sweep = values[i] / total * 2 * math.pi;
        if (sweep > 0) parts.add((a, a + sweep, colors[i % colors.length]));
        a += sweep;
      }
    }
    // borda (só a metade da frente aparece: ângulos de 0 a pi)
    for (final (s, e, color) in parts) {
      final a = math.max(s, 0.0), b = math.min(e, math.pi);
      if (b <= a) continue;
      final side = Path()
        ..moveTo(at(c, a).dx, at(c, a).dy)
        ..arcTo(top, a, b - a, false)
        ..lineTo(at(bottom.center, b).dx, at(bottom.center, b).dy)
        ..arcTo(bottom, b, -(b - a), false)
        ..close();
      canvas.drawPath(side, Paint()..color = _shade(color, .62));
      canvas.drawLine(at(c, b), at(bottom.center, b), line);
    }
    // contorno da borda
    canvas.drawLine(Offset(top.left, c.dy), Offset(bottom.left, bottom.center.dy), line);
    canvas.drawLine(Offset(top.right, c.dy), Offset(bottom.right, bottom.center.dy), line);
    canvas.drawArc(bottom, 0, math.pi, false, line);
    // tampa
    for (final (s, e, color) in parts) {
      canvas.drawArc(top, s, e - s, true, Paint()..color = color);
      if (parts.length > 1) canvas.drawLine(c, at(c, s), line);
    }
    canvas.drawOval(top, line);
  }

  @override
  bool shouldRepaint(DiskPiePainter old) => old.values.join() != values.join();
}

/// Aba "Internet": trabalhar off-line, só no Wi-Fi e o que o app pode buscar sozinho.
class InternetTab extends StatelessWidget {
  /// Escolhas ainda não aplicadas (null = as salvas).
  final NetMode? mode;
  final Set<NetFeature>? off;
  final void Function(NetMode mode, Set<NetFeature> off) onChanged;

  /// Só para testes; no app vem do AppState.
  final NetPolicy? policy;
  const InternetTab({super.key, this.mode, this.off, required this.onChanged, this.policy});

  @override
  Widget build(BuildContext context) {
    final net = policy ?? context.watch<AppState>().net;
    final m = mode ?? net.mode;
    final disabled = off ?? net.disabled;
    const small = TextStyle(fontSize: 12, color: Color(0xFF555555));
    Widget box(Key key, String label, bool value, ValueChanged<bool> change, {bool enabled = true}) => CheckboxListTile(
          key: key,
          dense: true,
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          controlAffinity: ListTileControlAffinity.leading,
          value: value,
          onChanged: enabled ? (v) => change(v ?? false) : null,
          title: Text(label, style: TextStyle(fontSize: 14, color: enabled ? Colors.black : const Color(0xFF999999))),
        );
    final offline = m == NetMode.offline;
    return ListView(padding: EdgeInsets.zero, children: [
      XpGroupBox(
        title: 'Conexão',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          box(const Key('net-offline'), 'Trabalhar off-line (nada usa a internet)', offline,
              (v) => onChanged(v ? NetMode.offline : NetMode.online, disabled)),
          box(const Key('net-wifi'), 'Só usar a internet no Wi-Fi', m == NetMode.wifiOnly,
              (v) => onChanged(v ? NetMode.wifiOnly : NetMode.online, disabled), enabled: !offline),
          if (m == NetMode.wifiOnly)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: Text(net.onWifi ? 'Agora: no Wi-Fi, a internet está liberada.' : 'Agora: nos dados móveis, o app espera o Wi-Fi.', style: small),
            ),
        ]),
      ),
      XpGroupBox(
        title: 'O que pode buscar sozinho',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final f in NetFeature.values)
            box(Key('net-${f.name}'), f.label, !disabled.contains(f), (v) => onChanged(m, v ? ({...disabled}..remove(f)) : {...disabled, f}),
                enabled: !offline),
          const SizedBox(height: 4),
          const Text(
            'O que você pede na hora sempre funciona: baixar do YouTube, "Preencher pelo MusicBrainz" no Editar e o botão Resumo dos podcasts.',
            style: small,
          ),
        ]),
      ),
    ]);
  }
}
