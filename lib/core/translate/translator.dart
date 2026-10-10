import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../security/secure_store.dart';

final translatorProvider = ChangeNotifierProvider<KlkTranslator>((_) => KlkTranslator()..load());

/// Idiomas que más usa la diáspora dominicana.
const translateTargets = <String, TranslateLanguage>{
  'Inglés': TranslateLanguage.english,
  'Italiano': TranslateLanguage.italian,
  'Alemán': TranslateLanguage.german,
  'Francés': TranslateLanguage.french,
  'Portugués': TranslateLanguage.portuguese,
  'Neerlandés': TranslateLanguage.dutch,
  'Catalán': TranslateLanguage.catalan,
};

/// Idiomas a los que se pueden traducir los mensajes que me llegan ("mi idioma").
const myLanguages = <String, TranslateLanguage>{
  'Español': TranslateLanguage.spanish,
  ...translateTargets,
};

const _byCode = <String, TranslateLanguage>{
  'es': TranslateLanguage.spanish,
  'en': TranslateLanguage.english,
  'it': TranslateLanguage.italian,
  'de': TranslateLanguage.german,
  'fr': TranslateLanguage.french,
  'pt': TranslateLanguage.portuguese,
  'nl': TranslateLanguage.dutch,
  'ca': TranslateLanguage.catalan,
};

/// Traductor que funciona DENTRO del móvil (Google ML Kit).
/// Los mensajes no se envían a ningún servidor para traducirlos.
/// La primera vez descarga el idioma (~30 MB).
class KlkTranslator extends ChangeNotifier {
  final Map<String, String> results = {}; // id de mensaje -> traducción
  final Set<String> working = {};
  final Set<String> _autoTried = {}; // mensajes ya revisados por la traducción automática

  static const _autoKey = 'klk.translate.auto';
  static const _langKey = 'klk.translate.lang';
  final _store = SecureStore();

  /// Traducir solos los mensajes que llegan en otro idioma.
  bool auto = false;

  /// Idioma al que traduzco (por defecto, español).
  TranslateLanguage myLanguage = TranslateLanguage.spanish;

  String get myLanguageName =>
      myLanguages.entries.firstWhere((e) => e.value == myLanguage, orElse: () => myLanguages.entries.first).key;

  Future<void> load() async {
    try {
      auto = await _store.read(_autoKey) == '1';
      final code = await _store.read(_langKey);
      final lang = myLanguages.values.where((l) => l.bcpCode == code).firstOrNull;
      if (lang != null) myLanguage = lang;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setAuto(bool on) async {
    auto = on;
    _autoTried.clear();
    notifyListeners();
    try {
      await _store.write(_autoKey, on ? '1' : '0');
    } catch (_) {}
  }

  Future<void> setMyLanguage(TranslateLanguage lang) async {
    myLanguage = lang;
    // Las traducciones hechas a otro idioma ya no sirven
    results.clear();
    _autoTried.clear();
    notifyListeners();
    try {
      await _store.write(_langKey, lang.bcpCode);
    } catch (_) {}
  }

  /// Traducción automática: se llama al mostrar un mensaje recibido.
  void autoTranslate(String messageId, String text) {
    if (!auto || text.trim().length < 4) return;
    if (_autoTried.contains(messageId) || results.containsKey(messageId) || working.contains(messageId)) return;
    _autoTried.add(messageId);
    // Después de pintar, para no notificar en mitad de la construcción de la lista
    Future.microtask(() => translateIncoming(messageId, text, automatic: true));
  }

  Future<String> _translate(String text, TranslateLanguage from, TranslateLanguage to) async {
    final models = OnDeviceTranslatorModelManager();
    for (final lang in {from, to}) {
      if (!await models.isModelDownloaded(lang.bcpCode)) {
        await models.downloadModel(lang.bcpCode, isWifiRequired: false);
      }
    }
    final t = OnDeviceTranslator(sourceLanguage: from, targetLanguage: to);
    try {
      return await t.translateText(text);
    } finally {
      await t.close();
    }
  }

  /// Traduce a mi idioma un mensaje recibido.
  /// Si es automática y el mensaje ya está en mi idioma (o no se reconoce), no enseña nada.
  Future<void> translateIncoming(String messageId, String text, {bool automatic = false}) async {
    if (working.contains(messageId)) return;
    working.add(messageId);
    if (!automatic) notifyListeners();
    try {
      final id = LanguageIdentifier(confidenceThreshold: automatic ? 0.6 : 0.4);
      final code = await id.identifyLanguage(text);
      await id.close();
      final from = _byCode[code];
      if (code == myLanguage.bcpCode) {
        if (!automatic) results[messageId] = 'Ya está en ${myLanguageName.toLowerCase()}';
      } else if (from == null) {
        if (!automatic) results[messageId] = 'No reconozco este idioma';
      } else {
        results[messageId] = await _translate(text, from, myLanguage);
      }
    } catch (e) {
      debugPrint('Traducir: $e');
      if (!automatic) results[messageId] = 'No se pudo traducir. Revisa tu conexión la primera vez.';
    } finally {
      working.remove(messageId);
      notifyListeners();
    }
  }

  /// Traduce lo que estoy escribiendo (español -> otro idioma).
  Future<String> translateOutgoing(String text, TranslateLanguage to) =>
      _translate(text, TranslateLanguage.spanish, to);
}
