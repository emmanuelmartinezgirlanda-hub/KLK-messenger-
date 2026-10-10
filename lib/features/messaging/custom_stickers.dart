import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Stickers hechos por el usuario: una foto (o una imagen pegada desde el
/// teclado) recortada en cuadrado y guardada en este móvil.
class CustomStickers {
  CustomStickers._();

  static const size = 512;

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'klk_stickers'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Mis stickers, del más nuevo al más viejo.
  static Future<List<String>> list() async {
    try {
      final files = (await _dir()).listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      return [for (final f in files) f.path];
    } catch (_) {
      return const [];
    }
  }

  /// Elige una foto de la galería y la convierte en sticker. Devuelve la ruta, o null.
  static Future<String?> createFromGallery() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1400, maxHeight: 1400);
    if (x == null) return null;
    return saveBytes(await File(x.path).readAsBytes());
  }

  /// Recorta en cuadrado (por el centro), lo deja en 512×512 y lo guarda como PNG.
  static Future<String> saveBytes(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final side = math.min(img.width, img.height).toDouble();
    final src = ui.Rect.fromLTWH((img.width - side) / 2, (img.height - side) / 2, side, side);
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawImageRect(
      img,
      src,
      ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final out = await rec.endRecording().toImage(size, size);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    out.dispose();
    final path = p.join((await _dir()).path, 'sticker_${DateTime.now().microsecondsSinceEpoch}.png');
    await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    return path;
  }

  static Future<void> delete(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}
