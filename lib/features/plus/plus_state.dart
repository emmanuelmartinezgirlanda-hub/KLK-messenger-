import 'package:flutter/foundation.dart';

/// KLK Plus encendido en esta compilación. En la App Store va apagado hasta que
/// las suscripciones estén activas en App Store Connect: entonces TODO es gratis
/// y no se ve nada de Plus. En TestFlight se enciende con --dart-define=KLK_PLUS=true.
const bool kPlusFeatures = bool.fromEnvironment('KLK_PLUS', defaultValue: false);

/// Estado de KLK Plus, accesible desde cualquier pantalla (también las que no
/// usan Riverpod, como el selector de stickers). Con Plus apagado, siempre «activo».
final plusActive = ValueNotifier<bool>(!kPlusFeatures);
final plusUntilNotifier = ValueNotifier<DateTime?>(null);

void setPlus(DateTime? until) {
  plusUntilNotifier.value = until;
  plusActive.value = !kPlusFeatures || (until != null && until.isAfter(DateTime.now()));
}
