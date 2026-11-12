import 'dart:io';

import 'package:flutter/material.dart';

const _avatarColors = [
  Color(0xFFCE1126), Color(0xFF00A6B4), Color(0xFF6A2C91),
  Color(0xFF1F7A4D), Color(0xFFC46A00), Color(0xFF002D62),
];

Color avatarColor(String id) => _avatarColors[id.hashCode.abs() % _avatarColors.length];

/// Foto de perfil redonda; si no hay foto, la inicial sobre un color.
class ChatAvatar extends StatelessWidget {
  final String id;
  final String title;
  final String? photoPath;
  final double radius;

  const ChatAvatar({super.key, required this.id, required this.title, this.photoPath, this.radius = 26});

  @override
  Widget build(BuildContext context) {
    final path = photoPath;
    if (path != null && File(path).existsSync()) {
      return CircleAvatar(radius: radius, backgroundImage: FileImage(File(path)));
    }
    // Comunidades: la bandera llena todo el círculo.
    final first = title.isEmpty ? '' : title.characters.first;
    final runes = first.runes.toList();
    if (runes.length == 2 && runes.every((r) => r >= 0x1F1E6 && r <= 0x1F1FF)) {
      return ClipOval(
        child: Container(
          width: radius * 2,
          height: radius * 2,
          color: avatarColor(id),
          child: OverflowBox(
            maxWidth: radius * 6,
            maxHeight: radius * 6,
            child: Text(first, style: TextStyle(fontSize: radius * 2.9, height: 1)),
          ),
        ),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: avatarColor(id),
      child: Text(
        title.isEmpty ? '?' : title.characters.first.toUpperCase(),
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: radius * 0.7),
      ),
    );
  }
}

/// Foto con adornos, como en WhatsApp: aro de colores si tiene un estado sin ver
/// (gris si ya lo viste) y un relojito si el chat tiene mensajes temporales.
class AvatarDecor extends StatelessWidget {
  final Widget child;
  final double radius;
  /// 0 = sin estado · 1 = estado nuevo · 2 = estado ya visto
  final int ring;
  final bool timer;
  const AvatarDecor({super.key, required this.child, required this.radius, this.ring = 0, this.timer = false});

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    Widget out = child;
    if (ring != 0) {
      out = Container(
        padding: const EdgeInsets.all(2.2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: ring == 1
              ? const SweepGradient(colors: [Color(0xFF002D62), Color(0xFFCE1126), Color(0xFFFFB627), Color(0xFF002D62)])
              : null,
          border: ring == 1 ? null : Border.all(color: Colors.grey.withValues(alpha: 0.55), width: 2),
        ),
        child: Container(
          padding: const EdgeInsets.all(1.8),
          decoration: BoxDecoration(shape: BoxShape.circle, color: surface),
          child: child,
        ),
      );
    }
    if (!timer) return out;
    final s = (radius * 0.62).clamp(14.0, 22.0);
    return Stack(clipBehavior: Clip.none, children: [
      out,
      Positioned(
        right: -2,
        bottom: -2,
        child: Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            color: const Color(0xFF14213D),
            shape: BoxShape.circle,
            border: Border.all(color: surface, width: 2),
          ),
          child: Icon(Icons.timer_rounded, size: s * 0.62, color: Colors.white),
        ),
      ),
    ]);
  }
}
