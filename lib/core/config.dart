/// Configuración de compilación.
///
/// La dirección del servidor se fija al compilar:
///   flutter build ipa --dart-define=KLK_SERVER=https://api.tudominio.com
/// Si se deja vacía, la app arranca en **modo demo** (sin servidor, con
/// contactos y respuestas de ejemplo). El usuario también puede escribirla
/// en "Opciones avanzadas" de la pantalla de bienvenida.
abstract final class KlkConfig {
  static const String _serverFromBuild = String.fromEnvironment('KLK_SERVER');

  /// Servidor oficial de KLK messenger. Si se vacía el campo en
  /// "Opciones avanzadas", la app entra en modo demo.
  static const String officialServer = 'https://klk-server.onrender.com';
  static const String defaultServer = _serverFromBuild == '' ? officialServer : _serverFromBuild;

  /// Servidor TURN para llamadas cuando los dos móviles no pueden conectarse
  /// directamente (pasa en algunas redes móviles). Opcional:
  ///   --dart-define=KLK_TURN_URL=turn:turn.tudominio.com:3478
  ///   --dart-define=KLK_TURN_USER=... --dart-define=KLK_TURN_PASS=...
  static const String turnUrl = String.fromEnvironment('KLK_TURN_URL');
  static const String turnUser = String.fromEnvironment('KLK_TURN_USER');
  static const String turnPass = String.fromEnvironment('KLK_TURN_PASS');

  /// Firebase (solo Android, para los avisos push). Son las claves públicas
  /// del proyecto que salen en google-services.json; no son secretas.
  static const String _fcmApiKey =
      String.fromEnvironment('KLK_FCM_API_KEY', defaultValue: 'AIzaSyBXbgMXdNEJ3nq1JfBxIKs8nO2n3IeUMT0');
  static const String _fcmAppId =
      String.fromEnvironment('KLK_FCM_APP_ID', defaultValue: '1:297744925319:android:74bfd3ecff921793c6ae22');
  static const String _fcmProject = String.fromEnvironment('KLK_FCM_PROJECT', defaultValue: 'klk-messenger-2fd3a');
  static const String _fcmSender = String.fromEnvironment('KLK_FCM_SENDER', defaultValue: '297744925319');

  /// Datos de Firebase para KlkNative.registerPush, o null si no hay.
  static Map<String, String>? get firebase => _fcmAppId.isEmpty || _fcmApiKey.isEmpty
      ? null
      : {'apiKey': _fcmApiKey, 'appId': _fcmAppId, 'projectId': _fcmProject, 'senderId': _fcmSender};

  /// Código de verificación aceptado en modo demo.
  static const String demoCode = '123456';
}
