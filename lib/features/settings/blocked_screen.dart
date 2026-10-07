import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../messaging/app_controller.dart';

/// Lista de contactos bloqueados, con opción de desbloquear.
class BlockedScreen extends ConsumerWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final list = app.blockedChats;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Contactos bloqueados')),
      body: list.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No has bloqueado a nadie.\nPara bloquear, entra en el chat → ⋮ → Bloquear.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
                ),
              ),
            )
          : ListView(children: [
              for (final c in list)
                ListTile(
                  leading: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath),
                  title: Text(c.title),
                  subtitle: c.phone.isEmpty ? null : Text(prettyPhone(c.phone)),
                  trailing: TextButton(
                    onPressed: () => app.setBlocked(c.id, false),
                    child: const Text('Desbloquear'),
                  ),
                ),
            ]),
    );
  }
}
