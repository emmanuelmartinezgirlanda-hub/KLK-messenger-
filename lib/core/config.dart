/// Configuración de compilación.
///
/// La dirección del servidor se fija al compilar:
///   flutter build ipa --dart-define=KLK_SERVER=https://api.tudominio.com
/// Si se deja vacía, la app arranca en **modo demo** (sin servidor, con
/// contactos y respuestas de ejemplo). El usuario también puede escribirla
/// en "Opciones avanzadas" de la pantalla de bienvenida.
abstract final class KlkConfig {
  static const String defaultServer = String.fromEnvironment('KLK_SERVER');

  /// Servidor TURN para llamadas cuando los dos móviles no pueden conectarse
  /// directamente (pasa en algunas redes móviles). Opcional:
  ///   --dart-define=KLK_TURN_URL=turn:turn.tudominio.com:3478
  ///   --dart-define=KLK_TURN_USER=... --dart-define=KLK_TURN_PASS=...
  static const String turnUrl = String.fromEnvironment('KLK_TURN_URL');
  static const String turnUser = String.fromEnvironment('KLK_TURN_USER');
  static const String turnPass = String.fromEnvironment('KLK_TURN_PASS');

  /// Código de verificación aceptado en modo demo.
  static const String demoCode = '123456';
}
