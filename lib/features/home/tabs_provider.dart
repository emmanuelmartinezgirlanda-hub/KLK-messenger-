import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/secure_store.dart';

/// Pestañas que el usuario ha ocultado (Ajustes → Pestañas).
/// Chats y Ajustes no se pueden ocultar.
class HiddenTabs {
  final bool status;
  final bool communities;
  const HiddenTabs({this.status = false, this.communities = false});
}

final hiddenTabsProvider = NotifierProvider<HiddenTabsNotifier, HiddenTabs>(HiddenTabsNotifier.new);

class HiddenTabsNotifier extends Notifier<HiddenTabs> {
  static const _key = 'klk.hiddenTabs';

  @override
  HiddenTabs build() {
    _restore();
    return const HiddenTabs();
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(secureStoreProvider).read(_key) ?? '';
      state = HiddenTabs(status: v.contains('s'), communities: v.contains('c'));
    } catch (_) {}
  }

  Future<void> set(HiddenTabs t) async {
    state = t;
    try {
      await ref.read(secureStoreProvider).write(_key, '${t.status ? 's' : ''}${t.communities ? 'c' : ''}');
    } catch (_) {}
  }
}
