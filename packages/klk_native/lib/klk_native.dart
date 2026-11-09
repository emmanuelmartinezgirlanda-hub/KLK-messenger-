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
  /// Modo belleza en videollamadas (detecta la cara y suaviza la piel antes de enviar
  /// el vídeo). [level] de 0 (apagado) a 1. Devuelve false si no se pudo aplicar.
  static bool get supportsBeauty => supported;
  static Future<bool> setBeauty(String trackId, double level) async {
    if (!supportsBeauty) return false;
    try {
      return await _channel.invokeMethod<bool>('setBeauty', {'track': trackId, 'level': level}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> removeBeauty(String trackId) async {
    if (!supportsBeauty) return;
    try {
      await _channel.invokeMethod('removeBeauty', {'track': trackId});
    } catch (_) {}
  }

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

  // ---------- Apple Watch (walkie-talkie) ----------

  static const _watch = EventChannel('klk/watch');

  /// Grabaciones que manda el reloj: {type, chatId, ms, path}.
  static Stream<Map<String, dynamic>> get watchEvents => supported
      ? _watch.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map))
      : const Stream.empty();

  /// Pasa al reloj la lista de contactos para el walkie: [{id, title}].
  static Future<void> watchContacts(List<Map<String, String>> contacts) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('watchContacts', {'contacts': contacts});
    } catch (_) {}
  }

  /// Hace sonar en el reloj un audio de walkie que acaba de llegar.
  static Future<void> watchPlay(String path, {required String chatId, required String from}) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('watchPlay', {'path': path, 'chatId': chatId, 'from': from});
    } catch (_) {}
  }

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

/// Llamadas con el móvil bloqueado: en iPhone con PushKit + CallKit; en Android
/// con un aviso de Firebase que enseña la llamada a pantalla completa.
///
/// El iPhone avisa a Dart cuando:
/// - [onToken]: tiene el token VoIP (hay que dárselo al servidor).
/// - [onIncoming]: está enseñando una llamada (con la pantalla del iPhone).
/// - [onAnswer] / [onEnd]: la persona contestó o colgó desde esa pantalla.
class KlkCalls {
  static const _ch = MethodChannel('klk/calls');

  static void Function(String token)? onToken;
  static void Function(String id, bool video, String from)? onIncoming;
  static void Function(String id)? onAnswer;
  static void Function(String id)? onEnd;
  /// Android: KLK se abrió tocando la pantalla de llamada (sin contestar aún).
  static void Function(String id)? onOpen;

  static bool _started = false;

  /// Empieza a escuchar al iPhone. Los avisos que llegaron antes se entregan ahora.
  static Future<void> start() async {
    if (!(Platform.isIOS || Platform.isAndroid) || _started) return;
    _started = true;
    _ch.setMethodCallHandler((call) async {
      final a = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
      final id = (a['id'] as String?) ?? '';
      switch (call.method) {
        case 'token':
          onToken?.call((a['token'] as String?) ?? '');
        case 'incoming':
          onIncoming?.call(id, a['video'] == true, (a['from'] as String?) ?? '');
        case 'answer':
          onAnswer?.call(id);
        case 'end':
          onEnd?.call(id);
        case 'open':
          onOpen?.call(id);
      }
      return null;
    });
    try {
      await _ch.invokeMethod('ready');
    } on MissingPluginException {
      _started = false;
    } catch (_) {}
  }

  static Future<String?> voipToken() => _call<String>('voipToken');

  /// ¿Está sonando esta llamada con la pantalla del iPhone?
  static Future<bool> has(String id) async => (await _call<bool>('has', {'id': id})) ?? false;

  /// Contesté desde la pantalla de KLK.
  static Future<void> answered(String id) => _call<void>('answered', {'id': id});

  /// La llamada terminó (reason: remote, unanswered, declined, failed).
  static Future<void> end(String id, {String reason = 'remote'}) =>
      _call<void>('end', {'id': id, 'reason': reason});

  static Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    if (!(Platform.isIOS || Platform.isAndroid)) return null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }
}
