import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// ¿Este iPhone tiene el «cristal líquido» de Apple (iOS 26 o más nuevo)?
final bool nativeGlassAvailable = () {
  if (kIsWeb || !Platform.isIOS) return false;
  final m = RegExp(r'(\d+)\.').firstMatch(Platform.operatingSystemVersion);
  return (int.tryParse(m?.group(1) ?? '') ?? 0) >= 26;
}();

/// Fondo de cristal nativo de Apple. Solo se usa si [nativeGlassAvailable].
class NativeGlass extends StatelessWidget {
  final double radius;
  final bool dark;
  const NativeGlass({super.key, required this.radius, required this.dark});

  @override
  Widget build(BuildContext context) => UiKitView(
        key: ValueKey('glass-$dark-$radius'),
        viewType: 'klk/glass',
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        creationParams: {'radius': radius, 'dark': dark},
        creationParamsCodec: const StandardMessageCodec(),
      );
}
