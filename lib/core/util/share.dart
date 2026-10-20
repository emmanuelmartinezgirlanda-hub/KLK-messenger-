import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Abre "Compartir" del móvil. En iPhone/iPad hace falta decir desde dónde
/// sale la hoja (si no, en versiones nuevas de iOS no se abre). Si falla,
/// copia el texto y lo avisa.
Future<void> shareText(BuildContext context, String text, {String? subject}) async {
  final box = context.findRenderObject() as RenderBox?;
  final screen = MediaQuery.sizeOf(context);
  final origin = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : Rect.fromLTWH(screen.width / 2 - 1, screen.height / 2 - 1, 2, 2);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await Share.share(text, subject: subject, sharePositionOrigin: origin);
  } catch (e) {
    await Clipboard.setData(ClipboardData(text: text));
    messenger?.showSnackBar(const SnackBar(content: Text('No se pudo abrir «Compartir». Enlace copiado: pégalo donde quieras.')));
  }
}
