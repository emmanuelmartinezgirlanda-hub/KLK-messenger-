import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../messaging/app_controller.dart';

/// Código de seguridad de un chat: los dos móviles ven los mismos 60 números.
/// Si coinciden al compararlos en persona, nadie está espiando en medio.
class SafetyNumberScreen extends ConsumerWidget {
  final String chatId;
  const SafetyNumberScreen({super.key, required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final chat = app.chatById(chatId);
    final number = app.safetyNumber(chatId);
    final groups = <String>[
      if (number != null)
        for (var i = 0; i + 5 <= number.length; i += 5) number.substring(i, i + 5),
    ];
    final signal = app.usesSignal(chatId);
    return Scaffold(
      appBar: AppBar(title: const Text('Código de seguridad')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Icon(Icons.lock_outline, size: 56, color: cs.primary),
        const SizedBox(height: 12),
        Text('Cifrado de punta a punta con ${chat?.title ?? 'este contacto'}',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          signal
              ? 'Vuestros mensajes usan el Signal Protocol: cada mensaje lleva una clave nueva.'
              : 'Este contacto tiene una versión vieja de KLK. Pídele que la actualice para usar el cifrado nuevo.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: 24),
        if (groups.isEmpty)
          const Text('Todavía no hay código: escríbele primero.', textAlign: TextAlign.center)
        else
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.2,
              children: [
                for (final g in groups)
                  Center(
                    child: Text(g,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Text(
          'Compara estos números con los que ve tu contacto en su móvil (KLK → chat → ⋮ → Código de seguridad). '
          'Si son iguales, nadie puede leer vuestros mensajes. Si cambian, puede que haya reinstalado KLK.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, color: cs.onSurface.withValues(alpha: 0.7)),
        ),
        if (number != null) ...[
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: groups.join(' ')));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Código copiado')));
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copiar el código'),
          ),
        ],
      ]),
    );
  }
}
