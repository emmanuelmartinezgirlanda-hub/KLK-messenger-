import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/security/secure_store.dart';
import '../domain/privacy_settings.dart';

final privacyProvider =
    NotifierProvider<PrivacyNotifier, PrivacySettings>(PrivacyNotifier.new);

class PrivacyNotifier extends Notifier<PrivacySettings> {
  static const _key = 'klk.privacy';

  @override
  PrivacySettings build() {
    _restore();
    return const PrivacySettings();
  }

  Future<void> _restore() async {
    final saved = await ref.read(secureStoreProvider).read(_key);
    if (saved != null) state = PrivacySettings.decode(saved);
  }

  Future<void> update(PrivacySettings s) async {
    state = s;
    await ref.read(secureStoreProvider).write(_key, s.encode());
  }
}
