import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';

/// Este número se abrió en otro dispositivo: aquí la sesión ya no vale.
/// KLK es, de momento, de un solo dispositivo por número (como WhatsApp antes).
class SessionClosedScreen extends ConsumerWidget {
  const SessionClosedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final phone = app.session?.phone;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Icon(Icons.devices_other_rounded, size: 72, color: cs.primary),
            const SizedBox(height: 24),
            const Text('Tu KLK se abrió en otro dispositivo',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            Text(
              'Entraste con ${phone == null ? 'tu número' : prettyPhone(phone)} en otro móvil u ordenador. '
              'De momento KLK funciona en un solo dispositivo por número, así que aquí se cerró la sesión.\n\n'
              'Tus chats siguen guardados en este móvil. Si vuelves a entrar aquí, se cerrará en el otro.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, height: 1.4, color: cs.onSurface.withValues(alpha: 0.8)),
            ),
            const Spacer(),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => ref.read(appProvider).signInAgain(),
              child: const Text('Volver a entrar en este dispositivo'),
            ),
            const SizedBox(height: 10),
            Text('Usar KLK en varios dispositivos a la vez llegará con KLK Plus.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
          ]),
        ),
      ),
    );
  }
}
