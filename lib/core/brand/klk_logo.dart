import 'package:flutter/material.dart';

/// Escudo de KLK (el mismo dibujo que el icono de la app).
class KlkEmblem extends StatelessWidget {
  final double size;
  const KlkEmblem({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset('assets/brand/klk_emblem.png', width: size, height: size, fit: BoxFit.cover),
      );
}

/// Logo completo: escudo + "KLK messenger".
class KlkLogo extends StatelessWidget {
  final double height;
  const KlkLogo({super.key, this.height = 220});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height * 0.12),
        child: Image.asset('assets/brand/klk_logo.png', height: height, fit: BoxFit.contain),
      );
}
