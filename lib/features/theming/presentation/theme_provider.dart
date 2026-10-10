import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/security/secure_store.dart';
import '../domain/klk_theme.dart';

/// Gestor del tema global. Persiste el tema elegido de forma cifrada.
final themeProvider =
    NotifierProvider<ThemeNotifier, KlkTheme>(ThemeNotifier.new);

class ThemeNotifier extends Notifier<KlkTheme> {
  static const _key = 'klk.theme';

  @override
  KlkTheme build() {
    _restore();
    return KlkTheme.auto; // por defecto: claro u oscuro según el móvil
  }

  Future<void> _restore() async {
    final saved = await ref.read(secureStoreProvider).read(_key);
    if (saved != null) state = KlkTheme.decode(saved);
  }

  Future<void> apply(KlkTheme theme) async {
    state = theme;
    await ref.read(secureStoreProvider).write(_key, theme.encode());
  }

  /// Importa un tema compartido por otro usuario (JSON).
  Future<void> importFromJson(String json) => apply(KlkTheme.decode(json));

  String exportCurrent() => state.encode();
}
