import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import '../gif_fetcher.dart';
import '../models.dart';
import '../theme.dart';

/// Busca de GIFs na web dentro do app. Com "Modo salvar" ligado, tocar num GIF guarda na música.
class GifWebScreen extends StatefulWidget {
  final Track track;
  const GifWebScreen({super.key, required this.track});

  @override
  State<GifWebScreen> createState() => _GifWebScreenState();
}

class _Site {
  final String name;
  final Uri Function(String q) url;
  const _Site(this.name, this.url);
}

final _sites = [
  _Site('Google', (q) => Uri.https('www.google.com', '/search', {'tbm': 'isch', 'tbs': 'itp:animated', 'q': q})),
  _Site('Tenor', (q) => Uri.parse('https://tenor.com/search/${Uri.encodeComponent(q.replaceAll(' ', '-'))}-gifs')),
  _Site('GIPHY', (q) => Uri.parse('https://giphy.com/search/${Uri.encodeComponent(q.replaceAll(' ', '-'))}')),
  _Site('Pinterest', (q) => Uri.https('www.pinterest.com', '/search/pins/', {'q': q})),
];

/// Em modo salvar, intercepta o toque e manda para o app o endereço da imagem tocada.
const _saveModeJs = r'''
(function(){
  if (window.__pnInstalled) { window.__pnSave = SAVE; return; }
  window.__pnInstalled = true; window.__pnSave = SAVE;
  function srcOf(el){
    for (var n = el, i = 0; n && i < 6; n = n.parentElement, i++) {
      if (n.tagName === 'IMG') return n.currentSrc || n.src;
      if (n.tagName === 'VIDEO' && n.poster) return n.poster;
      var imgs = n.querySelectorAll ? n.querySelectorAll('img') : [];
      if (imgs.length === 1) return imgs[0].currentSrc || imgs[0].src;
    }
    return null;
  }
  document.addEventListener('click', function(e){
    if (!window.__pnSave) return;
    var s = srcOf(e.target);
    if (s) { e.preventDefault(); e.stopPropagation(); PN.postMessage(s); }
  }, true);
})();
''';

class _GifWebScreenState extends State<GifWebScreen> {
  late final WebViewController _web;
  late final TextEditingController _q;
  int _site = 0;
  bool _saveMode = false;
  int _saved = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _q = TextEditingController(text: app.gifFetcher.webQueryFor(widget.track));
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('PN', onMessageReceived: (m) => _save(m.message))
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) => _inject()));
    _open();
  }

  void _open() => _web.loadRequest(_sites[_site].url(_q.text.trim()));

  Future<void> _inject() => _web.runJavaScript(_saveModeJs.replaceAll('SAVE', '$_saveMode')).catchError((_) {});

  Future<void> _save(String src) async {
    if (_busy) return;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      List<int>? bytes;
      if (src.startsWith('data:')) {
        final comma = src.indexOf(',');
        if (comma > 0 && src.substring(0, comma).contains('base64')) bytes = base64Decode(src.substring(comma + 1));
      } else {
        final res = await http.get(Uri.parse(src), headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android) PlayerNostalgico'}).timeout(const Duration(seconds: 30));
        if (res.statusCode == 200 && res.bodyBytes.length <= 8 * 1024 * 1024) bytes = res.bodyBytes;
      }
      final (artistDir, titleDir) = GifFetcher.dirsFor(widget.track);
      final path = bytes == null
          ? null
          : await app.gifs.saveForTrack(widget.track, bytes, artistDir: artistDir, titleDir: titleDir, credit: src.startsWith('data:') ? 'web' : src);
      if (path == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Não deu para salvar essa imagem. Tente abrir o GIF maior e tocar de novo.')));
      } else {
        setState(() => _saved++);
        messenger.showSnackBar(SnackBar(content: Text(path.endsWith('.gif') || path.endsWith('.webp')
            ? 'GIF salvo na música ($_saved).'
            : 'Salvo, mas é uma imagem parada. Abra o GIF maior para pegar o animado.')));
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Falhou ao baixar. Confira a internet.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: XpBackground(
        child: SafeArea(
          child: Column(children: [
            XpTitleBar(title: 'Buscar GIFs na web', actions: [XpTitleButton(icon: Icons.close, tooltip: 'Fechar', onTap: () => Navigator.pop(context))]),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _open(),
                    decoration: const InputDecoration(isDense: true, filled: true, fillColor: Colors.white, border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 6),
                XpButton(label: 'Buscar', icon: Icons.search, onTap: _open),
              ]),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (var i = 0; i < _sites.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(_sites[i].name),
                        selected: _site == i,
                        onSelected: (_) {
                          setState(() => _site = i);
                          _open();
                        },
                      ),
                    ),
                ],
              ),
            ),
            Material(
              color: _saveMode ? const Color(0xFFFFE680) : const Color(0xFFDDE7F7),
              child: SwitchListTile(
                dense: true,
                value: _saveMode,
                onChanged: (v) {
                  setState(() => _saveMode = v);
                  _inject();
                },
                title: Text(_saveMode ? 'Modo salvar LIGADO: toque num GIF para guardar' : 'Modo salvar desligado: navegue à vontade'),
                subtitle: Text('Salvos nesta música: $_saved${_busy ? ' · baixando...' : ''}'),
              ),
            ),
            Expanded(child: WebViewWidget(controller: _web)),
          ]),
        ),
      ),
    );
  }
}
