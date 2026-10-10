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

enum _Filter { all, unread, groups }

class ChatListView extends ConsumerStatefulWidget {
  const ChatListView({super.key});

  @override
  ConsumerState<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends ConsumerState<ChatListView> {
  final _search = TextEditingController();
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final all = app.visibleChats;
    final q = foldForSearch(_search.text.trim());
    final unreadCount = all.where((c) => c.unread > 0).length;
    final chats = all.where((c) {
      if (_filter == _Filter.unread && c.unread == 0) return false;
      if (_filter == _Filter.groups && !c.isGroup) return false;
      if (q.isEmpty) return true;
      return foldForSearch(c.title).contains(q) || foldForSearch(c.lastText).contains(q) || c.phone.contains(q);
    }).toList();
    final news = app.currentAnnouncement;

    final top = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Buscar',
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 22),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Borrar',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => setState(_search.clear),
                  ),
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
          ),
        ),
      ),
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          children: [
            _chip('Todos', _Filter.all),
            _chip(unreadCount > 0 ? 'No leídos $unreadCount' : 'No leídos', _Filter.unread),
            _chip('Grupos', _Filter.groups),
          ],
        ),
      ),
      if (news != null && q.isEmpty)
        _AnnouncementCard(
          news: news,
          onClose: () => ref.read(appProvider).dismissAnnouncement(news.id),
        ),
      if (app.birthdaysToday.isNotEmpty && q.isEmpty && _filter == _Filter.all)
        _BirthdayCard(people: app.birthdaysToday),
    ];

    if (all.isEmpty) {
      return ListView(children: [
        ...top,
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
          child: Column(children: [
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
      ]);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: top.length + (chats.isEmpty ? 1 : chats.length),
      itemBuilder: (context, i) {
        if (i < top.length) return top[i];
        if (chats.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(40),
            child: Text(
              q.isNotEmpty ? 'No hay chats con «${_search.text.trim()}»' : 'No hay chats aquí',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          );
        }
        final c = chats[i - top.length];
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

  Widget _chip(String label, _Filter f) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: _filter == f,
          onSelected: (_) => setState(() => _filter = f),
        ),
      );
}

/// Aviso de KLK (lo manda el dueño desde su panel).
class _AnnouncementCard extends StatelessWidget {
  final KlkAnnouncement news;
  final VoidCallback onClose;
  const _AnnouncementCard({required this.news, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
          child: Icon(Icons.campaign_rounded, size: 20, color: cs.onPrimary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('KLK · ${news.title}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 3),
            Text(news.body, style: TextStyle(fontSize: 14, color: cs.onSurface.withValues(alpha: 0.8))),
          ]),
        ),
        IconButton(
          tooltip: 'Cerrar aviso',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 20),
          onPressed: onClose,
        ),
      ]),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      minVerticalPadding: 10,
      leading: ChatAvatar(id: chat.id, title: chat.title, photoPath: chat.avatarPath, radius: 27),
      title: Row(children: [
        Expanded(
          child: Text(chat.title,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.5)),
        ),
        if (chat.blocked) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.block, size: 15, color: Color(0xFFFF6B7A))),
        Text(chatTime(chat.updatedAt),
            style: TextStyle(
                fontSize: 12, color: unread ? cs.primary : muted, fontWeight: unread ? FontWeight.w700 : null)),
      ]),
      subtitle: Row(children: [
        Expanded(
          child: Text(
            activity ?? chat.lastText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 14.5, color: typing ? cs.primary : muted, fontWeight: typing ? FontWeight.w600 : null),
          ),
        ),
        if (unread)
          Container(
            margin: const EdgeInsets.only(left: 8),
            constraints: const BoxConstraints(minWidth: 22),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(12)),
            child: Text('${chat.unread}',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
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
