import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/privacy_settings.dart';
import '../../lock/app_lock.dart';
import '../../messaging/app_controller.dart';
import '../../settings/blocked_screen.dart';
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
            secondary: const Icon(Icons.face_unlock_outlined),
            title: const Text('Bloquear KLK con Face ID'),
            subtitle: const Text('Al abrir KLK, o al volver tras 30 segundos fuera'),
            value: s.appLock,
            onChanged: (v) async {
              if (v) {
                final messenger = ScaffoldMessenger.of(context);
                if (!await AppLockService.available()) {
                  messenger.showSnackBar(const SnackBar(
                      content: Text('Configura Face ID o un código en tu iPhone para poder bloquear KLK.')));
                  return;
                }
                // Confirmo que funciona antes de activarlo, para no quedarte fuera.
                if (!await AppLockService.authenticate('Confirma para activar el bloqueo de KLK')) return;
              }
              await notifier.update(s.copyWith(appLock: v));
            },
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Contactos bloqueados'),
            subtitle: Consumer(builder: (_, ref, __) {
              final n = ref.watch(appProvider).blockedChats.length;
              return Text(n == 0 ? 'Ninguno' : '$n bloqueado${n == 1 ? '' : 's'}');
            }),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BlockedScreen())),
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
