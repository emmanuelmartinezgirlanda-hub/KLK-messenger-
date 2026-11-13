import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Un estilo de anillo para la foto cuando alguien tiene un estado.
class RingStyle {
  final String name;
  final List<Color> colors;
  /// Gira y brilla (neón).
  final bool neon;
  /// Solo con KLK Plus.
  final bool plus;
  const RingStyle(this.name, this.colors, {this.neon = false, this.plus = true});
}

/// Anillos disponibles. «verde» es el de todo el mundo; el resto, con Plus.
const ringStyles = <String, RingStyle>{
  'verde': RingStyle('Verde', [Color(0xFF25D366), Color(0xFF1DB954), Color(0xFF25D366)], plus: false),
  'azul': RingStyle('Azul', [Color(0xFF1E6FE8), Color(0xFF00B4FF), Color(0xFF1E6FE8)]),
  'rosa': RingStyle('Rosa', [Color(0xFFFF4F9A), Color(0xFFFF9AC8), Color(0xFFFF4F9A)]),
  'morado': RingStyle('Morado', [Color(0xFF7C3AED), Color(0xFFC084FC), Color(0xFF7C3AED)]),
  'dorado': RingStyle('Dorado', [Color(0xFFB8860B), Color(0xFFFFE08A), Color(0xFFB8860B)]),
  'rojo': RingStyle('Rojo', [Color(0xFFCE1126), Color(0xFFFF6B6B), Color(0xFFCE1126)]),
  'bandera': RingStyle('Bandera RD', [Color(0xFF002D62), Color(0xFFFFFFFF), Color(0xFFCE1126), Color(0xFF002D62)]),
  'arcoiris': RingStyle('Arcoíris', [
    Color(0xFFFF3B30), Color(0xFFFF9500), Color(0xFFFFCC00), Color(0xFF34C759), Color(0xFF00C7BE),
    Color(0xFF007AFF), Color(0xFFAF52DE), Color(0xFFFF3B30),
  ]),
  'neon_azul': RingStyle('Neón azul', [Color(0xFF00E5FF), Color(0xFF2962FF), Color(0xFF00E5FF)], neon: true),
  'neon_rosa': RingStyle('Neón rosa', [Color(0xFFFF2BD6), Color(0xFF7C4DFF), Color(0xFFFF2BD6)], neon: true),
  'neon_verde': RingStyle('Neón verde', [Color(0xFF39FF14), Color(0xFF00E5A0), Color(0xFF39FF14)], neon: true),
  'neon_fuego': RingStyle('Neón fuego', [Color(0xFFFF3D00), Color(0xFFFFC400), Color(0xFFFF3D00)], neon: true),
  'neon_arcoiris': RingStyle('Neón arcoíris', [
    Color(0xFFFF2D55), Color(0xFFFF9500), Color(0xFFFFEA00), Color(0xFF39FF14), Color(0xFF00E5FF),
    Color(0xFF7C4DFF), Color(0xFFFF2BD6), Color(0xFFFF2D55),
  ], neon: true),
};

/// Pone el anillo alrededor de [child]. [seen] = ya lo vi (anillo gris).
class StatusRing extends StatefulWidget {
  final Widget child;
  final String style;
  final bool seen;
  final double width;
  const StatusRing({super.key, required this.child, this.style = 'verde', this.seen = false, this.width = 2.4});

  @override
  State<StatusRing> createState() => _StatusRingState();
}

class _StatusRingState extends State<StatusRing> with SingleTickerProviderStateMixin {
  AnimationController? _spin;

  RingStyle get _style => ringStyles[widget.style] ?? ringStyles['verde']!;
  bool get _animated => _style.neon && !widget.seen;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusRing old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_animated && _spin == null) {
      _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();
    } else if (!_animated && _spin != null) {
      _spin!.dispose();
      _spin = null;
    }
  }

  @override
  void dispose() {
    _spin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final inner = Container(
      padding: const EdgeInsets.all(1.8),
      decoration: BoxDecoration(shape: BoxShape.circle, color: surface),
      child: widget.child,
    );
    if (widget.seen) {
      return Container(
        padding: EdgeInsets.all(widget.width),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.grey.withValues(alpha: 0.55), width: widget.width * 0.85),
        ),
        child: inner,
      );
    }
    final s = _style;
    Widget ring(double turn) => Container(
          padding: EdgeInsets.all(widget.width),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(colors: s.colors, transform: GradientRotation(turn * 2 * math.pi)),
            boxShadow: s.neon
                ? [
                    BoxShadow(
                      color: s.colors[(turn * s.colors.length).floor() % s.colors.length].withValues(alpha: 0.75),
                      blurRadius: 9,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
          child: inner,
        );
    final spin = _spin;
    if (spin == null) return ring(0);
    return AnimatedBuilder(animation: spin, builder: (_, __) => ring(spin.value));
  }
}

/// Muestra de un anillo (para elegirlo).
class RingSwatch extends StatelessWidget {
  final String style;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;
  const RingSwatch({super.key, required this.style, required this.selected, required this.locked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = ringStyles[style]!;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 78,
        child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            StatusRing(
              style: style,
              width: 3,
              child: CircleAvatar(
                radius: 26,
                backgroundColor: cs.surfaceContainerHighest,
                child: Icon(Icons.person_rounded, color: cs.onSurfaceVariant),
              ),
            ),
            if (selected)
              Positioned(
                right: -2,
                bottom: -2,
                child: CircleAvatar(radius: 11, backgroundColor: cs.primary, child: const Icon(Icons.check, size: 14, color: Colors.white)),
              )
            else if (locked)
              const Positioned(
                right: -2,
                bottom: -2,
                child: CircleAvatar(radius: 11, backgroundColor: Color(0xFF2C220E), child: Icon(Icons.lock, size: 12, color: Color(0xFFFFD86B))),
              ),
          ]),
          const SizedBox(height: 6),
          Text(s.name, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
