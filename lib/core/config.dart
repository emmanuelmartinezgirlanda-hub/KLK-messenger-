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

  /// Código de verificación aceptado en modo demo.
  static const String demoCode = '123456';
}
