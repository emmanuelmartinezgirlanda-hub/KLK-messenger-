/// Interruptores de funciones.
///
/// Recargas y "Enviar dinero" están apagados en la versión 1.0 de la App Store
/// porque aún no funcionan con un proveedor autorizado. El código sigue ahí:
/// para volver a mostrarlos, compila con `--dart-define=KLK_MONEY=true`
/// (o cambia el valor por defecto a `true`).
const bool kMoneyFeatures = bool.fromEnvironment('KLK_MONEY', defaultValue: false);

/// KLK Mi Gente: el muro público dentro de KLK (publicaciones, me gusta,
/// comentarios). Apagado en la App Store hasta que esté probado: se enciende
/// con `--dart-define=KLK_GENTE=true` (TestFlight lo lleva encendido).
const bool kGenteFeatures = bool.fromEnvironment('KLK_GENTE', defaultValue: false);
