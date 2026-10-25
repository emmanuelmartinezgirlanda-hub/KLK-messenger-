import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/l10n/l10n.dart';
import '../messaging/app_controller.dart';

/// Foto de un negocio (logo o producto) guardada en el servidor.
/// Mientras carga o si falla, enseña [fallback].
class BizImage extends ConsumerWidget {
  final String id;
  final double size;
  final double radius;
  final Widget fallback;
  const BizImage({super.key, required this.id, required this.size, this.radius = 12, required this.fallback});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.read(appProvider).bizImageUrl(id);
    if (url == null) return SizedBox(width: size, height: size, child: fallback);
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: px,
        gaplessPlayback: true,
        loadingBuilder: (_, child, progress) => progress == null ? child : SizedBox(width: size, height: size, child: fallback),
        errorBuilder: (_, __, ___) => SizedBox(width: size, height: size, child: fallback),
      ),
    );
  }
}

/// Abre la foto en grande (se puede ampliar con los dedos).
void showBizPhoto(BuildContext context, WidgetRef ref, String id, {String title = ''}) {
  final url = ref.read(appProvider).bizImageUrl(id);
  if (url == null) return;
  Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(color: Colors.white)),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 4,
          child: Image.network(url,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  Text(tr('No se pudo cargar la foto.'), style: const TextStyle(color: Colors.white70))),
        ),
      ),
    ),
  ));
}

/// Qué quiso hacer la persona con la foto.
enum BizPhotoChoice { gallery, camera, remove }

/// Hoja con "Elegir de la galería / Hacer una foto / Quitar foto".
Future<BizPhotoChoice?> askBizPhoto(BuildContext context, {required bool hasPhoto}) =>
    showModalBottomSheet<BizPhotoChoice>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(tr('Elegir de la galería')),
            onTap: () => Navigator.pop(ctx, BizPhotoChoice.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(tr('Hacer una foto')),
            onTap: () => Navigator.pop(ctx, BizPhotoChoice.camera),
          ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A)),
              title: Text(tr('Quitar foto'), style: const TextStyle(color: Color(0xFFFF6B7A))),
              onTap: () => Navigator.pop(ctx, BizPhotoChoice.remove),
            ),
        ]),
      ),
    );

/// Saca una foto de la galería o la cámara, ya reducida a [maxSide] píxeles.
/// Devuelve null si la persona cancela. Si no hay permiso, lo avisa.
Future<List<int>?> pickPhotoBytes(BuildContext context, BizPhotoChoice source,
    {double maxSide = 1000, int quality = 82}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final x = await ImagePicker().pickImage(
      source: source == BizPhotoChoice.camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: maxSide,
      maxHeight: maxSide,
      imageQuality: quality,
    );
    if (x == null) return null;
    return await x.readAsBytes();
  } catch (_) {
    messenger?.showSnackBar(SnackBar(
        content: Text(tr('KLK no tiene permiso para tus fotos o la cámara. Actívalo en Ajustes del iPhone → KLK.'))));
    return null;
  }
}

/// Pide la foto, la sube al servidor y devuelve su id.
/// Devuelve '' si la quitó, null si canceló o falló (y ya avisó).
Future<String?> pickAndUploadBizPhoto(BuildContext context, WidgetRef ref,
    {required bool hasPhoto, double maxSide = 1000, ValueChanged<bool>? onBusy}) async {
  final choice = await askBizPhoto(context, hasPhoto: hasPhoto);
  if (choice == null || !context.mounted) return null;
  if (choice == BizPhotoChoice.remove) return '';
  final messenger = ScaffoldMessenger.maybeOf(context);
  final bytes = await pickPhotoBytes(context, choice, maxSide: maxSide);
  if (bytes == null) return null;
  onBusy?.call(true);
  try {
    return await ref.read(appProvider).uploadBizImage(bytes);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('${tr('No se pudo subir la foto')}: $e')));
    return null;
  } finally {
    onBusy?.call(false);
  }
}
