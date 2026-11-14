import 'package:material_ui/material_ui.dart';

/// Paleta "Windows XP / WMP" usada em todo o app.
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
  static const gold = Color(0xFFE0A800);
  static const red = Color(0xFFC2381A);

  static const titleGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [blueLight, blue, Color(0xFF0F4FC4), Color(0xFF2A73E8)],
    stops: [0, .45, .55, 1],
  );

  static const barGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF5F8FE0), Color(0xFF2A5BC4), Color(0xFF123F9E), Color(0xFF2B63CF)],
    stops: [0, .45, .55, 1],
  );

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: blue, primary: blue, secondary: navy),
      scaffoldBackgroundColor: bgBottom,
      fontFamily: 'Tahoma',
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: const Color(0xFF111111), displayColor: navy),
      snackBarTheme: const SnackBarThemeData(backgroundColor: navy, behavior: SnackBarBehavior.floating),
    );
  }
}

/// Fundo azul claro em degradê das telas.
class XpBackground extends StatelessWidget {
  final Widget child;
  const XpBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Xp.bgTop, Xp.bgBottom],
          ),
        ),
        child: child,
      );
}

/// Barra de título estilo janela do Windows XP.
class XpTitleBar extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  const XpTitleBar({super.key, required this.title, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(gradient: Xp.titleGradient),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white70),
            gradient: const RadialGradient(
              center: Alignment(-.3, -.3),
              colors: [Color(0xFFFFD36B), Color(0xFFE07B00)],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 15,
              shadows: [Shadow(color: Color(0xFF0A2F80), offset: Offset(1, 1))],
            ),
          ),
        ),
        ...actions,
      ]),
    );
  }
}

/// Pequeno botão quadrado da barra de título (ícone branco).
class XpTitleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  const XpTitleButton({super.key, required this.icon, required this.onTap, required this.tooltip});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            width: 28,
            height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: Colors.white),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF5D9CF7), Color(0xFF2363D6)],
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 16),
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
  const GlossyButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 44,
    this.active = false,
    this.tooltip,
  });

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
          boxShadow: const [
            BoxShadow(color: Color(0xFF1D3C78), spreadRadius: 1),
          ],
        ),
        child: Icon(
          icon,
          size: size * .48,
          color: active ? Xp.red : const Color(0xFF1D3C78),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Barra azul brilhante que segura os botões de transporte.
class GlossyBar extends StatelessWidget {
  final List<Widget> children;
  const GlossyBar({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          gradient: Xp.barGradient,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: const Color(0xFF0B2F7A)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: children),
      );
}

/// Botão retangular clássico do XP (fundo claro, borda azul).
class XpButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;
  const XpButton({super.key, required this.label, this.icon, this.onTap, this.primary = false});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : .5,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFF003C74)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: primary
                  ? const [Color(0xFF5BA3F5), Color(0xFF2A72D8)]
                  : const [Colors.white, Color(0xFFE3E3DB)],
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: primary ? Colors.white : Xp.navy),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: primary ? FontWeight.bold : FontWeight.normal,
                  color: primary ? Colors.white : Colors.black87,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Caixa estilo menu do iPod (cabeçalho prateado + linhas).
class IpodBox extends StatelessWidget {
  final String title;
  final String? trailing;
  final List<Widget> children;
  const IpodBox({super.key, required this.title, this.trailing, required this.children});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFF7F8A9C), width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFF4F6FA), Color(0xFFC8CED9)],
              ),
              border: Border(bottom: BorderSide(color: Color(0xFF8892A5))),
            ),
            child: Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
              if (trailing != null) Text(trailing!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
          ),
          ...children,
        ]),
      );
}

class IpodRow extends StatelessWidget {
  final String label;
  final String? detail;
  final VoidCallback? onTap;
  final bool selected;
  const IpodRow({super.key, required this.label, this.detail, this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF5BA3F5), Color(0xFF2A72D8)])
                : null,
            border: const Border(bottom: BorderSide(color: Xp.listBorder)),
          ),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                    fontSize: 15,
                    color: selected ? Colors.white : Colors.black87,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  )),
            ),
            if (detail != null)
              Text(detail!, style: TextStyle(fontSize: 12, color: selected ? Colors.white70 : const Color(0xFF7A869C))),
            Icon(Icons.chevron_right, size: 18, color: selected ? Colors.white : const Color(0xFF7A869C)),
          ]),
        ),
      );
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
        child: Text(text.toUpperCase(),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Xp.navy, letterSpacing: .5)),
      );
}

/// Cor estável derivada de um texto, para capas sem imagem.
Color colorFor(String seed) {
  final h = seed.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), .55, .45).toColor();
}
