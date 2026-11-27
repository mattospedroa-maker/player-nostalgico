import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../audiobooks.dart';
import '../models.dart';
import '../book_service.dart';
import '../book_text.dart';
import '../player_service.dart';
import '../podcasts.dart' show formatClock;
import '../theme.dart';
import '../xp_icons.dart';

// ---------------------------------------------------------------------------
// Aparência do leitor (Aa)

enum ReaderFont { serif, sans }

enum ReaderPaper { paper, white, dark }

class ReaderLook {
  final ReaderFont font;

  /// 0 = pequena, 1 = média, 2 = grande.
  final int size;
  final ReaderPaper paper;

  /// Destacar a frase que está sendo lida (texto da transcrição do vídeo).
  final bool highlight;

  /// Ajuste fino do destaque (ms): positivo = destaque vai na frente da voz; negativo = atrás.
  final int syncMs;
  const ReaderLook({this.font = ReaderFont.serif, this.size = 1, this.paper = ReaderPaper.paper, this.highlight = true, this.syncMs = 0});

  static const _sizes = [14.5, 17.0, 20.0];

  double fontSize({bool compact = false}) => _sizes[size.clamp(0, 2)] * (compact ? .8 : 1);
  String? get family => font == ReaderFont.serif ? 'serif' : null;

  Color get background => switch (paper) { ReaderPaper.paper => const Color(0xFFF8F1DC), ReaderPaper.white => Colors.white, ReaderPaper.dark => const Color(0xFF1E2230) };
  Color get ink => switch (paper) { ReaderPaper.paper => const Color(0xFF2B2416), ReaderPaper.white => const Color(0xFF1A1A1A), ReaderPaper.dark => const Color(0xFFD9D4C5) };
  Color get faint => switch (paper) { ReaderPaper.paper => const Color(0xFF8A7A55), ReaderPaper.white => const Color(0xFF888888), ReaderPaper.dark => const Color(0xFF8C8FA0) };

  /// Fundo da frase destacada.
  Color get mark => switch (paper) { ReaderPaper.paper => const Color(0x66F2C230), ReaderPaper.white => const Color(0x55FFD54A), ReaderPaper.dark => const Color(0x664D7BE0) };

  /// Verso da folha (o que aparece na dobra).
  Color get back => switch (paper) { ReaderPaper.paper => const Color(0xFFEDE1BF), ReaderPaper.white => const Color(0xFFEDEDED), ReaderPaper.dark => const Color(0xFF2C3142) };

  static ReaderLook of(AppState app) => ReaderLook(
        font: ReaderFont.values.asNameMap()[app.prefs.getString('leitorFonte')] ?? ReaderFont.serif,
        size: app.prefs.getInt('leitorTamanho') ?? 1,
        paper: ReaderPaper.values.asNameMap()[app.prefs.getString('leitorPapel')] ?? ReaderPaper.paper,
        highlight: app.prefs.getBool('leitorDestaque') ?? true,
        syncMs: app.prefs.getInt('leitorAtraso') ?? 0,
      );

  Future<void> save(AppState app) async {
    await app.prefs.setString('leitorFonte', font.name);
    await app.prefs.setInt('leitorTamanho', size);
    await app.prefs.setString('leitorPapel', paper.name);
    await app.prefs.setBool('leitorDestaque', highlight);
    await app.prefs.setInt('leitorAtraso', syncMs);
    app.touch();
  }

  ReaderLook copyWith({ReaderFont? font, int? size, ReaderPaper? paper, bool? highlight, int? syncMs}) => ReaderLook(
        font: font ?? this.font,
        size: size ?? this.size,
        paper: paper ?? this.paper,
        highlight: highlight ?? this.highlight,
        syncMs: syncMs ?? this.syncMs,
      );

  @override
  bool operator ==(Object other) =>
      other is ReaderLook && other.font == font && other.size == size && other.paper == paper && other.highlight == highlight && other.syncMs == syncMs;
  @override
  int get hashCode => Object.hash(font, size, paper, highlight, syncMs);
}

String _syncLabel(int ms) => ms == 0 ? '(no tempo)' : '(${ms > 0 ? '+' : '−'}${(ms.abs() / 1000).toStringAsFixed(2).replaceAll('.', ',')} s)';

/// Janelinha do "Aa": fonte, tamanho, papel e o destaque da frase.
Future<void> showReaderLook(BuildContext context) {
  final app = context.read<AppState>();
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final look = ReaderLook.of(app);
      Widget opt(String label, bool on, ReaderLook next) => Padding(
            padding: const EdgeInsets.all(2),
            child: GestureDetector(
              onTap: () async {
                await next.save(app);
                setState(() {});
              },
              child: Bevel(
                sunken: on,
                color: on ? const Color(0xFFE3E1D4) : Xp.beige,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(label, style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.bold : FontWeight.normal)),
              ),
            ),
          );
      return XpAlertDialog(
        icon: XpIcons.doc,
        title: const Text('Aparência do livro'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Letra', style: TextStyle(fontSize: 12.5, color: Xp.blueText)),
          Wrap(children: [
            opt('Serifada', look.font == ReaderFont.serif, look.copyWith(font: ReaderFont.serif)),
            opt('Sem serifa', look.font == ReaderFont.sans, look.copyWith(font: ReaderFont.sans)),
          ]),
          const SizedBox(height: 6),
          const Text('Tamanho', style: TextStyle(fontSize: 12.5, color: Xp.blueText)),
          Wrap(children: [
            opt('Pequena', look.size == 0, look.copyWith(size: 0)),
            opt('Média', look.size == 1, look.copyWith(size: 1)),
            opt('Grande', look.size == 2, look.copyWith(size: 2)),
          ]),
          const SizedBox(height: 6),
          const Text('Fundo', style: TextStyle(fontSize: 12.5, color: Xp.blueText)),
          Wrap(children: [
            opt('Papel', look.paper == ReaderPaper.paper, look.copyWith(paper: ReaderPaper.paper)),
            opt('Branco', look.paper == ReaderPaper.white, look.copyWith(paper: ReaderPaper.white)),
            opt('Escuro', look.paper == ReaderPaper.dark, look.copyWith(paper: ReaderPaper.dark)),
          ]),
          const SizedBox(height: 6),
          const Text('Destacar a frase lida (texto da transcrição)', style: TextStyle(fontSize: 12.5, color: Xp.blueText)),
          Wrap(children: [
            opt('Sim', look.highlight, look.copyWith(highlight: true)),
            opt('Não', !look.highlight, look.copyWith(highlight: false)),
          ]),
          if (look.highlight) ...[
            const SizedBox(height: 6),
            Text('Destaque fora do tempo da voz? ${_syncLabel(look.syncMs)}', style: const TextStyle(fontSize: 12.5, color: Xp.blueText)),
            Wrap(children: [
              opt('◀ Atrasar', false, look.copyWith(syncMs: (look.syncMs - 250).clamp(-3000, 3000))),
              opt('Normal', look.syncMs == 0, look.copyWith(syncMs: 0)),
              opt('Adiantar ▶', false, look.copyWith(syncMs: (look.syncMs + 250).clamp(-3000, 3000))),
            ]),
          ],
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      );
    }),
  );
}

// ---------------------------------------------------------------------------
// Páginas

/// Pedaço de um parágrafo numa página ([start]..[end] em letras).
class PageSeg {
  final int para;
  final int start;
  final int end;
  const PageSeg(this.para, this.start, this.end);
}

class BookPage {
  final int chapter;
  final int index;
  final List<PageSeg> segs;

  /// Letras do capítulo antes desta página (para achar a página pela fração lida).
  final int charStart;

  /// Prancha (página inteira com a pintura de uma cena): a chave da ilustração. Null = página de texto.
  final int? plate;

  /// Página da pintura (começo do capítulo ou prancha) com uma frase só: a pintura ocupa o resto da página.
  final bool spotlight;
  const BookPage(this.chapter, this.index, this.segs, this.charStart, {this.plate, this.spotlight = false});
  bool get first => index == 0;
}

/// Medidas usadas para dividir em páginas (mudou alguma, divide de novo).
class PageSpec {
  final Size size;
  final TextStyle body;
  final TextStyle title;
  final EdgeInsets padding;

  /// Espaço da ilustração no topo da 1ª página do capítulo (0 = sem).
  final double artHeight;

  /// Tamanho de letra do Android (Configurações > Tela > Tamanho da fonte). As páginas são medidas com ele,
  /// igual ao texto desenhado; sem isso, com a letra do celular maior, o texto passava do fim da página.
  final TextScaler scaler;

  /// Deixa uma linha livre no pé da página: a frase destacada fica em negrito e itálico (letras mais largas)
  /// e pode empurrar uma palavra para a linha de baixo; com a folga, nada sai cortado.
  final bool reserveLine;
  const PageSpec(
      {required this.size,
      required this.body,
      required this.title,
      required this.padding,
      this.artHeight = 0,
      this.scaler = TextScaler.noScaling,
      this.reserveLine = false});

  double get width => size.width - padding.horizontal;
  // 2 px de folga para arredondamentos entre a medida e o desenho
  double get height => size.height - padding.vertical - footer - 2 - (reserveLine ? lineHeight : 0);
  double get lineHeight => scaler.scale(body.fontSize ?? 14) * (body.height ?? 1.2);
  double get footer => (body.fontSize ?? 14) * 1.4;
  double get gap => (body.fontSize ?? 14) * .45;

  @override
  bool operator ==(Object other) =>
      other is PageSpec &&
      other.size == size &&
      other.body == body &&
      other.title == title &&
      other.padding == padding &&
      other.artHeight == artHeight &&
      other.scaler == scaler &&
      other.reserveLine == reserveLine;
  @override
  int get hashCode => Object.hash(size, body, title, padding, artHeight, scaler, reserveLine);
}

const _indent = '  ';

/// Divide um capítulo em páginas que cabem na tela, sem cortar no meio de uma linha.
/// [plates]: pranchas das cenas, (parágrafo antes do qual entra, chave da ilustração).
List<BookPage> paginate(int chapterIndex, BookChapter ch, PageSpec spec, {bool hasArt = false, List<(int, int)> plates = const []}) {
  final pages = <BookPage>[];
  final w = spec.width, h = spec.height;
  if (w <= 20 || h <= 20) return [BookPage(chapterIndex, 0, const [], 0)];
  var segs = <PageSeg>[];
  var used = 0.0;
  var chars = 0, pageStart = 0;
  // cabeçalho da 1ª página: título do capítulo e ilustração
  if (ch.title.isNotEmpty) {
    final tp = TextPainter(text: TextSpan(text: ch.title, style: spec.title), textDirection: TextDirection.ltr, textAlign: TextAlign.center, textScaler: spec.scaler)
      ..layout(maxWidth: w);
    used += tp.height + spec.gap * 2;
    tp.dispose();
  }
  final header = used;
  void newPage() {
    pages.add(BookPage(chapterIndex, pages.length, segs, pageStart));
    segs = <PageSeg>[];
    used = 0;
    pageStart = chars;
  }

  // fim da 1ª frase do parágrafo (até a vírgula ou o ponto) e a altura dela
  int firstPieceEnd(int i) {
    final text = ch.paragraphs[i];
    final starts = ch.hasSentences && ch.sentences[i].length >= 4 ? [for (var j = 0; j < ch.sentences[i].length; j += 2) ch.sentences[i][j]] : pieceStarts(text);
    return starts.length > 1 ? starts[1] : text.length;
  }

  double heightOf(int i, int end) {
    final tp = TextPainter(
        text: TextSpan(text: _indent + ch.paragraphs[i].substring(0, end), style: spec.body),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.justify,
        textScaler: spec.scaler)
      ..layout(maxWidth: w);
    final out = tp.height;
    tp.dispose();
    return out;
  }

  // pintura do começo do capítulo com uma frase só (a pintura fica grande); frase longa demais: pintura menor
  // e o texto segue na mesma página, como antes
  var firstStart = 0;
  if (hasArt && ch.paragraphs.isNotEmpty) {
    final end = firstPieceEnd(0);
    if (heightOf(0, end) <= (h - header) * .4) {
      segs.add(PageSeg(0, 0, end));
      chars += end;
      pages.add(BookPage(chapterIndex, 0, segs, 0, spotlight: true));
      segs = <PageSeg>[];
      used = 0;
      pageStart = chars;
      firstStart = end;
    } else {
      used += spec.artHeight + spec.gap;
    }
  }

  for (var i = 0; i < ch.paragraphs.length; i++) {
    final text = ch.paragraphs[i];
    var start = i == 0 ? firstStart : 0;
    // prancha da cena antes deste parágrafo: página com a pintura e a 1ª frase do parágrafo; o resto segue na
    // página seguinte
    for (final (para, key) in plates) {
      if (para != i || i == 0) continue;
      if (segs.isNotEmpty) newPage();
      final end = firstPieceEnd(i);
      final one = heightOf(i, end) <= h * .3 ? [PageSeg(i, 0, end)] : const <PageSeg>[];
      pages.add(BookPage(chapterIndex, pages.length, one, chars, plate: key, spotlight: one.isNotEmpty));
      if (one.isNotEmpty) {
        chars += end;
        start = end;
      }
      used = 0;
      pageStart = chars;
    }
    while (start < text.length && start > 0 && text[start] == ' ') {
      start++;
    }
    while (start < text.length) {
      final piece = (start == 0 ? _indent : '') + text.substring(start);
      final tp = TextPainter(text: TextSpan(text: piece, style: spec.body), textDirection: TextDirection.ltr, textAlign: TextAlign.justify, textScaler: spec.scaler)
        ..layout(maxWidth: w);
      final room = h - used;
      if (tp.height <= room) {
        segs.add(PageSeg(i, start, text.length));
        used += tp.height + spec.gap;
        chars += text.length - start;
        tp.dispose();
        break;
      }
      // não cabe inteiro: quantas linhas cabem?
      final lines = tp.computeLineMetrics();
      var fit = 0;
      var y = 0.0;
      for (final l in lines) {
        if (y + l.height > room) break;
        y += l.height;
        fit++;
      }
      if (fit == 0) {
        tp.dispose();
        if (segs.isEmpty && used > 0) {
          // título e ilustração encheram a 1ª página: o texto começa na próxima (nunca some do fim da página)
          newPage();
          continue;
        }
        if (segs.isEmpty) {
          // nem uma linha cabe numa página vazia (tela minúscula): põe assim mesmo para não travar
          segs.add(PageSeg(i, start, text.length));
          chars += text.length - start;
          newPage();
          break;
        }
        newPage();
        continue;
      }
      final lastLine = lines[fit - 1];
      // baseline já é contada do topo do parágrafo (somar a altura das linhas de cima pulava para uma linha
      // mais embaixo, e o fim da página saía cortado)
      final pos = tp.getPositionForOffset(Offset(w - 1, lastLine.baseline - lastLine.ascent / 2));
      final endInPiece = tp.getLineBoundary(pos).end;
      tp.dispose();
      final prefix = start == 0 ? _indent.length : 0;
      var end = start + math.max<int>(1, endInPiece - prefix);
      if (end >= text.length) end = text.length;
      // com destaque: a página acaba no fim de um trecho (nenhum trecho fica dividido entre duas páginas, então
      // a página vira na hora exata em que o próximo trecho começa)
      if (spec.reserveLine && ch.hasSentences && end < text.length) {
        final f = ch.sentences[i];
        var cut = -1;
        for (var j = 0; j < f.length; j += 2) {
          if (f[j] > start && f[j] <= end) cut = f[j];
        }
        if (cut > start) {
          end = cut;
        } else if (start == 0 && segs.isNotEmpty) {
          // o 1º trecho do parágrafo não cabe nesta página: o parágrafo começa na próxima
          newPage();
          continue;
        }
        // trecho maior que a página inteira: corta onde der (a página vira pelo tempo das palavras)
      }
      segs.add(PageSeg(i, start, end));
      chars += end - start;
      start = end;
      while (start < text.length && text[start] == ' ') {
        start++;
      }
      newPage();
    }
  }
  if (segs.isNotEmpty || pages.isEmpty) newPage();
  return pages;
}

/// Página onde está a letra [char] do parágrafo [para] (null = não está em nenhuma).
int? pageForChar(List<BookPage> pages, int para, int char) {
  for (var i = 0; i < pages.length; i++) {
    for (final s in pages[i].segs) {
      if (s.para == para && char >= s.start && (char < s.end || (char == s.end && s.end == s.start))) return i;
    }
  }
  // letra num espaço entre dois pedaços (o corte da página pula espaços): a página seguinte
  for (var i = 0; i < pages.length; i++) {
    for (final s in pages[i].segs) {
      if (s.para == para && s.start > char) return i;
    }
  }
  return null;
}

/// Página que contém a fração [fraction] (0..1) do capítulo.
int pageForFraction(List<BookPage> pages, int chapterChars, double fraction) {
  if (pages.isEmpty) return 0;
  final target = (fraction.clamp(0.0, 1.0) * chapterChars).floor();
  for (var i = pages.length - 1; i >= 0; i--) {
    if (pages[i].charStart <= target) return i;
  }
  return 0;
}

/// Desenha uma página.
class PageView extends StatelessWidget {
  final BookChapter chapter;
  final BookPage page;
  final PageSpec spec;
  final ReaderLook look;
  final File? art;
  final String footer;
  /// Frase destacada neste capítulo: parágrafo e letras [start, end).
  final ({int para, int start, int end})? highlight;

  /// Prancha: nome da cena e crédito da pintura.
  final String plateTitle;
  final String plateCredit;
  const PageView({
    super.key,
    required this.chapter,
    required this.page,
    required this.spec,
    required this.look,
    required this.footer,
    this.art,
    this.highlight,
    this.plateTitle = '',
    this.plateCredit = '',
  });

  /// Página inteira com a pintura da cena, o nome dela e o pintor (como as pranchas dos livros antigos).
  Widget _plate() => Container(
        color: look.background,
        padding: spec.padding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(spec.gap * 2),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(border: Border.all(color: look.faint.withValues(alpha: .7))),
                child: art == null
                    ? const SizedBox()
                    : Image.file(art!, fit: BoxFit.contain, cacheWidth: 1000, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox()),
              ),
            ),
          ),
          if (plateTitle.isNotEmpty)
            Text(plateTitle, textAlign: TextAlign.center, style: spec.body.copyWith(fontSize: (spec.body.fontSize ?? 14) * 1.05), textScaler: spec.scaler),
          // a frase lida junto com a pintura
          for (final s in page.segs) ...[
            SizedBox(height: spec.gap),
            Text.rich(_seg(s), textAlign: TextAlign.justify, style: spec.body, textScaler: spec.scaler),
          ],
          if (page.segs.isNotEmpty) SizedBox(height: spec.gap),
          if (plateCredit.isNotEmpty)
            Text(plateCredit,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: (spec.body.fontSize ?? 14) * .68, color: look.faint, decoration: TextDecoration.none)),
          SizedBox(
            height: spec.footer,
            child: Center(child: Text(footer, style: TextStyle(fontSize: (spec.body.fontSize ?? 14) * .7, color: look.faint, decoration: TextDecoration.none))),
          ),
        ]),
      );

  /// Texto de um pedaço de parágrafo, com a frase lida marcada: fundo, negrito e itálico (a linha de folga
  /// no pé da página segura as palavras que a frase mais larga empurra).
  InlineSpan _seg(PageSeg s) {
    final text = chapter.paragraphs[s.para];
    final indent = s.start == 0 ? _indent : '';
    final h = highlight;
    if (h == null || h.para != s.para || h.end <= s.start || h.start >= s.end) return TextSpan(text: indent + text.substring(s.start, s.end));
    final a = math.max(h.start, s.start), b = math.min(h.end, s.end);
    return TextSpan(children: [
      TextSpan(text: indent + text.substring(s.start, a)),
      TextSpan(text: text.substring(a, b), style: TextStyle(backgroundColor: look.mark, fontWeight: FontWeight.bold, fontStyle: FontStyle.italic)),
      TextSpan(text: text.substring(b, s.end)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (page.plate != null) return _plate();
    return Container(
      color: look.background,
      padding: spec.padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: ClipRect(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                // páginas de texto: o que sobrar de espaço fica dividido em cima e embaixo (texto centralizado)
                mainAxisAlignment: page.first ? MainAxisAlignment.start : MainAxisAlignment.center,
                children: [
              if (page.first && chapter.title.isNotEmpty) ...[
                SizedBox(height: spec.gap),
                Text(chapter.title, textAlign: TextAlign.center, style: spec.title, textScaler: spec.scaler),
                SizedBox(height: spec.gap),
              ],
              if (page.first && art != null && page.spotlight) ...[
                // pintura grande, com uma frase só embaixo
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(border: Border.all(color: look.faint.withValues(alpha: .6))),
                    child: Image.file(art!, fit: BoxFit.contain, cacheWidth: 1000, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox()),
                  ),
                ),
                SizedBox(height: spec.gap * 2),
              ] else if (page.first && art != null) ...[
                Container(
                  height: spec.artHeight,
                  decoration: BoxDecoration(border: Border.all(color: look.faint.withValues(alpha: .6))),
                  child: Image.file(art!, fit: BoxFit.cover, cacheWidth: 900, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox()),
                ),
                SizedBox(height: spec.gap),
              ],
              for (final s in page.segs) ...[
                Text.rich(
                  _seg(s),
                  textAlign: TextAlign.justify,
                  style: spec.body,
                  textScaler: spec.scaler,
                ),
                SizedBox(height: spec.gap),
              ],
            ]),
          ),
        ),
        SizedBox(
          height: spec.footer,
          child: Center(child: Text(footer, style: TextStyle(fontSize: (spec.body.fontSize ?? 14) * .7, color: look.faint, decoration: TextDecoration.none))),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Virar a página com a folha dobrando

/// Recorta o polígono do retângulo [r] do lado do semiplano em que (P - m)·d >= 0 (Sutherland–Hodgman).
List<Offset> clipHalfPlane(List<Offset> poly, Offset m, Offset d) {
  double side(Offset q) => (q.dx - m.dx) * d.dx + (q.dy - m.dy) * d.dy;
  final out = <Offset>[];
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    final sa = side(a), sb = side(b);
    if (sa >= 0) out.add(a);
    if ((sa >= 0) != (sb >= 0)) {
      final t = sa / (sa - sb);
      out.add(Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t));
    }
  }
  return out;
}

/// Reflexo de [q] na reta que passa por [m] com normal [d].
Offset reflect(Offset q, Offset m, Offset d) {
  final len2 = d.dx * d.dx + d.dy * d.dy;
  if (len2 == 0) return q;
  final k = 2 * ((q.dx - m.dx) * d.dx + (q.dy - m.dy) * d.dy) / len2;
  return Offset(q.dx - k * d.dx, q.dy - k * d.dy);
}

/// Geometria da dobra: o canto [corner] da folha foi puxado até [touch].
class Curl {
  final Size size;
  final Offset corner;
  final Offset touch;
  const Curl(this.size, this.corner, this.touch);

  Offset get mid => Offset((corner.dx + touch.dx) / 2, (corner.dy + touch.dy) / 2);
  Offset get dir => touch - corner;
  List<Offset> get rect => [Offset.zero, Offset(size.width, 0), Offset(size.width, size.height), Offset(0, size.height)];

  /// Parte da folha que continua deitada (do lado do dedo).
  List<Offset> get flat => dir.distanceSquared < 1 ? rect : clipHalfPlane(rect, mid, dir);

  /// Parte levantada, já virada por cima (o verso da folha).
  List<Offset> get flap {
    if (dir.distanceSquared < 1) return const [];
    final lifted = clipHalfPlane(rect, mid, -dir);
    return [for (final q in lifted) reflect(q, mid, dir)];
  }
}

Path _path(List<Offset> pts) {
  final p = Path();
  if (pts.isEmpty) return p;
  p.moveTo(pts.first.dx, pts.first.dy);
  for (final q in pts.skip(1)) {
    p.lineTo(q.dx, q.dy);
  }
  return p..close();
}

class _FlatClipper extends CustomClipper<Path> {
  final Curl? curl;
  _FlatClipper(this.curl);
  @override
  Path getClip(Size size) => curl == null ? (Path()..addRect(Offset.zero & size)) : _path(Curl(size, curl!.corner, curl!.touch).flat);
  @override
  bool shouldReclip(_FlatClipper old) => old.curl?.touch != curl?.touch || old.curl?.corner != curl?.corner;
}

class _FlapPainter extends CustomPainter {
  final Curl? curl;
  final Color back;
  _FlapPainter(this.curl, this.back);

  @override
  void paint(Canvas canvas, Size size) {
    final c = curl;
    if (c == null || c.dir.distanceSquared < 1) return;
    final g = Curl(size, c.corner, c.touch);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final flat = _path(g.flat);
    final flap = _path(g.flap);
    // sombra da folha levantada sobre a página de baixo
    final d = g.dir / g.dir.distance;
    final shadowW = math.min(40.0, g.dir.distance / 3);
    final m = g.mid;
    final under = Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), flat);
    canvas.save();
    canvas.clipPath(under);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(m, m - d * shadowW, const [Color(0x55000000), Color(0x00000000)]),
    );
    canvas.restore();
    // verso da folha, com brilho perto da dobra
    canvas.drawShadow(flap, Colors.black, 4, false);
    canvas.drawPath(flap, Paint()..color = back);
    canvas.drawPath(
      flap,
      Paint()
        ..shader = ui.Gradient.linear(
          m,
          m + d * math.max(30.0, g.dir.distance / 2),
          [Colors.black.withValues(alpha: .18), Colors.white.withValues(alpha: .25), Colors.black.withValues(alpha: .05)],
          const [0, .35, 1],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlapPainter old) => old.curl?.touch != curl?.touch || old.back != back;
}

/// Folheador: mostra uma página e vira com a folha dobrando (arrastando o dedo, tocando nas beiradas
/// ou sozinho quando a narração avança). [pageAt] desenha a página de número [n] (null = não existe).
class CurlPager extends StatefulWidget {
  final int page;
  final Widget? Function(int n) pageAt;
  final void Function(int n, {required bool byUser}) onPage;
  final Color back;
  const CurlPager({super.key, required this.page, required this.pageAt, required this.onPage, required this.back});

  @override
  State<CurlPager> createState() => CurlPagerState();
}

class CurlPagerState extends State<CurlPager> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Curl? _curl;

  /// Virando para a frente (a atual sai) ou para trás (a anterior volta por cima).
  bool _forward = true;
  Offset _from = Offset.zero, _to = Offset.zero, _start = Offset.zero;
  Size _size = Size.zero;
  bool _dragging = false;
  bool? _dragForward;
  bool _byUser = false;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Offset get _cornerFwd => Offset(_size.width, _size.height);

  /// Vira uma página para a frente/trás com a animação (usado também pelo "virar sozinho").
  Future<void> turn({required bool forward, bool byUser = true}) async {
    if (_anim.isAnimating || _dragging || _size == Size.zero) return;
    if (widget.pageAt(widget.page + (forward ? 1 : -1)) == null) return;
    _forward = forward;
    _byUser = byUser;
    final h = _size.height, w = _size.width;
    // para a frente: o canto de baixo sai da direita e vai até a esquerda; para trás, o caminho inverso
    _from = forward ? Offset(w - 1, h - 1) : Offset(-w, h);
    _to = forward ? Offset(-w, h) : Offset(w, h);
    await _run(complete: true, curve: Curves.easeInOut);
  }

  Future<void> _run({required bool complete, Curve curve = Curves.easeOut}) async {
    _anim.value = 0;
    void tick() {
      final t = curve.transform(_anim.value);
      setState(() => _curl = Curl(_size, _cornerFwd, Offset.lerp(_from, _to, t)!));
    }

    _anim.addListener(tick);
    try {
      await _anim.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    } finally {
      _anim.removeListener(tick);
    }
    final landed = complete;
    setState(() => _curl = null);
    if (landed) widget.onPage(widget.page + (_forward ? 1 : -1), byUser: _byUser);
  }

  void _dragStart(DragStartDetails d) {
    if (_anim.isAnimating) return;
    _dragging = true;
    _dragForward = null;
    _start = d.localPosition;
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final dx = d.localPosition.dx - _start.dx;
    if (_dragForward == null) {
      if (dx.abs() < 6) return;
      _dragForward = dx < 0;
      if (widget.pageAt(widget.page + (_dragForward! ? 1 : -1)) == null) {
        _dragging = false;
        return;
      }
    }
    final w = _size.width, h = _size.height;
    final lift = ((d.localPosition.dy - _start.dy) * .4).clamp(-h * .3, h * .1);
    final x = _dragForward! ? (w + dx * 1.6).clamp(-w, w - 1) : (-w + dx * 1.6).clamp(-w, w - 1);
    setState(() => _curl = Curl(_size, _cornerFwd, Offset(x.toDouble(), h + lift)));
  }

  void _dragEnd(DragEndDetails d) {
    if (!_dragging || _dragForward == null || _curl == null) {
      _dragging = false;
      return;
    }
    _dragging = false;
    final fwd = _dragForward!;
    final v = d.velocity.pixelsPerSecond.dx;
    final x = _curl!.touch.dx;
    final done = fwd ? (x < 0 || v < -500) : (x > 0 || v > 500);
    _forward = fwd;
    _byUser = true;
    final w = _size.width, h = _size.height;
    _from = _curl!.touch;
    if (done) {
      _to = fwd ? Offset(-w, h) : Offset(w, h);
      _run(complete: true);
    } else {
      // desistiu: a folha volta para onde estava
      _to = fwd ? Offset(w - 1, h - 1) : Offset(-w, h);
      _anim.value = 0;
      void tick() => setState(() => _curl = Curl(_size, _cornerFwd, Offset.lerp(_from, _to, Curves.easeOut.transform(_anim.value))!));
      _anim.addListener(tick);
      _anim.forward(from: 0).whenComplete(() {
        _anim.removeListener(tick);
        if (mounted) setState(() => _curl = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      final cur = widget.pageAt(widget.page) ?? const SizedBox();
      final curling = _curl != null;
      // para a frente: em cima a atual (dobrando), embaixo a próxima. Para trás: em cima a anterior.
      final top = curling && !_forward ? (widget.pageAt(widget.page - 1) ?? cur) : cur;
      final under = curling ? (_forward ? widget.pageAt(widget.page + 1) : cur) : null;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _dragStart,
        onHorizontalDragUpdate: _dragUpdate,
        onHorizontalDragEnd: _dragEnd,
        onTapUp: (d) {
          final x = d.localPosition.dx;
          if (x > _size.width * .7) unawaited(turn(forward: true));
          if (x < _size.width * .3) unawaited(turn(forward: false));
        },
        child: Stack(fit: StackFit.expand, children: [
          ?under,
          ClipPath(clipper: _FlatClipper(_curl), child: top),
          if (curling) IgnorePointer(child: CustomPaint(painter: _FlapPainter(_curl, widget.back))),
        ]),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// O leitor (compacto no lugar dos GIFs, ou em tela cheia)

/// Leitor do livro que está tocando. Segue a narração sozinho (vira a página quando a estimativa passa);
/// folhear à mão para de seguir até tocar em "↩ Voltar para onde está lendo".
class BookReader extends StatefulWidget {
  final Track track;
  final bool compact;
  const BookReader({super.key, required this.track, this.compact = false});

  @override
  State<BookReader> createState() => _BookReaderState();
}

class _BookReaderState extends State<BookReader> {
  BookText? _text;
  bool _loading = true;
  int _chapter = 0;
  int _page = 0;
  bool _following = true;
  StreamSubscription<Duration>? _sub;
  final _pager = GlobalKey<CurlPagerState>();
  final Map<int, List<BookPage>> _pages = {};
  PageSpec? _spec;
  List<int> _match = const [];
  BookInfo? _matchedFor;
  DateTime _lastFollow = DateTime(2000);
  int _artCount = -1;

  /// Seguindo a narração, a prancha fica uns segundos na tela antes de virar.
  DateTime _plateUntil = DateTime(2000);

  late final BookService _books = context.read<AppState>().bookService;

  @override
  void initState() {
    super.initState();
    _books.addListener(_onBooks);
    _load();
  }

  /// O texto mudou (a transcrição ganhou mais um pedaço arrumado pelo Gemini): troca sem perder o lugar.
  void _onBooks() {
    if (!mounted || _loading) return;
    // chegou ilustração nova: as pranchas mudam as páginas
    final artCount = _books.infoFor(widget.track.path)?.art.length ?? 0;
    if (artCount != _artCount) {
      _artCount = artCount;
      if (_spec != null) {
        setState(() => _pages.clear());
        if (_following) _follow(context.read<PlayerService>().player.position, jump: true);
      }
    }
    final t = _books.textIfLoaded(widget.track.path);
    if (t == null || identical(t, _text)) return;
    setState(() {
      _text = t;
      _pages.clear();
      _matchedFor = null;
      if (_chapter >= t.chapters.length) {
        _chapter = 0;
        _page = 0;
      }
      if (_spec != null) _page = _page.clamp(0, math.max(0, _pagesOf(_chapter).length - 1));
    });
    if (_following) _follow(context.read<PlayerService>().player.position, jump: true);
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    final t = await app.bookService.loadText(widget.track.path);
    if (!mounted) return;
    setState(() {
      _text = t;
      _loading = false;
    });
    final ps = context.read<PlayerService>();
    _sub = ps.player.positionStream.listen((pos) {
      _mark(pos);
      _follow(pos);
    });
    _mark(ps.player.position);
    _follow(ps.player.position, jump: true);
  }

  /// Frase sendo lida agora (null = sem destaque).
  ({int chapter, int para, int start, int end})? _hl;

  ({int chapter, int para, int start, int end})? _sentence(Duration pos) {
    final text = _text;
    if (text == null || !mounted) return null;
    final app = context.read<AppState>();
    final look = ReaderLook.of(app);
    if (!look.highlight || context.read<PlayerService>().current?.id != widget.track.id) return null;
    return sentenceAt(text, pos.inMilliseconds + look.syncMs);
  }

  void _mark(Duration pos) {
    if (!mounted) return;
    final s = _sentence(pos);
    if (s == _hl) return;
    setState(() => _hl = s);
  }

  @override
  void didUpdateWidget(BookReader old) {
    super.didUpdateWidget(old);
    if (old.track.path != widget.track.path) {
      _sub?.cancel();
      _pages.clear();
      _loading = true;
      _load();
    }
  }

  @override
  void dispose() {
    _books.removeListener(_onBooks);
    _sub?.cancel();
    super.dispose();
  }

  BookInfo get _info => context.read<AppState>().bookInfoOf(widget.track);

  List<int> _matchNow() {
    final info = _info;
    if (!identical(info, _matchedFor)) {
      _matchedFor = info;
      _match = _text == null ? const [] : matchChapters(info.chapters, _text!.chapters);
    }
    return _match;
  }

  /// Onde a narração está, em (capítulo do texto, página).
  (int, int)? _target(Duration pos) {
    final text = _text, spec = _spec;
    if (text == null || spec == null || text.chapters.isEmpty) return null;
    final ps = context.read<PlayerService>();
    if (ps.current?.id != widget.track.id) return null;
    final total = ps.player.duration ?? Duration(milliseconds: widget.track.durationMs);
    // com a frase exata (transcrição com tempos): a página da palavra que está sendo lida. Frase dividida entre
    // duas páginas vira no meio, quando a narração chega na parte de baixo (não espera a frase acabar).
    final s = readingAt(text, pos.inMilliseconds + ReaderLook.of(context.read<AppState>()).syncMs);
    if (s != null) {
      final pg = pageForChar(_pagesOf(s.chapter), s.para, s.char);
      if (pg != null) return (s.chapter, pg);
    }
    final at = textPosition(text: text, audio: _info.chapters, match: _matchNow(), pos: pos, total: total);
    final pages = _pagesOf(at.chapter);
    return (at.chapter, pageForFraction(pages, text.chapters[at.chapter].length, at.fraction));
  }

  void _follow(Duration pos, {bool jump = false}) {
    if (!mounted || (!_following && !jump)) return;
    final now = DateTime.now();
    if (!jump && now.difference(_lastFollow).inMilliseconds < 400) return;
    _lastFollow = now;
    final t = _target(pos);
    if (t == null) return;
    final (c, pg) = t;
    if (c == _chapter && pg == _page) return;
    final cur = _globalIndex(_chapter, _page), dest = _globalIndex(c, pg);
    if (!jump && now.isBefore(_plateUntil)) return; // mostrando a prancha
    final pages = _pagesOf(_chapter);
    final plateNext = c == _chapter && _page + 1 < pages.length && pages[_page + 1].plate != null;
    if (!jump && (dest == cur + 1 || (dest == cur + 2 && plateNext))) {
      if (plateNext) _plateUntil = now.add(const Duration(seconds: 7));
      unawaited(_pager.currentState?.turn(forward: true, byUser: false));
    } else {
      setState(() {
        _chapter = c;
        _page = pg;
      });
    }
  }

  // Número "global" da página: capítulos antes contam como 1000 páginas cada (só para comparar vizinhas).
  int _globalIndex(int chapter, int page) => chapter * 100000 + page;

  List<BookPage> _pagesOf(int chapter) {
    final spec = _spec!;
    return _pages.putIfAbsent(chapter, () => paginate(chapter, _text!.chapters[chapter], spec, hasArt: _artFor(chapter) != null, plates: _platesFor(chapter)));
  }

  /// Pranchas das cenas que caem neste capítulo do texto: (parágrafo, chave da ilustração).
  List<(int, int)> _platesFor(int chapter) {
    final text = _text;
    if (text == null || !text.timed) return const [];
    final app = context.read<AppState>();
    final out = <(int, int)>[];
    for (final e in _info.scenes.entries) {
      if (app.bookService.artFile(widget.track.path, e.key) == null) continue;
      final at = sentenceAt(text, e.value.$1);
      if (at == null || at.chapter != chapter) continue;
      // a prancha entra antes do parágrafo seguinte ao da cena (não corta a frase no meio)
      final para = at.para + 1;
      if (para > 0 && para < text.chapters[chapter].paragraphs.length) out.add((para, e.key));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  File? _artFor(int textChapter) {
    final app = context.read<AppState>();
    final info = _info;
    var audioIndex = textChapter;
    if (info.chapters.isNotEmpty) {
      final m = _matchNow();
      audioIndex = m.indexOf(textChapter);
      if (audioIndex < 0) return null;
    }
    return app.bookService.artFile(widget.track.path, audioIndex);
  }

  /// Página n relativa à atual (n = página dentro de [_chapter]; fora do intervalo passa para o capítulo vizinho).
  (int, int)? _resolve(int n) {
    final text = _text!;
    var c = _chapter, pg = n;
    var pages = _pagesOf(c);
    while (pg >= pages.length) {
      pg -= pages.length;
      c++;
      if (c >= text.chapters.length) return null;
      pages = _pagesOf(c);
    }
    while (pg < 0) {
      c--;
      if (c < 0) return null;
      pages = _pagesOf(c);
      pg += pages.length;
    }
    return (c, pg);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    context.watch<PlayerService>();
    final look = ReaderLook.of(app);
    return ListenableBuilder(
      listenable: app.bookService,
      builder: (context, _) {
        if (_loading) return _frame(look, Center(child: Text('Abrindo o livro…', style: TextStyle(color: look.faint))));
        final text = _text;
        if (text == null || text.isEmpty) return _frame(look, _noText(app, look));
        return LayoutBuilder(builder: (context, box) {
          final compact = widget.compact;
          final fs = look.fontSize(compact: compact);
          final spec = PageSpec(
            size: box.biggest,
            body: TextStyle(fontSize: fs, height: 1.45, color: look.ink, fontFamily: look.family, decoration: TextDecoration.none),
            title: TextStyle(fontSize: fs * .85, letterSpacing: 1.2, color: look.faint, fontFamily: look.family, fontWeight: FontWeight.w600, decoration: TextDecoration.none),
            padding: compact ? const EdgeInsets.fromLTRB(14, 8, 14, 2) : const EdgeInsets.fromLTRB(22, 14, 22, 4),
            artHeight: box.biggest.height * (compact ? .34 : .36),
            scaler: MediaQuery.textScalerOf(context),
            reserveLine: look.highlight && text.timed,
          );
          if (spec != _spec) {
            final hadSpec = _spec != null;
            _spec = spec;
            _pages.clear();
            if (_following || !hadSpec) {
              final t = _target(context.read<PlayerService>().player.position);
              if (t != null) {
                _chapter = t.$1;
                _page = t.$2;
              }
            }
          }
          _chapter = _chapter.clamp(0, text.chapters.length - 1);
          _page = _page.clamp(0, _pagesOf(_chapter).length - 1);
          return Stack(children: [
            Positioned.fill(
              child: CurlPager(
                key: _pager,
                page: _page,
                back: look.back,
                pageAt: (n) {
                  final r = _resolve(n);
                  if (r == null) return null;
                  final (c, pg) = r;
                  final pages = _pagesOf(c);
                  return PageView(
                    key: ValueKey('$c/$pg'),
                    chapter: text.chapters[c],
                    page: pages[pg],
                    spec: spec,
                    look: look,
                    art: pages[pg].plate != null
                        ? context.read<AppState>().bookService.artFile(widget.track.path, pages[pg].plate!)
                        : (pg == 0 ? _artFor(c) : null),
                    highlight: _hl != null && _hl!.chapter == c ? (para: _hl!.para, start: _hl!.start, end: _hl!.end) : null,
                    plateTitle: pages[pg].plate == null ? '' : (_info.scenes[pages[pg].plate]?.$2 ?? ''),
                    plateCredit: pages[pg].plate == null ? '' : (_info.artCredit[pages[pg].plate] ?? ''),
                    footer: 'pág. ${pg + 1} de ${pages.length} · cap. ${c + 1} de ${text.chapters.length}',
                  );
                },
                onPage: (n, {required byUser}) {
                  final r = _resolve(n);
                  if (r == null) return;
                  setState(() {
                    _chapter = r.$1;
                    _page = r.$2;
                    if (byUser) {
                      // folheou à mão: para de seguir, a menos que tenha caído justo onde a narração está
                      final t = _target(context.read<PlayerService>().player.position);
                      _following = t != null && t.$1 == _chapter && t.$2 == _page;
                    }
                  });
                },
              ),
            ),
            if (!_following)
              Positioned(
                left: 0,
                right: 0,
                bottom: spec.footer + 4,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _following = true);
                      _follow(context.read<PlayerService>().player.position, jump: true);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFFE1),
                        border: Border.all(color: Colors.black),
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: const [BoxShadow(color: Color(0x55000000), offset: Offset(2, 2), blurRadius: 3)],
                      ),
                      child: const Text('↩ Voltar para onde está lendo', style: TextStyle(fontSize: 12.5, color: Colors.black)),
                    ),
                  ),
                ),
              ),
            if (compact)
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: () => openFullReader(context, widget.track),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Xp.linkBlue, borderRadius: BorderRadius.circular(3)),
                    child: const Icon(Icons.open_in_full, size: 16, color: Colors.white),
                  ),
                ),
              ),
          ]);
        });
      },
    );
  }

  Widget _frame(ReaderLook look, Widget child) => Container(color: look.background, child: child);

  /// Sem texto da obra: capa e ilustrações alternando (como os GIFs), e o que está acontecendo com o texto.
  Widget _noText(AppState app, ReaderLook look) {
    final info = _info;
    final status = switch (info.textStatus) {
      TextStatus.searching => 'Procurando o texto da obra…',
      TextStatus.notFound => 'Não achei o texto em domínio público.\nDá para anexar um EPUB na tela do livro.',
      TextStatus.failed => 'Não deu para baixar o texto agora.',
      _ => 'Sem o texto da obra ainda.',
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        XpIcon(XpIcons.book, size: widget.compact ? 48 : 72),
        const SizedBox(height: 10),
        Text(status, textAlign: TextAlign.center, style: TextStyle(color: look.ink, fontSize: 13.5)),
      ]),
    );
  }
}

/// Abre o leitor em tela cheia (⤢ ou celular deitado).
Future<void> openFullReader(BuildContext context, Track t) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FullReaderScreen(trackId: t.id!)));

/// Leitor em tela cheia com o mini-player embaixo.
class FullReaderScreen extends StatelessWidget {
  final int trackId;
  const FullReaderScreen({super.key, required this.trackId});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ps = context.watch<PlayerService>();
    final t = app.byId(trackId);
    if (t == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.maybePop(context));
      return const SizedBox();
    }
    final info = app.bookInfoOf(t);
    final playing = ps.current?.id == t.id;
    return Scaffold(
      backgroundColor: Xp.beige,
      body: SafeArea(
        child: Column(children: [
          XpTitleBar(title: info.title.isEmpty ? t.title : info.title, icon: XpIcons.book, actions: [
            XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context)),
          ]),
          Expanded(child: BookReader(track: t)),
          // mini-player
          Container(
            decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF2C5AA8), Color(0xFF0C2A66)], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: StreamBuilder<Duration>(
              stream: ps.player.positionStream,
              builder: (context, snap) {
                final pos = snap.data ?? Duration.zero;
                final i = info.chapterIndexAt(pos);
                return Row(children: [
                  IconButton(
                    icon: Icon(playing && ps.playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
                    onPressed: playing ? ps.togglePlay : () => ps.playBook(t),
                  ),
                  Expanded(
                    child: Text(
                      [if (i >= 0) 'Cap. ${i + 1}', if (playing) '${formatClock(pos)} / ${formatClock(ps.player.duration ?? Duration.zero)}'].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.replay_10, color: Colors.white), onPressed: playing ? () => ps.seekBy(const Duration(seconds: -10)) : null),
                  IconButton(icon: const Icon(Icons.forward_30, color: Colors.white), onPressed: playing ? () => ps.seekBy(const Duration(seconds: 30)) : null),
                  TextButton(
                    onPressed: ps.cyclePodcastSpeed,
                    child: Text('${ps.podcastSpeed}x'.replaceAll('.0x', 'x').replaceAll('.', ','), style: const TextStyle(color: Colors.white)),
                  ),
                ]);
              },
            ),
          ),
          GestureDetector(
            onTap: () => showReaderLook(context),
            child: const XpStatusBar(['Aa  Aparência', 'Leitor']),
          ),
        ]),
      ),
    );
  }
}
