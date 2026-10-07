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

  /// Se emite cada vez que el usuario hace una captura de pantalla (iPhone).
  static Stream<void> get screenshots =>
      supported ? _shots.receiveBroadcastStream().map((_) {}) : const Stream.empty();
}
