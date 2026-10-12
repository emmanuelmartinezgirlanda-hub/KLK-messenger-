import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../security/secure_store.dart';
import 'strings.dart';

/// Idiomas de KLK. El español es el original; el resto se traduce con [tr].
const supportedLanguages = <String, String>{
  'es': 'Español',
  'en': 'English',
  'it': 'Italiano',
  'fr': 'Français',
  'pt': 'Português',
};

String _lang = 'es';

/// Idioma en el que se está mostrando la app ahora mismo ('es', 'en'…).
String currentLanguageCode() => _lang;

void setCurrentLanguage(String code) {
  _lang = supportedLanguages.containsKey(code) ? code : 'es';
  Intl.defaultLocale = _lang;
}

/// Traduce un texto escrito en español al idioma actual.
/// Si falta la traducción, se queda en español.
String tr(String es) {
  if (_lang == 'es') return es;
  return translations[_lang]?[es] ?? es;
}

/// Primer idioma del móvil que KLK sabe hablar. Si ninguno, español.
String deviceLanguage([List<ui.Locale>? locales]) {
  for (final l in locales ?? ui.PlatformDispatcher.instance.locales) {
    if (supportedLanguages.containsKey(l.languageCode)) return l.languageCode;
  }
  return 'es';
}

/// Idioma elegido en Ajustes. null = automático (el del móvil).
final languageProvider = NotifierProvider<LanguageNotifier, String?>(LanguageNotifier.new);

class LanguageNotifier extends Notifier<String?> {
  static const _key = 'klk.language';

  @override
  String? build() {
    _restore();
    return null;
  }

  Future<void> _restore() async {
    final saved = await ref.read(secureStoreProvider).read(_key);
    if (saved != null && supportedLanguages.containsKey(saved)) state = saved;
  }

  /// null = seguir el idioma del móvil.
  Future<void> choose(String? code) async {
    state = code;
    final store = ref.read(secureStoreProvider);
    if (code == null) {
      await store.delete(_key);
    } else {
      await store.write(_key, code);
    }
  }
}
