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
