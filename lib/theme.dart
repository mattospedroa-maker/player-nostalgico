import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'xp_icons.dart';

/// Paleta "Windows XP / WMP 9" usada em todo o app.
class Xp {
  static const navy = Color(0xFF0A246A);
  static const navyDeep = Color(0xFF06163F);
  static const blue = Color(0xFF1C5FD8);
  static const blueLight = Color(0xFF3B8CF5);
  static const blueText = Color(0xFF33507F);
  static const blueMuted = Color(0xFF5A6F95);
  static const bgTop = Color(0xFFDFE9F8);
  static const bgBottom = Color(0xFFC7D7EF);
  static const beige = Color(0xFFECE9D8);
  static const beigeBorder = Color(0xFFACA899);
  static const listBorder = Color(0xFFE4E8EF);
  static const select = Color(0xFF316AC5);
  static const linkBlue = Color(0xFF215DC6);
  static const gold = Color(0xFFE0A800);
  static const red = Color(0xFFC2381A);
  static const shadow = Color(0xFF716F64);
  static const lcdText = Color(0xFF7FD4FF);
  static const lcdDim = Color(0xFF4F86C9);

  /// Barra de título "Luna" do XP.
  static const titleGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0997FF), Color(0xFF0053EE), Color(0xFF0050EE), Color(0xFF0066FF), Color(0xFF005BFF), Color(0xFF003DD7)],
    stops: [0, .08, .4, .88, .95, 1],
  );

  /// Barra de controles escura do WMP 9.
  static const barGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF2A4F9E), Color(0xFF0D2766), Color(0xFF06163F), Color(0xFF183D8A)],
    stops: [0, .48, .52, 1],
  );

  static const lcdStyle = TextStyle(
    fontFamily: 'Lcd',
    color: lcdText,
    fontSize: 22,
    height: 1,
    shadows: [Shadow(color: Color(0xFF2AA8FF), blurRadius: 5)],
  );

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: blue, primary: blue, secondary: navy),
      scaffoldBackgroundColor: beige,
      fontFamily: 'XpSans',
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: const Color(0xFF111111), displayColor: navy),
      snackBarTheme: const SnackBarThemeData(backgroundColor: navy, behavior: SnackBarBehavior.floating),
      dialogTheme: const DialogThemeData(
        backgroundColor: beige,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: Color(0xFF0831D9), width: 3),
        ),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: Color(0xFFACA899)),
        ),
        textStyle: TextStyle(fontFamily: 'XpSans', fontSize: 14, color: Colors.black),
      ),
      bottomSheetTheme: const BottomSheetThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero)),
    );
  }
}

/// Fundo bege das janelas do XP.
class XpBackground extends StatelessWidget {
  final Widget child;
  const XpBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ColoredBox(color: Xp.beige, child: child);
}

/// Borda em relevo do Windows 98/XP: [sunken] = afundada (campos, visor), senão saltada (botões).
class Bevel extends StatelessWidget {
  final Widget child;
  final bool sunken;
  final Color? color;
  final EdgeInsetsGeometry? padding;
  const Bevel({super.key, required this.child, this.sunken = false, this.color, this.padding});

  @override
  Widget build(BuildContext context) {
    final light = sunken ? const Color(0xFF808080) : Colors.white;
    final dark = sunken ? Colors.white : Xp.shadow;
    final innerLight = sunken ? const Color(0xFF404040) : const Color(0xFFF7F6EF);
    final innerDark = sunken ? const Color(0xFFDFDFDF) : Xp.beigeBorder;
    return Container(
      decoration: BoxDecoration(
        color: color ?? (sunken ? Colors.white : Xp.beige),
        border: Border(
          top: BorderSide(color: light),
          left: BorderSide(color: light),
          right: BorderSide(color: dark),
          bottom: BorderSide(color: dark),
        ),
      ),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: innerLight),
            left: BorderSide(color: innerLight),
            right: BorderSide(color: innerDark),
            bottom: BorderSide(color: innerDark),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// Barra de título estilo janela do Windows XP (Luna).
class XpTitleBar extends StatelessWidget {
  final String title;
  final XpIcons icon;
  final List<Widget> actions;
  const XpTitleBar({super.key, required this.title, this.icon = XpIcons.cassette, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: const BoxDecoration(
        gradient: Xp.titleGradient,
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      padding: const EdgeInsets.only(left: 8, right: 5),
      child: Row(
        children: [
          XpIcon(icon, size: 20),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
                shadows: [Shadow(color: Color(0xFF0F1089), offset: Offset(1, 1))],
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Botão da barra de título (azul; o de fechar é vermelho, como no XP).
class XpTitleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  const XpTitleButton({super.key, required this.icon, required this.onTap, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    final close = icon == Icons.close;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(left: 3),
          width: 27,
          height: 27,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: Colors.white),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: close ? const [Color(0xFFF3A48A), Color(0xFFE1532E), Color(0xFFC43B1B)] : const [Color(0xFF76A6FF), Color(0xFF2F68E8), Color(0xFF1C4FD0)],
            ),
          ),
          child: Icon(icon, color: Colors.white, size: 17),
        ),
      ),
    );
  }
}

/// Item de um menu da barra de menus.
class XpMenuItem {
  final String label;
  final VoidCallback? onTap;
  final bool checked;
  const XpMenuItem(this.label, this.onTap, {this.checked = false});
}

/// Barra de menus (Arquivo, Exibir…): cada menu abre uma lista de verdade.
class XpMenuBar extends StatelessWidget {
  final List<(String, List<XpMenuItem>)> menus;
  const XpMenuBar(this.menus, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    height: 30,
    decoration: const BoxDecoration(
      color: Xp.beige,
      border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8))),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      children: [
        for (final (label, items) in menus)
          PopupMenuButton<int>(
            tooltip: '',
            offset: const Offset(0, 28),
            padding: EdgeInsets.zero,
            itemBuilder: (_) => [
              for (var i = 0; i < items.length; i++)
                PopupMenuItem<int>(
                  value: i,
                  enabled: items[i].onTap != null,
                  height: 40,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: items[i].checked ? const Text('✓', style: TextStyle(fontWeight: FontWeight.bold)) : null,
                      ),
                      Text(items[i].label),
                    ],
                  ),
                ),
            ],
            onSelected: (i) => items[i].onTap?.call(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: label.substring(0, 1),
                      style: const TextStyle(decoration: TextDecoration.underline),
                    ),
                    TextSpan(text: label.substring(1)),
                  ],
                ),
                style: const TextStyle(fontSize: 14, color: Colors.black),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Barra de status no rodapé da janela ("Pronto", contagens…).
class XpStatusBar extends StatelessWidget {
  final List<String> parts;
  const XpStatusBar(this.parts, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    height: 26,
    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
    decoration: const BoxDecoration(
      color: Xp.beige,
      border: Border(top: BorderSide(color: Xp.beigeBorder)),
    ),
    child: Row(
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          (i == 0 ? (Widget w) => Expanded(child: w) : (Widget w) => w)(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.centerLeft,
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Xp.beigeBorder),
                  left: BorderSide(color: Xp.beigeBorder),
                  right: BorderSide(color: Colors.white),
                  bottom: BorderSide(color: Colors.white),
                ),
              ),
              child: Text(
                parts[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF222222)),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Barra de endereço do Explorer: "Endereço  [📁 Música\Álbuns]".
class XpAddressBar extends StatelessWidget {
  final String path;
  const XpAddressBar(this.path, {super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
    decoration: const BoxDecoration(
      color: Xp.beige,
      border: Border(bottom: BorderSide(color: Color(0xFFD4D0C8))),
    ),
    child: Row(
      children: [
        const Text('Endereço', style: TextStyle(fontSize: 12.5, color: Color(0xFF555555))),
        const SizedBox(width: 6),
        Expanded(
          child: Bevel(
            sunken: true,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              children: [
                const XpIcon(XpIcons.folder, size: 16),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Cabeçalho de colunas do modo "Detalhes" (Nome | Faixas).
class XpColumnHeader extends StatelessWidget {
  final String name;
  final String? right;
  const XpColumnHeader(this.name, {super.key, this.right});

  @override
  Widget build(BuildContext context) {
    Widget cell(String t, {double? width}) {
      final c = Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: const BoxDecoration(
          color: Color(0xFFEBEADB),
          border: Border(
            right: BorderSide(color: Color(0xFFC7C5B2)),
            bottom: BorderSide(color: Color(0xFFD6D4C3), width: 3),
          ),
        ),
        child: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
      );
      return width == null ? Expanded(child: c) : c;
    }

    return Row(children: [cell(name), if (right != null) cell(right!, width: 92)]);
  }
}

/// Painel azul de tarefas do Explorer ("Tarefas de música").
class XpTaskPane extends StatelessWidget {
  final String title;
  final List<(XpIcons, String, VoidCallback?)> tasks;
  const XpTaskPane({super.key, required this.title, required this.tasks});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(9),
    decoration: const BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF7BA2E7), Color(0xFF6375D6)]),
    ),
    child: Container(
      decoration: const BoxDecoration(
        color: Color(0xFFD6DFF7),
        borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.white, Color(0xFFC6D3F7)])),
            child: Text(
              title,
              style: const TextStyle(color: Xp.linkBlue, fontWeight: FontWeight.bold, fontSize: 13.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final (icon, label, onTap) in tasks)
                  InkWell(
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      child: Row(
                        children: [
                          XpIcon(icon, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(label, style: const TextStyle(color: Xp.linkBlue, fontSize: 14)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Botão redondo prateado com brilho (estilo WMP).
class GlossyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final bool active;
  final String? tooltip;
  const GlossyButton({super.key, required this.icon, this.onTap, this.size = 44, this.active = false, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final btn = GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFDFE7F2), width: 2),
          gradient: const RadialGradient(
            center: Alignment(0, -.4),
            radius: .9,
            colors: [Colors.white, Color(0xFFE3EAF4), Color(0xFFA9B9D1), Color(0xFF7F93B4)],
            stops: [0, .35, .75, 1],
          ),
          boxShadow: const [BoxShadow(color: Color(0xFF0B1F4F), spreadRadius: 1)],
        ),
        child: Icon(icon, size: size * .48, color: active ? Xp.red : const Color(0xFF1D3C78)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Barra escura do WMP 9 que segura os botões de transporte.
class GlossyBar extends StatelessWidget {
  final List<Widget> children;
  const GlossyBar({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
    decoration: BoxDecoration(
      gradient: Xp.barGradient,
      borderRadius: BorderRadius.circular(44),
      border: Border.all(color: const Color(0xFF031038)),
      boxShadow: const [BoxShadow(color: Color(0x33000000), offset: Offset(0, 2), blurRadius: 3)],
    ),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children),
  );
}

/// Botão retangular clássico do XP (bege, borda azul-escura, cantos levemente arredondados).
class XpButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final XpIcons? xpIcon;
  final VoidCallback? onTap;
  final bool primary;
  const XpButton({super.key, required this.label, this.icon, this.xpIcon, this.onTap, this.primary = false});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : .5,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: const Color(0xFF003C74)),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Color(0xFFF0F0EA), Color(0xFFE3E3DB), Color(0xFFD6D0C5)],
              stops: [0, .5, .85, 1],
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
            decoration: primary
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: const Color(0xFF8DB2F3), width: 2),
                  )
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (xpIcon != null) ...[
                  XpIcon(xpIcon!, size: 20),
                  const SizedBox(width: 7),
                ] else if (icon != null) ...[
                  Icon(icon, size: 18, color: Xp.navy),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: primary ? FontWeight.bold : FontWeight.normal, color: Colors.black),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Botão quadrado em relevo com ícone grande e legenda (barra de ações do Tocando agora).
class BevelButton extends StatelessWidget {
  final XpIcons icon;
  final String label;
  final VoidCallback? onTap;
  final bool on;
  const BevelButton({super.key, required this.icon, required this.label, this.onTap, this.on = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Bevel(
      sunken: on,
      color: on ? const Color(0xFFE3E1D4) : Xp.beige,
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          XpIcon(icon, size: 22),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, fontWeight: on ? FontWeight.bold : FontWeight.normal),
          ),
        ],
      ),
    ),
  );
}

/// Lista estilo Explorer em modo "Detalhes" (caixa branca afundada + cabeçalho de colunas).
class IpodBox extends StatelessWidget {
  final String title;
  final String? trailing;
  final List<Widget> children;
  const IpodBox({super.key, required this.title, this.trailing, required this.children});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Bevel(
      sunken: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          XpColumnHeader(title, right: trailing),
          ...children,
        ],
      ),
    ),
  );
}

class IpodRow extends StatelessWidget {
  final String label;
  final String? detail;
  final VoidCallback? onTap;
  final bool selected;
  final XpIcons? icon;
  const IpodRow({super.key, required this.label, this.detail, this.onTap, this.selected = false, this.icon});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      color: selected ? Xp.select : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      child: Row(
        children: [
          if (icon != null) ...[XpIcon(icon!, size: 24), const SizedBox(width: 9)],
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, color: selected ? Colors.white : Colors.black),
            ),
          ),
          if (detail != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12.5, color: selected ? Colors.white70 : const Color(0xFF666666)),
              ),
            ),
        ],
      ),
    ),
  );
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Color(0xFF1C3F94)),
    ),
  );
}

/// Visor LCD azul (fonte de pixel, linhas de varredura) com tempo e barrinhas de espectro.
class LcdPanel extends StatefulWidget {
  final List<(String, String)> lines;
  final String time;
  final String total;
  final bool playing;
  final String? note;
  const LcdPanel({super.key, required this.lines, required this.time, required this.total, required this.playing, this.note});

  @override
  State<LcdPanel> createState() => _LcdPanelState();
}

class _LcdPanelState extends State<LcdPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _tick = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  final _rnd = Random();
  List<double> _bars = List.filled(13, .15);

  @override
  void initState() {
    super.initState();
    _tick.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted && widget.playing) {
        // barrinhas decorativas (não é análise do áudio): sobem e descem enquanto toca
        setState(() => _bars = [for (var i = 0; i < _bars.length; i++) (.25 + _rnd.nextDouble() * .75) * (1 - i / (_bars.length * 1.6))]);
        _tick.forward(from: 0);
      }
    });
    if (widget.playing) _tick.forward();
  }

  @override
  void didUpdateWidget(LcdPanel old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_tick.isAnimating) _tick.forward(from: 0);
    if (!widget.playing) setState(() => _bars = List.filled(_bars.length, .1));
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Bevel(
    sunken: true,
    color: const Color(0xFF020A1C),
    child: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF020A1C), Color(0xFF06173D)]),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 7),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (k, v) in widget.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 78,
                        child: Text(
                          k.toUpperCase(),
                          style: Xp.lcdStyle.copyWith(color: Xp.lcdDim, shadows: const []),
                        ),
                      ),
                      Expanded(
                        child: Text(v.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: Xp.lcdStyle),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(widget.time, style: Xp.lcdStyle.copyWith(fontSize: 42, color: const Color(0xFFAEE6FF))),
                  Text(
                    '  / ${widget.total}',
                    style: Xp.lcdStyle.copyWith(fontSize: 22, color: Xp.lcdDim, shadows: const []),
                  ),
                  const Spacer(),
                  SizedBox(
                    height: 32,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final b in _bars)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 170),
                            width: 6,
                            height: 32 * b.clamp(.08, 1),
                            margin: const EdgeInsets.only(left: 2),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFBFF0FF), Color(0xFF1F8FFF)]),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (widget.note != null) Text(widget.note!, style: Xp.lcdStyle.copyWith(fontSize: 18, color: const Color(0xFFFF8A7A))),
            ],
          ),
          // linhas de varredura do visor
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _ScanLines())),
          ),
        ],
      ),
    ),
  );
}

class _ScanLines extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x38000000);
    for (var y = 2.0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(_ScanLines old) => false;
}

/// Cor estável derivada de um texto, para capas sem imagem.
Color colorFor(String seed) {
  final h = seed.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), .55, .45).toColor();
}
