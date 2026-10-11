import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:klk_native/klk_native.dart';

enum _Shape { square, circle, free }

/// Editor de stickers (como en WhatsApp): quitar el fondo (iPhone), forma,
/// borde blanco y texto. Devuelve el PNG de 512×512 con fondo transparente.
class StickerEditor extends StatefulWidget {
  final String imagePath;
  const StickerEditor({super.key, required this.imagePath});

  @override
  State<StickerEditor> createState() => _StickerEditorState();
}

class _StickerEditorState extends State<StickerEditor> {
  final _boundary = GlobalKey();
  final _zoom = TransformationController();
  late String _path = widget.imagePath;
  bool _lifted = false;
  bool _cutting = false;
  bool _saving = false;
  _Shape _shape = _Shape.square;
  bool _outline = true;
  String _text = '';
  Color _textColor = Colors.white;
  bool _textTop = false;

  static const _colors = [Colors.white, Color(0xFFFFD60A), Color(0xFFCE1126), Color(0xFF002D62), Colors.black];

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _cut() async {
    if (_lifted) {
      setState(() {
        _path = widget.imagePath;
        _lifted = false;
        _shape = _Shape.square;
      });
      return;
    }
    setState(() => _cutting = true);
    try {
      final out = await KlkNative.liftSubject(widget.imagePath);
      if (!mounted) return;
      setState(() {
        _path = out;
        _lifted = true;
        _shape = _Shape.free;
        _zoom.value = Matrix4.identity();
      });
    } on KlkNativeException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _cutting = false);
    }
  }

  Future<void> _editText() async {
    final ctrl = TextEditingController(text: _text);
    final t = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Texto del sticker'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: '¡KLK!, ¡Tamo activo!…'),
        ),
        actions: [
          if (_text.isNotEmpty) TextButton(onPressed: () => Navigator.pop(d, ''), child: const Text('Quitar')),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Poner')),
        ],
      ),
    );
    ctrl.dispose();
    if (t != null) setState(() => _text = t.trim());
  }

  Future<void> _done() async {
    setState(() => _saving = true);
    try {
      // Deja que se pinte sin la marca de "seleccionado" antes de capturar.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final ro = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 512 / ro.size.width);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (!mounted || data == null) return;
      Navigator.pop<Uint8List>(context, data.buffer.asUint8List());
    } catch (_) {
      _snack('No se pudo crear el sticker');
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _image() {
    final file = Image.file(File(_path), fit: BoxFit.contain, gaplessPlayback: true);
    if (!_lifted || !_outline) return file;
    // Borde blanco alrededor de la figura recortada (8 copias desplazadas).
    const w = 7.0;
    const offs = [
      Offset(-w, 0), Offset(w, 0), Offset(0, -w), Offset(0, w),
      Offset(-w * .7, -w * .7), Offset(w * .7, -w * .7), Offset(-w * .7, w * .7), Offset(w * .7, w * .7),
    ];
    return Stack(fit: StackFit.expand, children: [
      for (final o in offs)
        Transform.translate(
          offset: o,
          child: Image.file(File(_path),
              fit: BoxFit.contain, color: Colors.white, colorBlendMode: BlendMode.srcIn, gaplessPlayback: true),
        ),
      file,
    ]);
  }

  Widget _sticker(double side) {
    Widget pic = InteractiveViewer(
      transformationController: _zoom,
      minScale: 0.4,
      maxScale: 6,
      boundaryMargin: EdgeInsets.all(side),
      clipBehavior: Clip.none,
      child: SizedBox(width: side, height: side, child: _image()),
    );
    switch (_shape) {
      case _Shape.square:
        pic = Container(
          decoration: BoxDecoration(
            border: _outline ? Border.all(color: Colors.white, width: side * 0.03) : null,
            borderRadius: BorderRadius.circular(side * 0.12),
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(side * 0.1), child: pic),
        );
      case _Shape.circle:
        pic = Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: _outline ? Border.all(color: Colors.white, width: side * 0.03) : null,
          ),
          child: ClipOval(child: pic),
        );
      case _Shape.free:
        pic = ClipRect(child: pic);
    }
    final fontSize = side * 0.13;
    return Stack(fit: StackFit.expand, children: [
      Padding(padding: EdgeInsets.all(side * 0.04), child: pic),
      if (_text.isNotEmpty)
        Align(
          alignment: _textTop ? const Alignment(0, -0.92) : const Alignment(0, 0.92),
          child: IgnorePointer(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: side * 0.05),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Stack(children: [
                  Text(_text,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic,
                        foreground: Paint()
                          ..style = PaintingStyle.stroke
                          ..strokeWidth = fontSize * 0.22
                          ..strokeJoin = StrokeJoin.round
                          ..color = _textColor == Colors.black ? Colors.white : Colors.black,
                      )),
                  Text(_text,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic,
                        color: _textColor,
                      )),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crear sticker'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving || _cutting ? null : _done,
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Listo'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: LayoutBuilder(builder: (context, c) {
                    final side = c.maxWidth;
                    return Stack(fit: StackFit.expand, children: [
                      // Cuadritos para ver qué parte queda transparente (no sale en el sticker).
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CustomPaint(painter: _Checker(cs.brightness == Brightness.dark)),
                      ),
                      RepaintBoundary(key: _boundary, child: _sticker(side)),
                      if (_cutting)
                        const ColoredBox(
                          color: Color(0x66000000),
                          child: Center(child: CircularProgressIndicator(color: Colors.white)),
                        ),
                    ]);
                  }),
                ),
              ),
            ),
          ),
          Text('Mueve y pellizca la foto para encuadrarla',
              style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              if (KlkNative.supported)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    avatar: const Icon(Icons.content_cut, size: 18),
                    label: Text(_lifted ? 'Con fondo' : 'Quitar fondo'),
                    selected: _lifted,
                    onSelected: _cutting ? null : (_) => _cut(),
                  ),
                ),
              for (final (shape, label, icon) in [
                (_Shape.square, 'Cuadrado', Icons.crop_square),
                (_Shape.circle, 'Círculo', Icons.circle_outlined),
                if (_lifted) (_Shape.free, 'Recortado', Icons.person_outline),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: Icon(icon, size: 18),
                    label: Text(label),
                    selected: _shape == shape,
                    onSelected: (_) => setState(() => _shape = shape),
                  ),
                ),
              FilterChip(
                label: const Text('Borde blanco'),
                selected: _outline,
                onSelected: (v) => setState(() => _outline = v),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(children: [
              OutlinedButton.icon(
                onPressed: _editText,
                icon: const Icon(Icons.text_fields),
                label: Text(_text.isEmpty ? 'Poner texto' : 'Cambiar texto'),
              ),
              if (_text.isNotEmpty) ...[
                IconButton(
                  tooltip: _textTop ? 'Texto abajo' : 'Texto arriba',
                  onPressed: () => setState(() => _textTop = !_textTop),
                  icon: Icon(_textTop ? Icons.vertical_align_bottom : Icons.vertical_align_top),
                ),
                const SizedBox(width: 4),
                for (final c in _colors)
                  GestureDetector(
                    onTap: () => setState(() => _textColor = c),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: _textColor == c ? cs.primary : cs.onSurface.withValues(alpha: 0.25),
                            width: _textColor == c ? 3 : 1),
                      ),
                    ),
                  ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Checker extends CustomPainter {
  final bool dark;
  _Checker(this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    const s = 16.0;
    final a = Paint()..color = dark ? const Color(0xFF2A3942) : const Color(0xFFE9EDEF);
    final b = Paint()..color = dark ? const Color(0xFF1F2C34) : const Color(0xFFFFFFFF);
    for (var y = 0.0; y < size.height; y += s) {
      for (var x = 0.0; x < size.width; x += s) {
        final even = ((x / s).floor() + (y / s).floor()).isEven;
        canvas.drawRect(Rect.fromLTWH(x, y, s, s), even ? a : b);
      }
    }
  }

  @override
  bool shouldRepaint(_Checker old) => old.dark != dark;
}
