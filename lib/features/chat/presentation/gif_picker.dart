import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../core/l10n/l10n.dart';

/// Un GIF de KLIPY: la miniatura para la lista y el bueno para enviar.
class KlipyGif {
  final String id;
  final String preview;
  final String full;
  final double ratio; // ancho / alto
  const KlipyGif(this.id, this.preview, this.full, this.ratio);
}

/// Busca GIF en KLIPY (API compatible con la de Tenor). Las búsquedas salen
/// del móvil, como pide KLIPY.
class KlipyClient {
  KlipyClient(this.key);
  final String key;
  static const _base = 'https://api.klipy.com/v2';

  String get _locale {
    final l = currentLanguageCode();
    return l == 'en' ? 'en_US' : '${l}_ES';
  }

  Future<(List<KlipyGif>, String?)> fetch({String q = '', String? pos}) async {
    final params = {
      'key': key,
      'client_key': 'klk_messenger',
      'limit': '30',
      'contentfilter': 'medium',
      'media_filter': 'tinygif,mediumgif,gif',
      'locale': _locale,
      if (q.isNotEmpty) 'q': q,
      if (pos != null && pos.isNotEmpty) 'pos': pos,
    };
    final uri = Uri.parse('$_base/${q.isEmpty ? 'featured' : 'search'}').replace(queryParameters: params);
    final r = await http.get(uri).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('GIF ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final out = <KlipyGif>[];
    for (final it in (j['results'] as List? ?? const [])) {
      if (it is! Map) continue;
      final f = it['media_formats'];
      if (f is! Map) continue;
      String? url(String k) => (f[k] is Map) ? (f[k]['url'] as String?) : null;
      final small = url('tinygif') ?? url('mediumgif') ?? url('gif');
      final big = url('mediumgif') ?? url('gif') ?? small;
      if (small == null || big == null) continue;
      var ratio = 1.0;
      final dims = (f['tinygif'] is Map ? f['tinygif']['dims'] : null) as List?;
      if (dims != null && dims.length == 2) {
        final w = (dims[0] as num).toDouble(), h = (dims[1] as num).toDouble();
        if (w > 0 && h > 0) ratio = w / h;
      }
      out.add(KlipyGif('${it['id']}', small, big, ratio));
    }
    return (out, j['next']?.toString());
  }

  /// Baja el GIF elegido a un archivo temporal (para enviarlo cifrado como foto).
  static Future<String> download(KlipyGif g) async {
    final r = await http.get(Uri.parse(g.full)).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) throw Exception('GIF ${r.statusCode}');
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/klk_gif_${DateTime.now().millisecondsSinceEpoch}.gif');
    await f.writeAsBytes(r.bodyBytes);
    return f.path;
  }
}

/// Hoja con buscador de GIF. Devuelve el GIF elegido (o null).
Future<KlipyGif?> pickGif(BuildContext context, String key) => showModalBottomSheet<KlipyGif>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _GifPicker(client: KlipyClient(key)),
    );

const _quick = ['Jajaja', 'Wepa', 'Bailar', 'Gracias', 'Te quiero', 'Buenos días', 'Wow', 'Triste', 'Fiesta', 'Ok'];

class _GifPicker extends StatefulWidget {
  final KlipyClient client;
  const _GifPicker({required this.client});

  @override
  State<_GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<_GifPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final List<KlipyGif> _items = [];
  String? _next;
  bool _loading = false;
  String? _error;
  String _q = '';
  Timer? _debounce;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    if (!reset && (_next == null || _next!.isEmpty)) return;
    final my = ++_req;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _next = null;
      }
    });
    try {
      final (list, next) = await widget.client.fetch(q: _q, pos: reset ? null : _next);
      if (!mounted || my != _req) return;
      setState(() {
        _items.addAll(list);
        _next = next;
      });
    } catch (_) {
      if (mounted && my == _req) setState(() => _error = tr('No se pudieron cargar los GIF. Revisa tu conexión.'));
    } finally {
      if (mounted && my == _req) setState(() => _loading = false);
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _q = v.trim();
      _load(reset: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: TextField(
              controller: _search,
              onChanged: _onSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: tr('Buscar GIF'),
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _quick.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => ActionChip(
                label: Text(_quick[i]),
                onPressed: () {
                  _search.text = _quick[i];
                  _q = _quick[i];
                  _load(reset: true);
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _error != null && _items.isEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
                : _items.isEmpty && _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _items.isEmpty
                        ? Center(child: Text(tr('No hay GIF con esa búsqueda')))
                        : GridView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
                            itemCount: _items.length,
                            itemBuilder: (_, i) {
                              final g = _items[i];
                              return GestureDetector(
                                onTap: () => Navigator.pop(context, g),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: ColoredBox(
                                    color: cs.surfaceContainerHighest,
                                    child: Image.network(g.preview,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                        errorBuilder: (_, __, ___) => const Icon(Icons.gif_box_outlined)),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
          // Lo pide KLIPY: decir de dónde salen los GIF.
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 2),
            child: Text('Powered by KLIPY',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: cs.onSurface.withValues(alpha: 0.55))),
          ),
        ]),
      ),
    );
  }
}
