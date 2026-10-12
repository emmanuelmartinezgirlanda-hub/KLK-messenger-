import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../messaging/app_controller.dart';
import 'chat_avatar.dart';
import 'chat_list_view.dart';
import 'chat_screen.dart';
import '../../../core/l10n/l10n.dart';

/// Chats archivados. Deslizar o dejar pulsado para desarchivar.
class ArchivedScreen extends ConsumerWidget {
  const ArchivedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final list = app.archivedChats;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Archivados'))),
      body: list.isEmpty
          ? Center(
              child: Text(tr('No tienes chats archivados'),
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
            )
          : ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(tr('Deja pulsado un chat para sacarlo de aquí.'),
                    style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
              ),
              for (final c in list)
                ListTile(
                  leading: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath),
                  title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(c.lastText, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(chatTime(c.updatedAt), style: const TextStyle(fontSize: 12)),
                    if (c.unread > 0)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(10)),
                        child: Text('${c.unread}', style: TextStyle(color: cs.onPrimary, fontSize: 11.5)),
                      ),
                  ]),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: c.id))),
                  onLongPress: () async {
                    await app.setArchived(c.id, false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('«${c.title}» vuelve a la lista de chats')));
                    }
                  },
                ),
            ]),
    );
  }
}
