import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

final translatorProvider = ChangeNotifierProvider<KlkTranslator>((_) => KlkTranslator());

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

  /// Traduce al español un mensaje recibido.
  Future<void> translateIncoming(String messageId, String text) async {
    if (working.contains(messageId)) return;
    working.add(messageId);
    notifyListeners();
    try {
      final id = LanguageIdentifier(confidenceThreshold: 0.4);
      final code = await id.identifyLanguage(text);
      await id.close();
      final from = _byCode[code];
      if (code == 'es') {
        results[messageId] = 'Ya está en español';
      } else if (from == null) {
        results[messageId] = 'No reconozco este idioma';
      } else {
        results[messageId] = await _translate(text, from, TranslateLanguage.spanish);
      }
    } catch (e) {
      debugPrint('Traducir: $e');
      results[messageId] = 'No se pudo traducir. Revisa tu conexión la primera vez.';
    } finally {
      working.remove(messageId);
      notifyListeners();
    }
  }

  /// Traduce lo que estoy escribiendo (español -> otro idioma).
  Future<String> translateOutgoing(String text, TranslateLanguage to) =>
      _translate(text, TranslateLanguage.spanish, to);
}
