import 'dart:io';

import 'package:flutter/services.dart';

/// Error legible de las funciones nativas.
class KlkNativeException implements Exception {
  final String code;
  final String message;
  const KlkNativeException(this.code, this.message);
  @override
  String toString() => message;
}

/// Funciones nativas de KLK. En Android (aún) no están disponibles.
class KlkNative {
  static const _channel = MethodChannel('klk/native');
  static const _shots = EventChannel('klk/screenshots');

  static bool get supported => Platform.isIOS;

  /// Pasa una nota de voz a texto en el propio iPhone (sin internet).
  static Future<String> transcribe(String path, {String locale = 'es-ES'}) async {
    if (!supported) {
      throw const KlkNativeException('unsupported', 'Pasar audios a texto de momento solo está en iPhone.');
    }
    try {
      final text = await _channel.invokeMethod<String>('transcribe', {'path': path, 'locale': locale});
      return (text ?? '').trim();
    } on PlatformException catch (e) {
      throw KlkNativeException(e.code, e.message ?? 'No se pudo pasar a texto');
    } on MissingPluginException {
      throw const KlkNativeException('unsupported', 'Esta versión de KLK no puede pasar audios a texto.');
    }
  }

  /// Comprime un vídeo en el propio iPhone (para estados largos).
  /// Si no se puede (Android o versión antigua), devuelve el archivo original.
  static Future<String> compressVideo(String path) async {
    if (!supported) return path;
    try {
      final out = await _channel.invokeMethod<String>('compressVideo', {'path': path});
      return (out == null || out.isEmpty) ? path : out;
    } on MissingPluginException {
      return path;
    } on PlatformException catch (e) {
      throw KlkNativeException(e.code, e.message ?? 'No se pudo preparar el vídeo');
    }
  }

  /// Quita el fondo de una foto (deja la persona u objeto) en el propio iPhone.
  /// Devuelve la ruta de un PNG transparente. Necesita iOS 17.
  static Future<String> liftSubject(String path) async {
    if (!supported) {
      throw const KlkNativeException('unsupported', 'Quitar el fondo de momento solo está en iPhone.');
    }
    try {
      final out = await _channel.invokeMethod<String>('liftSubject', {'path': path});
      if (out == null || out.isEmpty) throw const KlkNativeException('failed', 'No se pudo quitar el fondo');
      return out;
    } on PlatformException catch (e) {
      throw KlkNativeException(e.code, e.message ?? 'No se pudo quitar el fondo');
    } on MissingPluginException {
      throw const KlkNativeException('unsupported', 'Esta versión de KLK no puede quitar fondos.');
    }
  }

  /// Pide permiso de notificaciones y devuelve el token de APNs del iPhone
  /// (hexadecimal), o null si no hay permiso o no se pudo obtener.
  static Future<String?> pushToken() async {
    if (!supported) return null;
    try {
      return await _channel
          .invokeMethod<String>('pushToken')
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Se emite cada vez que el usuario hace una captura de pantalla (iPhone).
  static Stream<void> get screenshots =>
      supported ? _shots.receiveBroadcastStream().map((_) {}) : const Stream.empty();
}
