import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../features/messaging/models.dart' show resolveMediaPath;

/// Archivo cifrado listo para subir, con lo necesario para descifrarlo.
class SealedFile {
  final List<int> bytes; // texto cifrado (lo que se sube al servidor)
  final List<int> key, nonce, mac;
  const SealedFile(this.bytes, this.key, this.nonce, this.mac);
}

/// Guarda los adjuntos en el móvil y los cifra/descifra.
///
/// Cada archivo se cifra con su propia clave AES-256-GCM aleatoria.
/// Esa clave viaja dentro del mensaje (que ya va cifrado de punta a punta),
/// así que el servidor solo guarda bytes ilegibles.
class MediaStore {
  static final _aes = AesGcm.with256bits();
  static const _uuid = Uuid();

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'media'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String? _dirPath;

  /// Se llama al arrancar: recuerda la carpeta actual y enseña a los modelos a
  /// traducir rutas guardadas con una carpeta antigua (iOS cambia la ruta de la
  /// app al actualizarla, y al restaurar una copia en otro iPhone).
  static Future<void> init() async {
    _dirPath = (await _dir()).path;
    resolveMediaPath = rebase;
  }

  /// ".../<otra carpeta>/media/abc.jpg" -> "<carpeta actual>/media/abc.jpg".
  static String? rebase(String? path) {
    final dir = _dirPath;
    if (path == null || dir == null) return path;
    final i = path.lastIndexOf('/media/');
    if (i < 0) return path;
    return p.join(dir, path.substring(i + '/media/'.length));
  }

  /// Carpeta de adjuntos (para la copia de seguridad).
  static Future<Directory> directory() => _dir();

  /// Ruta nueva dentro de la carpeta de KLK con la extensión dada (".jpg", ".m4a"…).
  static Future<String> newPath(String extension) async =>
      p.join((await _dir()).path, '${_uuid.v4()}$extension');

  /// Copia un archivo elegido por el usuario a la carpeta de KLK (calidad original).
  static Future<String> importFile(String sourcePath) async {
    final dest = await newPath(p.extension(sourcePath).toLowerCase());
    await File(sourcePath).copy(dest);
    return dest;
  }

  static Future<SealedFile> seal(String path) async {
    final key = await _aes.newSecretKey();
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(await File(path).readAsBytes(), secretKey: key, nonce: nonce);
    return SealedFile(box.cipherText, await key.extractBytes(), box.nonce, box.mac.bytes);
  }

  /// Descifra y guarda el archivo; devuelve su ruta local.
  static Future<String> open(List<int> cipherText,
      {required List<int> key, required List<int> nonce, required List<int> mac, required String extension}) async {
    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(key),
    );
    final path = await newPath(extension);
    await File(path).writeAsBytes(clear, flush: true);
    return path;
  }

  /// Borra todos los adjuntos (botón de pánico).
  static Future<void> wipe() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static String extensionFor(String? mime, String? name) {
    if (name != null && p.extension(name).isNotEmpty) return p.extension(name).toLowerCase();
    return switch (mime) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/heic' => '.heic',
      'video/mp4' => '.mp4',
      'video/quicktime' => '.mov',
      'audio/mp4' || 'audio/m4a' || 'audio/aac' => '.m4a',
      _ => '.bin',
    };
  }

  static String mimeFor(String path) => switch (p.extension(path).toLowerCase()) {
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.png' => 'image/png',
        '.heic' => 'image/heic',
        '.gif' => 'image/gif',
        '.webp' => 'image/webp',
        '.mp4' => 'video/mp4',
        '.mov' => 'video/quicktime',
        '.m4v' => 'video/mp4',
        '.m4a' => 'audio/mp4',
        '.aac' => 'audio/aac',
        '.pdf' => 'application/pdf',
        _ => 'application/octet-stream',
      };
}
