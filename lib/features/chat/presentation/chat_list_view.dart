import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import 'chat_avatar.dart';
import 'chat_screen.dart';
import 'new_chat_sheet.dart';


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
    final chats = app.visibleChats;

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

    final birthdays = app.birthdaysToday;
    final header = birthdays.isEmpty ? 0 : 1;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: chats.length + header,
      itemBuilder: (context, i) {
        if (i < header) return _BirthdayCard(people: birthdays);
        final c = chats[i - header];
        return _ChatTile(
          chat: c,
          activity: app.isRecording(c.id)
              ? 'grabando audio…'
              : app.isTyping(c.id)
                  ? 'escribiendo…'
                  : null,
        );
      },
    );
  }
}

/// "Hoy cumple Yaniris 🎂" con un botón para felicitar.
class _BirthdayCard extends StatelessWidget {
  final List<Chat> people;
  const _BirthdayCard({required this.people});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final names = people.map((c) => c.title.split(' ').first).toList();
    final who = names.length == 1
        ? names.first
        : '${names.sublist(0, names.length - 1).join(', ')} y ${names.last}';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(colors: [cs.secondary.withValues(alpha: 0.22), cs.primary.withValues(alpha: 0.18)]),
      ),
      child: Row(children: [
        const Text('🎂', style: TextStyle(fontSize: 30)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Hoy cumple $who', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            Text('Mándale un sticker o un audio, que le va a gustar',
                style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.7))),
          ]),
        ),
        FilledButton(
          onPressed: () {
            final c = people.first;
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ChatScreen(
                chatId: c.id,
                initialText: '¡Feliz cumpleaños, ${c.title.split(' ').first}! 🎂🇩🇴 Que Dios te bendiga',
              ),
            ));
          },
          child: const Text('Felicitar'),
        ),
      ]),
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
      leading: ChatAvatar(id: chat.id, title: chat.title, photoPath: chat.avatarPath),
      title: Row(children: [
        Expanded(
          child: Text(chat.title,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        if (chat.blocked) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.block, size: 15, color: Color(0xFFFF6B7A))),
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
      onLongPress: () => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Ocultar chat'),
              subtitle: const Text('Solo se verá en Ajustes → Chats ocultos, con tu PIN'),
              onTap: () async {
                Navigator.pop(ctx);
                final app = ref.read(appProvider);
                if (!await app.hasPin) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Primero crea tu PIN en Ajustes → Chats ocultos')));
                  }
                  return;
                }
                await app.setHidden(chat.id, true);
              },
            ),
          ]),
        ),
      ),
    );
  }
}
