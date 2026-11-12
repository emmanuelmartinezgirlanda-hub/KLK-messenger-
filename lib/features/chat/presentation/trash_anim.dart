import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Animación al borrar una nota de voz (como en WhatsApp): el micrófono salta,
/// da una vuelta y cae dentro del zafacón, que abre y cierra la tapa.
class TrashAnimation extends StatefulWidget {
  final VoidCallback onDone;
  const TrashAnimation({super.key, required this.onDone});

  @override
  State<TrashAnimation> createState() => _TrashAnimationState();
}

class _TrashAnimationState extends State<TrashAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1250))..forward();

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    Future.delayed(const Duration(milliseconds: 820), () {
      if (mounted) HapticFeedback.lightImpact(); // cae dentro
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFE5484D);
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = _c.value;
          // Zafacón: sube desde abajo, abre la tapa, la cierra y se va.
          final appear = Curves.easeOutBack.transform(_seg(t, 0.0, 0.25));
          final leave = Curves.easeIn.transform(_seg(t, 0.88, 1.0));
          final lidOpen = _seg(t, 0.25, 0.45) - _seg(t, 0.72, 0.84);
          final lid = -0.9 * Curves.easeOut.transform(lidOpen.clamp(0.0, 1.0));
          final canY = 40 * (1 - appear) + 50 * leave;
          // Micrófono: salta arriba dando una vuelta y cae dentro (0.0 → 0.8).
          final up = Curves.easeOut.transform(_seg(t, 0.0, 0.35));
          final down = Curves.easeIn.transform(_seg(t, 0.35, 0.78));
          final micY = -64 * up + 74 * down;
          final micVisible = t < 0.8;
          final micRot = math.pi * 2 * _seg(t, 0.0, 0.6);
          final micScale = 1.0 - 0.35 * down;
          return Stack(clipBehavior: Clip.none, alignment: Alignment.centerLeft, children: [
            Positioned(
              left: 22,
              bottom: 2,
              child: Transform.translate(
                offset: Offset(0, canY),
                child: SizedBox(
                  width: 34,
                  height: 40,
                  child: Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
                    // cuerpo
                    Container(
                      width: 26,
                      height: 28,
                      decoration: BoxDecoration(
                        color: red,
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6), top: Radius.circular(2)),
                      ),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                        for (var i = 0; i < 3; i++)
                          Container(width: 2.4, height: 16, decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(2))),
                      ]),
                    ),
                    // tapa (gira desde la izquierda)
                    Positioned(
                      bottom: 30,
                      child: Transform.rotate(
                        angle: lid,
                        alignment: Alignment.centerLeft,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 10,
                            height: 4,
                            decoration: const BoxDecoration(
                              color: red,
                              borderRadius: BorderRadius.vertical(top: Radius.circular(3)),
                            ),
                          ),
                          Container(
                            width: 32,
                            height: 5,
                            decoration: BoxDecoration(color: red, borderRadius: BorderRadius.circular(3)),
                          ),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            if (micVisible)
              Positioned(
                left: 26,
                bottom: 14,
                child: Transform.translate(
                  offset: Offset(0, micY),
                  child: Transform.rotate(
                    angle: micRot,
                    child: Transform.scale(
                      scale: micScale,
                      child: const Icon(Icons.mic_rounded, color: Color(0xFFCE1126), size: 26),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 72,
              child: Opacity(
                opacity: (1 - leave).clamp(0.0, 1.0) * _seg(t, 0.05, 0.25),
                child: Text('Nota de voz borrada',
                    style: TextStyle(fontSize: 15, color: cs.onSurface.withValues(alpha: 0.7), fontWeight: FontWeight.w600)),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
