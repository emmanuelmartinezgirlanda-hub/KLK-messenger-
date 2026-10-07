import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/security/secure_store.dart';
import '../domain/privacy_settings.dart';

final privacyProvider =
    NotifierProvider<PrivacyNotifier, PrivacySettings>(PrivacyNotifier.new);

class PrivacyNotifier extends Notifier<PrivacySettings> {
  static const _key = 'klk.privacy';
  final _loaded = Completer<void>();

  /// Se completa cuando ya se han leído los ajustes guardados.
  Future<void> get loaded => _loaded.future;

  @override
  PrivacySettings build() {
    _restore();
    return const PrivacySettings();
  }

  Future<void> _restore() async {
    try {
      final saved = await ref.read(secureStoreProvider).read(_key);
      if (saved != null) state = PrivacySettings.decode(saved);
    } catch (_) {
      // Si no se pueden leer, se quedan los valores por defecto.
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
  }

  Future<void> update(PrivacySettings s) async {
    state = s;
    await ref.read(secureStoreProvider).write(_key, s.encode());
  }
}
