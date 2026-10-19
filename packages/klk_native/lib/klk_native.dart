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

  /// Activa los avisos push del iPhone: pide permiso y devuelve el token de
  /// Apple (hexadecimal), o null si no hay permiso o no está disponible.
  static Future<String?> registerPush() async {
    if (!supported) return null;
    try {
      return await _channel
          .invokeMethod<String>('registerPush')
          .timeout(const Duration(seconds: 30), onTimeout: () => null);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      throw KlkNativeException(e.code, e.message ?? 'No se pudieron activar los avisos');
    }
  }

  /// ¿Es una versión de prueba? (TestFlight en iPhone; en Android, el APK de
  /// pruebas compilado con --dart-define=KLK_TEST=true). Las tiendas no permiten
  /// activar funciones de pago con códigos, así que eso solo sale en pruebas.
  static Future<bool> isTestBuild() async {
    if (Platform.isAndroid) return const bool.fromEnvironment('KLK_TEST');
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isTestFlight') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Iconos alternativos de la app (solo iPhone por ahora).
  static bool get supportsAppIcons => supported;

  /// Cambia el icono de la app. null = el normal.
  static Future<void> setAppIcon(String? name) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('setAppIcon', {'name': name});
    } on PlatformException catch (e) {
      throw KlkNativeException(e.code, e.message ?? 'No se pudo cambiar el icono');
    } on MissingPluginException {
      throw const KlkNativeException('unsupported', 'Esta versión de KLK no puede cambiar el icono.');
    }
  }

  /// Icono actual (null = el normal).
  static Future<String?> appIcon() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('getAppIcon');
    } catch (_) {
      return null;
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

  /// Se emite cada vez que el usuario hace una captura de pantalla (iPhone).
  static Stream<void> get screenshots =>
      supported ? _shots.receiveBroadcastStream().map((_) {}) : const Stream.empty();
}
