import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import '../../theming/domain/klk_theme.dart';
import 'chat_screen.dart';
import 'message_bubble.dart';
import '../../../core/l10n/l10n.dart';

/// Mensajes destacados ⭐ (de todos los chats, o solo de [chatId]).
class StarredScreen extends ConsumerStatefulWidget {
  final String? chatId;
  const StarredScreen({super.key, this.chatId});

  @override
  ConsumerState<StarredScreen> createState() => _StarredScreenState();
}

class _StarredScreenState extends ConsumerState<StarredScreen> {
  List<Message>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await ref.read(appProvider).starredMessages();
    if (!mounted) return;
    setState(() => _items = widget.chatId == null ? all : all.where((m) => m.chatId == widget.chatId).toList());
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final items = _items;
    final bg = Theme.of(context).extension<BubbleStyle>()?.chatBg ?? cs.surface;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Mensajes destacados'))),
      backgroundColor: bg,
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star_outline_rounded, size: 64, color: Color(0xFFFFB627)),
                      const SizedBox(height: 14),
                      Text(tr('Todavía no tienes destacados'),
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(tr('Deja pulsado un mensaje y toca «Destacar» para guardarlo aquí.'),
                          textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
                    ]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final m = items[i];
                    final chat = app.chatById(m.chatId);
                    final who = m.isMine ? 'Tú' : (m.sender.isNotEmpty ? m.sender : (chat?.title ?? ''));
                    return InkWell(
                      onTap: chat == null
                          ? null
                          : () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: m.chatId))),
                      onLongPress: () async {
                        await app.toggleStar(m);
                        await _load();
                      },
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                          child: Row(children: [
                            Expanded(
                              child: Text(
                                chat == null || widget.chatId != null ? who : '$who  ›  ${chat.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: cs.primary),
                              ),
                            ),
                            Text(DateFormat.yMd('es').format(m.createdAt),
                                style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.6))),
                          ]),
                        ),
                        IgnorePointer(child: MessageBubble(message: m)),
                      ]),
                    );
                  },
                ),
    );
  }
}
