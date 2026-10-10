import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../../core/translate/translator.dart';

/// Ajustes → Traductor: traducción automática y el idioma al que traducir.
class TranslatorSettingsScreen extends ConsumerWidget {
  const TranslatorSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translatorProvider);
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Scaffold(
      appBar: AppBar(title: const Text('Traductor')),
      body: ListView(children: [
        SwitchListTile(
          secondary: const Icon(Icons.auto_awesome_outlined),
          title: const Text('Traducir automáticamente'),
          subtitle: Text('Si alguien te escribe en otro idioma, verás debajo la traducción al '
              '${t.myLanguageName.toLowerCase()}'),
          value: t.auto,
          onChanged: (v) => ref.read(translatorProvider).setAuto(v),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Mi idioma', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        RadioGroupCompat(
          selected: t.myLanguage.bcpCode,
          options: {for (final e in myLanguages.entries) e.value.bcpCode: e.key},
          onChanged: (code) {
            final lang = myLanguages.values.firstWhere((l) => l.bcpCode == code);
            ref.read(translatorProvider).setMyLanguage(lang);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Text(
            'La traducción se hace dentro de tu móvil: los mensajes no se envían a ningún servidor. '
            'La primera vez que traduce de un idioma descarga ese idioma (unos 30 MB).',
            style: TextStyle(fontSize: 13, color: muted),
          ),
        ),
      ]),
    );
  }
}

/// Lista de opciones con una marca en la elegida (sin depender de la API de Radio,
/// que cambia entre versiones de Flutter).
class RadioGroupCompat extends StatelessWidget {
  final String selected;
  final Map<String, String> options; // valor -> texto
  final ValueChanged<String> onChanged;
  const RadioGroupCompat({super.key, required this.selected, required this.options, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      for (final e in options.entries)
        ListTile(
          title: Text(e.value),
          trailing: e.key == selected ? Icon(Icons.check_circle, color: cs.secondary) : const Icon(Icons.circle_outlined),
          selected: e.key == selected,
          onTap: () => onChanged(e.key),
        ),
    ]);
  }
}
