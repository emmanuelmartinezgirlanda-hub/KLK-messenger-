import 'package:flutter/foundation.dart';

/// Estado de KLK Plus, accesible desde cualquier pantalla (también las que no
/// usan Riverpod, como el selector de stickers).
final plusActive = ValueNotifier<bool>(false);
final plusUntilNotifier = ValueNotifier<DateTime?>(null);

void setPlus(DateTime? until) {
  plusUntilNotifier.value = until;
  plusActive.value = until != null && until.isAfter(DateTime.now());
}
