import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/secure_store.dart';
import 'domain/klk_theme.dart';

/// Fondos de chat dominicanos, dibujados en el propio móvil (sin fotos de terceros).
class Wallpaper {
  final String id;
  final String name;
  const Wallpaper(this.id, this.name);
}

const wallpapers = [
  Wallpaper('klk', 'Dibujitos KLK'),
  Wallpaper('ninguno', 'Color liso'),
  Wallpaper('malecon', 'Malecón al atardecer'),
  Wallpaper('samana', 'Playa de Samaná'),
  Wallpaper('pico', 'Pico Duarte'),
  Wallpaper('bandera', 'Bandera'),
];

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
      if (saved != null && wallpapers.any((w) => w.id == saved)) state = saved;
    } catch (_) {}
  }

  Future<void> set(String id) async {
    state = id;
    await ref.read(secureStoreProvider).write(_key, id);
  }
}

/// Dibuja el fondo elegido detrás de los mensajes.
class ChatWallpaper extends StatelessWidget {
  final String id;
  final bool dim; // oscurece/aclara un poco para que se lean bien las burbujas
  const ChatWallpaper({super.key, required this.id, this.dim = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = theme.extension<BubbleStyle>()?.chatBg ?? theme.colorScheme.surface;
    if (id == 'ninguno') return ColoredBox(color: bg);
    if (id == 'klk') {
      final dark = theme.brightness == Brightness.dark;
      return ColoredBox(
        color: bg,
        child: CustomPaint(
          painter: _DoodlePainter(
            ink: (dark ? Colors.white : const Color(0xFF002D62)).withValues(alpha: dark ? 0.045 : 0.07),
          ),
        ),
      );
    }
    final surface = theme.colorScheme.surface;
    return Stack(fit: StackFit.expand, children: [
      CustomPaint(painter: _WallpaperPainter(id)),
      if (dim) ColoredBox(color: surface.withValues(alpha: 0.35)),
    ]);
  }
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
