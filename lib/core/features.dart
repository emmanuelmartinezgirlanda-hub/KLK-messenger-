/// Interruptores de funciones.
///
/// Recargas y "Enviar dinero" están apagados en la versión 1.0 de la App Store
/// porque aún no funcionan con un proveedor autorizado. El código sigue ahí:
/// para volver a mostrarlos, compila con `--dart-define=KLK_MONEY=true`
/// (o cambia el valor por defecto a `true`).
const bool kMoneyFeatures = bool.fromEnvironment('KLK_MONEY', defaultValue: false);
