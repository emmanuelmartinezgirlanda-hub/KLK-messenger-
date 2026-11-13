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

/// Walkie-talkie: mantener pulsado para hablar; al otro le suena sola.
/// Está en todas las versiones, pero cada persona lo tiene que ACTIVAR en
/// Ajustes (apagado de fábrica): así ningún audio suena solo sin que lo pidas.
/// Para quitarlo del todo: `--dart-define=KLK_WALKIE=false`.
const bool kWalkieFeatures = bool.fromEnvironment('KLK_WALKIE', defaultValue: true);

/// Llamadas y videollamadas en grupo (hasta 4 personas). De momento solo en
/// las versiones de prueba (TestFlight lleva KLK_TEST).
const bool kGroupCalls =
    bool.fromEnvironment('KLK_GROUP_CALLS', defaultValue: bool.fromEnvironment('KLK_TEST'));
