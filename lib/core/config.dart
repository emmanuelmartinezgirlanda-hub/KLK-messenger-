/// Configuración de compilación.
///
/// La dirección del servidor se fija al compilar:
///   flutter build ipa --dart-define=KLK_SERVER=https://api.tudominio.com
/// Si se deja vacía, la app arranca en **modo demo** (sin servidor, con
/// contactos y respuestas de ejemplo). El usuario también puede escribirla
/// en "Opciones avanzadas" de la pantalla de bienvenida.
abstract final class KlkConfig {
  static const String defaultServer = String.fromEnvironment('KLK_SERVER');

  /// Código de verificación aceptado en modo demo.
  static const String demoCode = '123456';
}
