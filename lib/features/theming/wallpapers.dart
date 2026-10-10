import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/security/secure_store.dart';
import 'domain/klk_theme.dart';

/// Fondos de chat dominicanos, dibujados en el propio móvil (sin fotos de terceros).
///
/// Tipos de id:
/// - ilustración: 'malecon', 'samana', 'colonial'…
/// - patrón: 'klk', 'puntos', 'olas'
/// - color sólido: 'c:<índice>'  ·  degradado: 'g:<índice>'
/// - 'foto' (una foto de la galería, guardada solo en este móvil)
/// - 'ninguno'
class Wallpaper {
  final String id;
  final String name;
  const Wallpaper(this.id, this.name);
}

/// Ilustraciones dibujadas.
const wallpapers = [
  Wallpaper('malecon', 'Malecón al atardecer'),
  Wallpaper('samana', 'Playa de Samaná'),
  Wallpaper('pico', 'Pico Duarte'),
  Wallpaper('bandera', 'Bandera'),
  Wallpaper('colonial', 'Zona Colonial'),
  Wallpaper('noche', 'Noche en el campo'),
  Wallpaper('palmeras', 'Palmeras'),
  Wallpaper('constanza', 'Valle de Constanza'),
  Wallpaper('carnaval', 'Carnaval'),
  Wallpaper('lluvia', 'Aguacero'),
];

/// Patrones que toman los colores del tema.
const wallpaperPatterns = [
  Wallpaper('klk', 'Dibujitos KLK'),
  Wallpaper('puntos', 'Puntos'),
  Wallpaper('olas', 'Olas'),
  Wallpaper('ninguno', 'Color liso'),
];

const wallpaperColors = <Color>[
  Color(0xFF0B3D2E), Color(0xFF12355B), Color(0xFF3D2352), Color(0xFF5A1F2B),
  Color(0xFF6B4A1F), Color(0xFF2F4F4F), Color(0xFF1C1C1E), Color(0xFF36454F),
  Color(0xFFE8DCCB), Color(0xFFCFE6D9), Color(0xFFD6E4F0), Color(0xFFF2D7D9),
  Color(0xFFEFE3B8), Color(0xFFDDD5EE), Color(0xFFFFE4C4), Color(0xFFF4F4F4),
];

class WallpaperGradient {
  final String name;
  final Color a, b;
  const WallpaperGradient(this.name, this.a, this.b);
}

const wallpaperGradients = [
  WallpaperGradient('Caribe', Color(0xFF00C6FF), Color(0xFF0072FF)),
  WallpaperGradient('Atardecer', Color(0xFFFF7E5F), Color(0xFFFEB47B)),
  WallpaperGradient('Bandera', Color(0xFF002D62), Color(0xFFCE1126)),
  WallpaperGradient('Mango', Color(0xFFFFB347), Color(0xFFFFCC33)),
  WallpaperGradient('Uva', Color(0xFF7F00FF), Color(0xFFE100FF)),
  WallpaperGradient('Menta', Color(0xFF43E97B), Color(0xFF38F9D7)),
  WallpaperGradient('Noche', Color(0xFF0F2027), Color(0xFF2C5364)),
  WallpaperGradient('Rosa', Color(0xFFEE9CA7), Color(0xFFFFDDE1)),
  WallpaperGradient('Café', Color(0xFF603813), Color(0xFFB29F94)),
  WallpaperGradient('Aurora', Color(0xFF00B09B), Color(0xFF96C93D)),
  WallpaperGradient('Lavanda', Color(0xFFA18CD1), Color(0xFFFBC2EB)),
  WallpaperGradient('Grafito', Color(0xFF232526), Color(0xFF414345)),
];

int? _indexOf(String id, String prefix, int length) {
  if (!id.startsWith(prefix)) return null;
  final i = int.tryParse(id.substring(prefix.length));
  return (i != null && i >= 0 && i < length) ? i : null;
}

bool isValidWallpaper(String id) =>
    id == 'foto' ||
    wallpapers.any((w) => w.id == id) ||
    wallpaperPatterns.any((w) => w.id == id) ||
    _indexOf(id, 'c:', wallpaperColors.length) != null ||
    _indexOf(id, 'g:', wallpaperGradients.length) != null;

String wallpaperName(String id) {
  for (final w in [...wallpapers, ...wallpaperPatterns]) {
    if (w.id == id) return w.name;
  }
  if (id == 'foto') return 'Tu foto';
  if (_indexOf(id, 'c:', wallpaperColors.length) != null) return 'Color sólido';
  final g = _indexOf(id, 'g:', wallpaperGradients.length);
  if (g != null) return 'Degradado ${wallpaperGradients[g].name}';
  return 'Dibujitos KLK';
}

final wallpaperProvider = NotifierProvider<WallpaperNotifier, String>(WallpaperNotifier.new);

class WallpaperNotifier extends Notifier<String> {
  static const _key = 'klk.wallpaper';

  @override
  String build() {
    _restore();
    return 'klk';
  }

  Future<void> _restore() async {
    try {
      final saved = await ref.read(secureStoreProvider).read(_key);
      if (saved != null && isValidWallpaper(saved)) state = saved;
    } catch (_) {}
  }

  Future<void> set(String id) async {
    state = id;
    await ref.read(secureStoreProvider).write(_key, id);
  }
}

/// Cuánto se aclara/oscurece el fondo para que se lean las burbujas (0 a 0.8).
final wallpaperDimProvider = NotifierProvider<WallpaperDimNotifier, double>(WallpaperDimNotifier.new);

class WallpaperDimNotifier extends Notifier<double> {
  static const _key = 'klk.wallpaper.dim';

  @override
  double build() {
    _restore();
    return 0.35;
  }

  Future<void> _restore() async {
    try {
      final v = double.tryParse(await ref.read(secureStoreProvider).read(_key) ?? '');
      if (v != null) state = v.clamp(0.0, 0.8);
    } catch (_) {}
  }

  Future<void> set(double v) async {
    state = v.clamp(0.0, 0.8);
    await ref.read(secureStoreProvider).write(_key, state.toString());
  }
}

/// Ruta de la foto elegida como fondo (se queda en el móvil, no se envía a nadie).
final wallpaperPhotoProvider = NotifierProvider<WallpaperPhotoNotifier, String?>(WallpaperPhotoNotifier.new);

class WallpaperPhotoNotifier extends Notifier<String?> {
  static const _key = 'klk.wallpaper.photo';

  @override
  String? build() {
    _restore();
    return null;
  }

  Future<void> _restore() async {
    try {
      final path = await ref.read(secureStoreProvider).read(_key);
      if (path != null && path.isNotEmpty && File(path).existsSync()) state = path;
    } catch (_) {}
  }

  /// Abre la galería y guarda una copia. Devuelve false si no se eligió nada.
  Future<bool> pickFromGallery() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1440, imageQuality: 85);
    if (picked == null) return false;
    final docs = await getApplicationDocumentsDirectory();
    final ext = p.extension(picked.path).isEmpty ? '.jpg' : p.extension(picked.path);
    final dest = p.join(docs.path, 'klk_fondo_${DateTime.now().millisecondsSinceEpoch}$ext');
    await File(picked.path).copy(dest);
    final old = state;
    state = dest;
    await ref.read(secureStoreProvider).write(_key, dest);
    if (old != null && old != dest) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    return true;
  }
}

/// Dibuja el fondo elegido detrás de los mensajes.
class ChatWallpaper extends ConsumerWidget {
  final String id;

  /// Si es false no se atenúa (miniaturas del selector).
  final bool dim;

  /// Atenuación concreta (vista previa del selector); si es null se usa la guardada.
  final double? dimAmount;

  const ChatWallpaper({super.key, required this.id, this.dim = true, this.dimAmount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bg = theme.extension<BubbleStyle>()?.chatBg ?? theme.colorScheme.surface;
    final dark = theme.brightness == Brightness.dark;
    final ink = (dark ? Colors.white : const Color(0xFF002D62)).withValues(alpha: dark ? 0.045 : 0.07);

    // Patrones: van sobre el color del tema y no necesitan atenuación
    if (id == 'ninguno') return ColoredBox(color: bg);
    if (id == 'klk') return ColoredBox(color: bg, child: CustomPaint(painter: _DoodlePainter(ink: ink)));
    if (id == 'puntos' || id == 'olas') {
      return ColoredBox(color: bg, child: CustomPaint(painter: _PatternPainter(id, ink.withValues(alpha: dark ? 0.08 : 0.12))));
    }

    Widget base;
    final c = _indexOf(id, 'c:', wallpaperColors.length);
    final g = _indexOf(id, 'g:', wallpaperGradients.length);
    if (c != null) {
      base = ColoredBox(color: wallpaperColors[c]);
    } else if (g != null) {
      final gr = wallpaperGradients[g];
      base = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [gr.a, gr.b]),
        ),
      );
    } else if (id == 'foto') {
      final path = ref.watch(wallpaperPhotoProvider);
      base = path == null
          ? ColoredBox(color: bg)
          : Image.file(File(path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => ColoredBox(color: bg));
    } else {
      base = CustomPaint(painter: _WallpaperPainter(id));
    }

    final double saved = ref.watch(wallpaperDimProvider);
    final double amount = dim ? (dimAmount ?? saved) : 0.0;
    if (amount <= 0) return base;
    return Stack(fit: StackFit.expand, children: [
      base,
      ColoredBox(color: theme.colorScheme.surface.withValues(alpha: amount)),
    ]);
  }
}

/// Abre el selector de fondos (ilustraciones, patrones, colores, degradados o tu foto).
Future<void> showWallpaperPicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _WallpaperPicker(),
  );
}

class _WallpaperPicker extends ConsumerStatefulWidget {
  const _WallpaperPicker();

  @override
  ConsumerState<_WallpaperPicker> createState() => _WallpaperPickerState();
}

class _WallpaperPickerState extends ConsumerState<_WallpaperPicker> {
  static const _tabs = ['Ilustraciones', 'Patrones', 'Colores', 'Degradados', 'Mi foto'];
  late String _sel;
  late double _dim;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _sel = ref.read(wallpaperProvider);
    _dim = ref.read(wallpaperDimProvider);
    if (wallpaperPatterns.any((w) => w.id == _sel)) {
      _tab = 1;
    } else if (_sel.startsWith('c:')) {
      _tab = 2;
    } else if (_sel.startsWith('g:')) {
      _tab = 3;
    } else if (_sel == 'foto') {
      _tab = 4;
    }
  }

  Widget _tile(String id, String? label, {bool round = false}) {
    final cs = Theme.of(context).colorScheme;
    final selected = id == _sel;
    final thumb = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: round ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: round ? null : BorderRadius.circular(12),
        border: Border.all(color: selected ? cs.secondary : cs.outlineVariant, width: selected ? 3 : 1),
      ),
      child: ChatWallpaper(id: id, dim: false),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label ?? wallpaperName(id),
      child: GestureDetector(
        onTap: () => setState(() => _sel = id),
        child: round
            ? AspectRatio(aspectRatio: 1, child: thumb)
            : Column(children: [
                Expanded(child: SizedBox(width: double.infinity, child: thumb)),
                const SizedBox(height: 4),
                Text(label ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
              ]),
      ),
    );
  }

  Widget _grid() {
    switch (_tab) {
      case 0:
        return GridView.count(
          crossAxisCount: 3,
          childAspectRatio: 0.62,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [for (final w in wallpapers) _tile(w.id, w.name)],
        );
      case 1:
        return GridView.count(
          crossAxisCount: 3,
          childAspectRatio: 0.62,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [for (final w in wallpaperPatterns) _tile(w.id, w.name)],
        );
      case 2:
        return GridView.count(
          crossAxisCount: 5,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          children: [for (var i = 0; i < wallpaperColors.length; i++) _tile('c:$i', 'Color ${i + 1}', round: true)],
        );
      case 3:
        return GridView.count(
          crossAxisCount: 5,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          children: [
            for (var i = 0; i < wallpaperGradients.length; i++)
              _tile('g:$i', wallpaperGradients[i].name, round: true),
          ],
        );
      default:
        final photo = ref.watch(wallpaperPhotoProvider);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (photo != null)
            Align(alignment: Alignment.centerLeft, child: SizedBox(height: 130, width: 80, child: _tile('foto', 'Tu foto'))),
          const SizedBox(height: 10),
          FilledButton.icon(
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(photo == null ? 'Elegir de la galería' : 'Cambiar foto'),
            onPressed: () async {
              try {
                final ok = await ref.read(wallpaperPhotoProvider.notifier).pickFromGallery();
                if (ok && mounted) setState(() => _sel = 'foto');
              } catch (_) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('No se pudo abrir la galería. Revisa el permiso de Fotos en Ajustes → KLK.')));
              }
            },
          ),
          const SizedBox(height: 8),
          Text('La foto se queda en tu móvil; no se envía a nadie.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbles = theme.extension<BubbleStyle>();
    Widget bubble(String text, bool mine) => Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: mine ? (bubbles?.mine ?? theme.colorScheme.primary) : (bubbles?.theirs ?? theme.colorScheme.surface),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(text,
                style: TextStyle(
                    fontSize: 13.5,
                    color: mine ? (bubbles?.mineText ?? Colors.white) : (bubbles?.theirsText ?? theme.colorScheme.onSurface))),
          ),
        );

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Fondo de los chats', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          // Vista previa en vivo
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 120,
              child: Stack(fit: StackFit.expand, children: [
                ChatWallpaper(id: _sel, dimAmount: _dim),
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  bubble('Klk, ¿qué tal se ve?', false),
                  bubble('¡Durísimo! 🔥', true),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < _tabs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_tabs[i]),
                    selected: _tab == i,
                    onSelected: (_) => setState(() => _tab = i),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 10),
          SizedBox(height: 230, child: _grid()),
          Row(children: [
            const Text('Atenuación'),
            Expanded(
              child: Slider(
                value: _dim,
                max: 0.8,
                divisions: 16,
                label: '${(_dim * 100).round()}%',
                onChanged: (v) => setState(() => _dim = v),
              ),
            ),
            SizedBox(width: 40, child: Text('${(_dim * 100).round()}%', textAlign: TextAlign.end)),
          ]),
          const SizedBox(height: 4),
          FilledButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(context);
              await ref.read(wallpaperProvider.notifier).set(_sel);
              await ref.read(wallpaperDimProvider.notifier).set(_dim);
              nav.pop();
              messenger.showSnackBar(SnackBar(content: Text('Fondo: ${wallpaperName(_sel)}')));
            },
            child: const Text('Fijar fondo'),
          ),
        ]),
      ),
      ),
    );
  }
}

/// Patrones sencillos (puntos y olas) en el color de tinta del tema.
class _PatternPainter extends CustomPainter {
  final String id;
  final Color ink;
  _PatternPainter(this.id, this.ink);

  @override
  void paint(Canvas canvas, Size size) {
    if (id == 'puntos') {
      final dot = Paint()..color = ink;
      const step = 26.0;
      for (var y = 0.0; y < size.height + step; y += step) {
        final row = (y / step).round();
        for (var x = row.isEven ? 0.0 : step / 2; x < size.width + step; x += step) {
          canvas.drawCircle(Offset(x, y), 2.4, dot);
        }
      }
      return;
    }
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const w = 40.0, gap = 22.0;
    for (var y = 10.0; y < size.height + gap; y += gap) {
      final path = Path()..moveTo(-w, y);
      for (var x = -w; x < size.width + w; x += w) {
        path.quadraticBezierTo(x + w / 4, y - 7, x + w / 2, y);
        path.quadraticBezierTo(x + w * 3 / 4, y + 7, x + w, y);
      }
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) => old.id != id || old.ink != ink;
}

class _WallpaperPainter extends CustomPainter {
  final String id;
  _WallpaperPainter(this.id);

  @override
  void paint(Canvas canvas, Size size) {
    switch (id) {
      case 'malecon':
        _malecon(canvas, size);
      case 'samana':
        _samana(canvas, size);
      case 'pico':
        _pico(canvas, size);
      case 'bandera':
        _bandera(canvas, size);
      case 'colonial':
        _colonial(canvas, size);
      case 'noche':
        _noche(canvas, size);
      case 'palmeras':
        _palmeras(canvas, size);
      case 'constanza':
        _constanza(canvas, size);
      case 'carnaval':
        _carnaval(canvas, size);
      case 'lluvia':
        _lluvia(canvas, size);
    }
  }

  void _sky(Canvas c, Size s, List<Color> colors, double until) {
    c.drawRect(
      Rect.fromLTWH(0, 0, s.width, s.height * until),
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors)
            .createShader(Rect.fromLTWH(0, 0, s.width, s.height * until)),
    );
  }

  void _palm(Canvas c, Offset base, double h, double lean, Color color) {
    final trunk = Path()
      ..moveTo(base.dx, base.dy)
      ..quadraticBezierTo(base.dx + lean * 0.3, base.dy - h * 0.5, base.dx + lean, base.dy - h);
    c.drawPath(
        trunk,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = h * 0.06
          ..strokeCap = StrokeCap.round);
    final top = Offset(base.dx + lean, base.dy - h);
    final leaf = Paint()..color = color;
    for (var i = 0; i < 7; i++) {
      final a = -math.pi + i * math.pi / 6 + (i.isEven ? 0.15 : -0.1);
      final tip = top + Offset(math.cos(a) * h * 0.55, math.sin(a) * h * 0.35 + h * 0.18);
      final ctrl = top + Offset(math.cos(a) * h * 0.3, math.sin(a) * h * 0.3 - h * 0.12);
      final p = Path()
        ..moveTo(top.dx, top.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy - h * 0.04, tip.dx, tip.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy + h * 0.05, top.dx, top.dy + h * 0.02)
        ..close();
      c.drawPath(p, leaf);
    }
  }

  void _malecon(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFF2B1B4D), Color(0xFFB3426B), Color(0xFFF08A4B), Color(0xFFFFC46B)], 0.62);
    c.drawCircle(Offset(s.width * 0.62, s.height * 0.55), s.width * 0.13, Paint()..color = const Color(0xFFFFE0A3));
    final sea = Rect.fromLTWH(0, s.height * 0.6, s.width, s.height * 0.28);
    c.drawRect(
        sea,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF3A3F7A), Color(0xFF14204A)],
          ).createShader(sea));
    final glint = Paint()..color = const Color(0x66FFD8A0);
    for (var i = 0; i < 9; i++) {
      final y = s.height * (0.62 + i * 0.025);
      final w = s.width * (0.22 - i * 0.018);
      c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(s.width * 0.62, y), width: w, height: 3),
              const Radius.circular(2)),
          glint);
    }
    // El muro del Malecón y sus farolas
    c.drawRect(Rect.fromLTWH(0, s.height * 0.86, s.width, s.height * 0.14), Paint()..color = const Color(0xFF221A33));
    c.drawRect(Rect.fromLTWH(0, s.height * 0.85, s.width, 6), Paint()..color = const Color(0xFF3B2F52));
    final lamp = Paint()..color = const Color(0xFF221A33);
    for (var x = s.width * 0.1; x < s.width; x += s.width * 0.3) {
      c.drawRect(Rect.fromLTWH(x, s.height * 0.72, 4, s.height * 0.14), lamp);
      c.drawCircle(Offset(x + 2, s.height * 0.72), 7, Paint()..color = const Color(0xFFFFE6A8));
    }
    _palm(c, Offset(s.width * 0.9, s.height * 0.87), s.height * 0.32, -s.width * 0.08, const Color(0xFF1A1328));
    _palm(c, Offset(s.width * 0.05, s.height * 0.87), s.height * 0.24, s.width * 0.05, const Color(0xFF1A1328));
  }

  void _samana(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFF6EC6F0), Color(0xFFBFE9FA)], 0.5);
    final cloud = Paint()..color = const Color(0xCCFFFFFF);
    for (final o in [Offset(s.width * 0.2, s.height * 0.12), Offset(s.width * 0.72, s.height * 0.2)]) {
      c.drawCircle(o, 26, cloud);
      c.drawCircle(o + const Offset(26, 6), 20, cloud);
      c.drawCircle(o + const Offset(-24, 8), 18, cloud);
    }
    final sea = Rect.fromLTWH(0, s.height * 0.48, s.width, s.height * 0.27);
    c.drawRect(
        sea,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0E8FB3), Color(0xFF3FD0CF)],
          ).createShader(sea));
    final foam = Path()..moveTo(0, s.height * 0.75);
    for (var x = 0.0; x <= s.width; x += s.width / 8) {
      foam.quadraticBezierTo(x + s.width / 16, s.height * 0.73, x + s.width / 8, s.height * 0.75);
    }
    foam
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    c.drawPath(foam, Paint()..color = const Color(0xFFF3E1B6));
    c.drawRect(Rect.fromLTWH(0, s.height * 0.745, s.width, 3), Paint()..color = const Color(0xCCFFFFFF));
    _palm(c, Offset(s.width * 0.82, s.height * 0.95), s.height * 0.45, -s.width * 0.22, const Color(0xFF2E6B3F));
    _palm(c, Offset(s.width * 0.12, s.height * 0.97), s.height * 0.3, s.width * 0.12, const Color(0xFF3B7D4A));
  }

  void _pico(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFF8DB8E8), Color(0xFFE8F1F8)], 1);
    void ridge(List<double> ys, double base, Color color) {
      final p = Path()..moveTo(0, s.height);
      for (var i = 0; i < ys.length; i++) {
        p.lineTo(s.width * i / (ys.length - 1), s.height * (base - ys[i]));
      }
      p
        ..lineTo(s.width, s.height)
        ..close();
      c.drawPath(p, Paint()..color = color);
    }

    ridge([0.1, 0.25, 0.42, 0.3, 0.2, 0.28, 0.15], 0.72, const Color(0xFF7FA08C));
    ridge([0.05, 0.16, 0.12, 0.26, 0.18, 0.1, 0.14], 0.84, const Color(0xFF4F7C5E));
    ridge([0.08, 0.04, 0.12, 0.06, 0.1, 0.05, 0.09], 0.96, const Color(0xFF2F5A3F));
    // Pinos del bosque nublado
    final pine = Paint()..color = const Color(0xFF1E3F2B);
    for (var i = 0; i < 9; i++) {
      final x = s.width * (0.05 + i * 0.115);
      final y = s.height * (0.9 + (i.isEven ? 0.02 : 0));
      final h = s.height * 0.08;
      c.drawPath(
          Path()
            ..moveTo(x, y - h)
            ..lineTo(x - h * 0.3, y)
            ..lineTo(x + h * 0.3, y)
            ..close(),
          pine);
    }
    final mist = Paint()..color = const Color(0x55FFFFFF);
    c.drawOval(Rect.fromCenter(center: Offset(s.width * 0.3, s.height * 0.55), width: s.width * 0.7, height: 34), mist);
    c.drawOval(Rect.fromCenter(center: Offset(s.width * 0.75, s.height * 0.66), width: s.width * 0.6, height: 28), mist);
  }

  void _bandera(Canvas c, Size s) {
    const blue = Color(0xFF002D62), red = Color(0xFFCE1126);
    final cx = s.width / 2, cy = s.height / 2, bar = s.width * 0.12;
    c.drawRect(Rect.fromLTWH(0, 0, s.width, s.height), Paint()..color = Colors.white);
    c.drawRect(Rect.fromLTRB(0, 0, cx - bar / 2, cy - bar / 2), Paint()..color = blue);
    c.drawRect(Rect.fromLTRB(cx + bar / 2, 0, s.width, cy - bar / 2), Paint()..color = red);
    c.drawRect(Rect.fromLTRB(0, cy + bar / 2, cx - bar / 2, s.height), Paint()..color = red);
    c.drawRect(Rect.fromLTRB(cx + bar / 2, cy + bar / 2, s.width, s.height), Paint()..color = blue);
    // Escudo simplificado
    c.drawCircle(Offset(cx, cy), bar * 0.42, Paint()..color = const Color(0xFF1F7A4D));
    c.drawCircle(Offset(cx, cy), bar * 0.28, Paint()..color = Colors.white);
  }


  void _colonial(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFF7CC4EF), Color(0xFFD8F0FB)], 1);
    const colors = [Color(0xFFF2B84B), Color(0xFFE5735C), Color(0xFF5BB3A5), Color(0xFF9A7FD1)];
    const tops = [0.39, 0.34, 0.41, 0.37];
    final w = s.width / 4;
    final ground = s.height * 0.83;
    for (var i = 0; i < 4; i++) {
      final x = w * i, top = s.height * tops[i];
      c.drawRect(Rect.fromLTRB(x, top, x + w, ground), Paint()..color = colors[i]);
      c.drawRect(Rect.fromLTWH(x, top - 6, w, 6), Paint()..color = const Color(0xE6FFFFFF));
      // Ventana con balcón
      final win = Rect.fromLTWH(x + w * 0.27, top + s.height * 0.07, w * 0.46, s.height * 0.09);
      c.drawRect(win, Paint()..color = const Color(0xFF2C4A63));
      c.drawRect(
          win,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
      // Puerta de arco
      final door = Path()
        ..moveTo(x + w * 0.3, ground)
        ..lineTo(x + w * 0.3, ground - s.height * 0.1)
        ..arcToPoint(Offset(x + w * 0.7, ground - s.height * 0.1), radius: Radius.circular(w * 0.2))
        ..lineTo(x + w * 0.7, ground)
        ..close();
      c.drawPath(door, Paint()..color = const Color(0xFF4B2E1E));
    }
    // Calle adoquinada
    c.drawRect(Rect.fromLTRB(0, ground, s.width, s.height), Paint()..color = const Color(0xFFB9A58F));
    final joint = Paint()
      ..color = const Color(0xFF9C876F)
      ..strokeWidth = 1;
    for (var y = ground; y < s.height; y += 12) {
      c.drawLine(Offset(0, y), Offset(s.width, y), joint);
      final offset = ((y - ground) / 12).round().isEven ? 0.0 : 12.0;
      for (var x = offset; x < s.width; x += 24) {
        c.drawLine(Offset(x, y), Offset(x, y + 12), joint);
      }
    }
  }

  void _noche(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFF050A1F), Color(0xFF16285A), Color(0xFF2D3F7A)], 1);
    final rnd = math.Random(3);
    final star = Paint()..color = Colors.white;
    for (var i = 0; i < 70; i++) {
      c.drawCircle(Offset(rnd.nextDouble() * s.width, rnd.nextDouble() * s.height * 0.7), 0.6 + rnd.nextDouble() * 1.2,
          star..color = Colors.white.withValues(alpha: 0.4 + rnd.nextDouble() * 0.6));
    }
    // Luna creciente
    final moon = Offset(s.width * 0.72, s.height * 0.16);
    c.drawCircle(moon, s.width * 0.1, Paint()..color = const Color(0xFFF6F1D3));
    c.drawCircle(moon + Offset(s.width * 0.04, -s.width * 0.03), s.width * 0.09, Paint()..color = const Color(0xFF0A1330));
    // Lomas y un bohío con la luz encendida
    final hill = Path()
      ..moveTo(0, s.height)
      ..lineTo(0, s.height * 0.82)
      ..quadraticBezierTo(s.width * 0.25, s.height * 0.74, s.width * 0.5, s.height * 0.79)
      ..quadraticBezierTo(s.width * 0.75, s.height * 0.84, s.width, s.height * 0.76)
      ..lineTo(s.width, s.height)
      ..close();
    c.drawPath(hill, Paint()..color = const Color(0xFF0B1A2E));
    const hut = Color(0xFF050D18);
    final hx = s.width * 0.48, hy = s.height * 0.79;
    c.drawRect(Rect.fromLTWH(hx - 18, hy - 22, 36, 22), Paint()..color = hut);
    c.drawPath(
        Path()
          ..moveTo(hx - 24, hy - 20)
          ..lineTo(hx, hy - 38)
          ..lineTo(hx + 24, hy - 20)
          ..close(),
        Paint()..color = hut);
    c.drawRect(Rect.fromLTWH(hx - 4, hy - 16, 8, 7), Paint()..color = const Color(0xFFFFC46B));
    _palm(c, Offset(s.width * 0.2, s.height * 0.8), s.height * 0.25, s.width * 0.04, hut);
    _palm(c, Offset(s.width * 0.82, s.height * 0.78), s.height * 0.2, -s.width * 0.05, hut);
  }

  void _palmeras(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFFFF7E5F), Color(0xFFFEB47B), Color(0xFFFFE29A)], 0.72);
    final sun = Offset(s.width * 0.5, s.height * 0.68);
    c.drawCircle(sun, s.width * 0.18, Paint()..color = const Color(0xDDFFF3C4));
    final sea = Rect.fromLTWH(0, s.height * 0.72, s.width, s.height * 0.28);
    c.drawRect(
        sea,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2A9D8F), Color(0xFF1D6F6A)],
          ).createShader(sea));
    final glint = Paint()..color = const Color(0x88FFE7B0);
    for (var i = 0; i < 5; i++) {
      final w = s.width * (0.36 - i * 0.06);
      c.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(sun.dx, s.height * (0.75 + i * 0.03)), width: w, height: 2.5),
              const Radius.circular(2)),
          glint);
    }
    const ink = Color(0xFF2B1B2E);
    _palm(c, Offset(s.width * 0.12, s.height * 1.02), s.height * 0.5, s.width * 0.12, ink);
    _palm(c, Offset(s.width * 0.88, s.height * 1.02), s.height * 0.38, -s.width * 0.1, ink);
  }

  void _constanza(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFFA9D6F5), Color(0xFFEEF8FD)], 1);
    final cloud = Paint()..color = const Color(0xE6FFFFFF);
    c.drawOval(Rect.fromCenter(center: Offset(s.width * 0.25, s.height * 0.16), width: s.width * 0.3, height: 16), cloud);
    c.drawOval(Rect.fromCenter(center: Offset(s.width * 0.7, s.height * 0.11), width: s.width * 0.36, height: 18), cloud);
    void ridge(List<double> ys, Color color) {
      final p = Path()..moveTo(0, s.height);
      for (var i = 0; i < ys.length; i++) {
        p.lineTo(s.width * i / (ys.length - 1), s.height * ys[i]);
      }
      p
        ..lineTo(s.width, s.height)
        ..close();
      c.drawPath(p, Paint()..color = color);
    }

    ridge([0.5, 0.38, 0.47, 0.31, 0.43, 0.36], const Color(0xFF6F8FA8));
    ridge([0.57, 0.48, 0.54, 0.44, 0.52, 0.49], const Color(0xFF4F7C5E));
    // Huertos en franjas
    const stripes = [Color(0xFF8CC06A), Color(0xFF6AA84F), Color(0xFFC8E39C)];
    final rows = 9;
    final top = s.height * 0.6;
    final h = (s.height - top) / rows;
    for (var i = 0; i < rows; i++) {
      final y = top + h * i;
      final p = Path()
        ..moveTo(0, y + h * 0.4)
        ..lineTo(s.width, y)
        ..lineTo(s.width, y + h)
        ..lineTo(0, y + h * 1.4)
        ..close();
      c.drawPath(p, Paint()..color = stripes[i % stripes.length]);
    }
    final flower = Paint()..color = const Color(0xFFE05A7A);
    final rnd = math.Random(5);
    for (var i = 0; i < 18; i++) {
      c.drawCircle(Offset(rnd.nextDouble() * s.width, top + rnd.nextDouble() * (s.height - top)), 2.2, flower);
    }
  }

  void _carnaval(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF3B0D5C));
    const colors = [
      Color(0xFFFFB627), Color(0xFF00A6B4), Color(0xFFCE1126), Color(0xFF7EE081), Color(0xFFFF5FA2), Color(0xFFFFD23F),
    ];
    final rnd = math.Random(11);
    for (var i = 0; i < 46; i++) {
      final paint = Paint()..color = colors[i % colors.length];
      final o = Offset(rnd.nextDouble() * s.width, rnd.nextDouble() * s.height);
      final size = 4 + rnd.nextDouble() * 7;
      c.save();
      c.translate(o.dx, o.dy);
      c.rotate(rnd.nextDouble() * math.pi);
      switch (i % 3) {
        case 0:
          c.drawCircle(Offset.zero, size * 0.7, paint);
        case 1:
          c.drawRect(Rect.fromCenter(center: Offset.zero, width: size * 1.6, height: size * 0.6), paint);
        default:
          c.drawPath(
              Path()
                ..moveTo(0, -size)
                ..lineTo(size, size * 0.8)
                ..lineTo(-size, size * 0.8)
                ..close(),
              paint);
      }
      c.restore();
    }
    // Serpentinas
    final ribbon = Paint()
      ..color = const Color(0x59FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final f in [0.18, 0.64]) {
      final y = s.height * f;
      final p = Path()..moveTo(0, y);
      for (var x = 0.0; x < s.width; x += s.width / 3) {
        p.quadraticBezierTo(x + s.width / 6, y - 22, x + s.width / 3, y);
      }
      c.drawPath(p, ribbon);
    }
  }

  void _lluvia(Canvas c, Size s) {
    _sky(c, s, const [Color(0xFF5D6D7E), Color(0xFF2C3E50)], 1);
    final cloud = Paint()..color = const Color(0xFF8899AA);
    for (final o in [Offset(s.width * 0.2, s.height * 0.1), Offset(s.width * 0.75, s.height * 0.15)]) {
      c.drawOval(Rect.fromCenter(center: o, width: s.width * 0.45, height: 34), cloud);
      c.drawOval(Rect.fromCenter(center: o + const Offset(18, -10), width: s.width * 0.3, height: 30), cloud);
    }
    final drop = Paint()
      ..color = const Color(0x8CCFE3F2)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final rnd = math.Random(9);
    for (var i = 0; i < 90; i++) {
      final x = rnd.nextDouble() * s.width, y = s.height * 0.2 + rnd.nextDouble() * s.height * 0.75;
      c.drawLine(Offset(x, y), Offset(x - 4, y + 12), drop);
    }
    c.drawRect(Rect.fromLTRB(0, s.height * 0.94, s.width, s.height), Paint()..color = const Color(0xFF22313F));
  }

  @override
  bool shouldRepaint(_WallpaperPainter old) => old.id != id;
}


/// Fondo de dibujitos (como el de WhatsApp) con cosas nuestras:
/// palmeras, sol, pelota, avión, café, música, corazones…
class _DoodlePainter extends CustomPainter {
  final Color ink;
  _DoodlePainter({required this.ink});

  static const _icons = <IconData>[
    Icons.beach_access_outlined,
    Icons.wb_sunny_outlined,
    Icons.sports_baseball_outlined,
    Icons.flight_outlined,
    Icons.local_cafe_outlined,
    Icons.music_note_outlined,
    Icons.favorite_border,
    Icons.chat_bubble_outline,
    Icons.star_border,
    Icons.emoji_emotions_outlined,
    Icons.sailing_outlined,
    Icons.headphones_outlined,
    Icons.local_florist_outlined,
    Icons.camera_alt_outlined,
    Icons.icecream_outlined,
    Icons.pets_outlined,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 64.0;
    final rnd = math.Random(7); // siempre el mismo dibujo
    for (var y = -cell / 2; y < size.height + cell; y += cell) {
      final row = (y / cell).round();
      for (var x = (row.isEven ? 0.0 : cell / 2) - cell / 2; x < size.width + cell; x += cell) {
        final icon = _icons[rnd.nextInt(_icons.length)];
        final s = 20.0 + rnd.nextDouble() * 8;
        final tp = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: s, color: ink),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas.save();
        canvas.translate(x + (rnd.nextDouble() - 0.5) * 16, y + (rnd.nextDouble() - 0.5) * 16);
        canvas.rotate((rnd.nextDouble() - 0.5) * 0.9);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_DoodlePainter old) => old.ink != ink;
}
