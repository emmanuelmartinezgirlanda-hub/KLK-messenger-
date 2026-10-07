import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/privacy_settings.dart';
import 'privacy_provider.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(privacyProvider);
    final notifier = ref.read(privacyProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Privacidad')),
      body: ListView(
        children: [
          const _Section('Presencia'),
          ListTile(
            leading: const Icon(Icons.access_time),
            title: const Text('Última conexión'),
            subtitle: Text(_audienceLabel(s.lastSeen)),
            trailing: DropdownButton<Audience>(
              value: s.lastSeen,
              underline: const SizedBox.shrink(),
              items: Audience.values
                  .map((a) => DropdownMenuItem(value: a, child: Text(_audienceLabel(a))))
                  .toList(),
              onChanged: (a) => notifier.update(s.copyWith(lastSeen: a)),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.done_all),
            title: const Text('Ocultar confirmaciones de lectura'),
            subtitle: const Text('Si lo activas, tampoco verás las de los demás.'),
            value: s.hideReadReceipts,
            onChanged: (v) => notifier.update(s.copyWith(hideReadReceipts: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.keyboard),
            title: const Text('Ocultar "escribiendo..."'),
            value: s.hideTyping,
            onChanged: (v) => notifier.update(s.copyWith(hideTyping: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.mic_none),
            title: const Text('Ocultar "grabando audio..."'),
            value: s.hideRecording,
            onChanged: (v) => notifier.update(s.copyWith(hideRecording: v)),
          ),
          const _Section('Estados'),
          SwitchListTile(
            secondary: const Icon(Icons.download_outlined),
            title: const Text('Permitir que guarden mis estados'),
            subtitle: const Text('Te avisaremos cuando alguien guarde uno.'),
            value: s.allowStorySaving,
            onChanged: (v) => notifier.update(s.copyWith(allowStorySaving: v)),
          ),
          const _Section('Seguridad'),
          SwitchListTile(
            secondary: const Icon(Icons.lock_outline),
            title: const Text('Bloquear KLK con PIN o huella'),
            value: s.appLock,
            onChanged: (v) => notifier.update(s.copyWith(appLock: v)),
          ),
        ],
      ),
    );
  }

  static String _audienceLabel(Audience a) => switch (a) {
        Audience.todos => 'Todo el mundo',
        Audience.contactos => 'Mis contactos',
        Audience.nadie => 'Nadie',
      };
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
              ),
        ),
      );
}
