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
  static const _captions = EventChannel('klk/captions');

  /// Subtítulos de llamada: lo que dice la persona por el micrófono, en directo
  /// y pasado a texto dentro del iPhone. Cada evento: (texto, esFinal).
  static Stream<(String, bool)> get liveCaptions => supported
      ? _captions.receiveBroadcastStream().map((e) {
          final m = (e as Map).cast<String, dynamic>();
          return ((m['t'] as String?) ?? '', m['f'] == true);
        })
      : const Stream.empty();

  /// Empieza a pasar mi voz a texto (p. ej. locale "es-US"). Lanza KlkNativeException si no se puede.
  static Future<void> startLiveCaptions(String locale) async {
    if (!supported) {
      throw const KlkNativeException('unsupported', 'Los subtítulos de momento solo están en iPhone.');
    }
    try {
      await _channel.invokeMethod('startLiveCaptions', {'locale': locale});
    } on PlatformException catch (e) {
      throw KlkNativeException(e.code, e.message ?? 'No se pudieron activar los subtítulos');
    } on MissingPluginException {
      throw const KlkNativeException('unsupported', 'Esta versión de KLK no tiene subtítulos.');
    }
  }

  static Future<void> stopLiveCaptions() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('stopLiveCaptions');
    } catch (_) {}
  }

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

  /// Activa los avisos push: pide permiso y devuelve el token, o null si no
  /// hay permiso o no está disponible. En iPhone es el token de Apple
  /// (hexadecimal); en Android, el de Firebase, y hace falta [android] con las
  /// claves públicas del proyecto (apiKey, appId, projectId, senderId).
  static Future<String?> registerPush({Map<String, String>? android}) async {
    if (Platform.isAndroid) {
      if (android == null || (android['appId'] ?? '').isEmpty) return null;
      try {
        return await _channel
            .invokeMethod<String>('registerPush', android)
            .timeout(const Duration(seconds: 60), onTimeout: () => null);
      } on MissingPluginException {
        return null;
      } on PlatformException catch (e) {
        throw KlkNativeException(e.code, e.message ?? 'No se pudieron activar los avisos');
      }
    }
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
    // Solo las compilaciones de prueba (KLK_TEST=true). Ojo: los revisores de
    // Apple también tienen recibo de «sandbox», así que eso solo no basta.
    if (!const bool.fromEnvironment('KLK_TEST')) return false;
    if (Platform.isAndroid) return true;
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

  // ---------- KLK Plus con Apple (StoreKit 2) o Google Play (Android) ----------

  /// ¿Se puede comprar Plus en este móvil (App Store en iPhone, Google Play en Android)?
  static bool get supportsStore => Platform.isIOS || Platform.isAndroid;

  /// ¿La tienda es Google Play? (si no, la App Store de Apple)
  static bool get isGooglePlay => Platform.isAndroid;

  /// Productos de la tienda: [{id, price, title, unit, count, trialUnit, trialCount}].
  static Future<List<Map<String, dynamic>>> storeProducts(List<String> ids) async {
    if (!supportsStore) return const [];
    try {
      final list = await _channel.invokeListMethod<Map<Object?, Object?>>('storeProducts', {'ids': ids});
      return [for (final m in list ?? const <Map<Object?, Object?>>[]) m.map((k, v) => MapEntry('$k', v))];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Compra: abre la hoja de pago de la tienda. Devuelve la compra firmada
  /// (JWS en iPhone) o el «purchase token» de Google Play (Android).
  static Future<String> storeBuy(String productId, {String? accountId}) async {
    try {
      final jws = await _channel.invokeMethod<String>('storeBuy', {'id': productId, 'account': accountId});
      if (jws == null) throw const KlkNativeException('store', 'No se pudo comprar');
      return jws;
    } on PlatformException catch (e) {
      throw KlkNativeException(e.code, e.message ?? 'No se pudo comprar');
    } on MissingPluginException {
      throw const KlkNativeException('unsupported', 'Actualiza KLK para comprar Plus.');
    }
  }

  /// Suscripciones activas (JWS o tokens de Google). [sync] = «Restaurar compras».
  static Future<List<String>> storeEntitlements({bool sync = false}) async {
    if (!supportsStore) return const [];
    try {
      return await _channel.invokeListMethod<String>('storeEntitlements', {'sync': sync}) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Abre «Gestionar suscripción» de la tienda (cancelar, cambiar plan).
  static Future<void> storeManage() async {
    if (!supportsStore) return;
    try {
      await _channel.invokeMethod('storeManage');
    } catch (_) {}
  }
}
