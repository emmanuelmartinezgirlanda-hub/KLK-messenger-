import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import 'chat_screen.dart';
import 'new_chat_sheet.dart';

const _avatarColors = [
  Color(0xFFCE1126), Color(0xFF00A6B4), Color(0xFF6A2C91),
  Color(0xFF1F7A4D), Color(0xFFC46A00), Color(0xFF002D62),
];

Color avatarColor(String id) => _avatarColors[id.hashCode.abs() % _avatarColors.length];

String chatTime(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (!t.isBefore(today)) return DateFormat.jm('es').format(t);
  if (!t.isBefore(today.subtract(const Duration(days: 1)))) return 'Ayer';
  if (!t.isBefore(today.subtract(const Duration(days: 6)))) return DateFormat.E('es').format(t);
  return DateFormat.yMd('es').format(t);
}

class ChatListView extends ConsumerWidget {
  const ChatListView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final chats = app.chats;

    if (chats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.forum_outlined, size: 56, color: cs.primary),
            const SizedBox(height: 16),
            const Text('Todavía no tienes chats', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('Escríbele a alguien por su número de teléfono.',
                textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => showNewChatSheet(context),
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('Nuevo chat'),
            ),
          ]),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: chats.length,
      itemBuilder: (context, i) => _ChatTile(
        chat: chats[i],
        activity: app.isRecording(chats[i].id)
            ? 'grabando audio…'
            : app.isTyping(chats[i].id)
                ? 'escribiendo…'
                : null,
      ),
    );
  }
}

class _ChatTile extends ConsumerWidget {
  final Chat chat;
  final String? activity; // "escribiendo…" / "grabando audio…"
  const _ChatTile({required this.chat, this.activity});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.6);
    final unread = chat.unread > 0;
    final typing = activity != null;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: CircleAvatar(
        radius: 26,
        backgroundColor: avatarColor(chat.id),
        child: Text(chat.title.characters.first,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      title: Row(children: [
        Expanded(
          child: Text(chat.title,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        Text(chatTime(chat.updatedAt),
            style: TextStyle(
                fontSize: 12, color: unread ? cs.secondary : muted, fontWeight: unread ? FontWeight.w700 : null)),
      ]),
      subtitle: Row(children: [
        Expanded(
          child: Text(
            activity ?? chat.lastText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: typing ? cs.secondary : muted, fontWeight: typing ? FontWeight.w600 : null),
          ),
        ),
        if (unread)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: cs.secondary, borderRadius: BorderRadius.circular(10)),
            child: Text('${chat.unread}',
                style: TextStyle(color: cs.onSecondary, fontSize: 11.5, fontWeight: FontWeight.w700)),
          ),
      ]),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id))),
    );
  }
}
