import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_list_view.dart' show chatTime;
import '../chat/presentation/chat_screen.dart';
import '../communities/community.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'call_log.dart';

/// Pestaña «Llamadas»: botones rápidos y el historial de llamadas.
class CallsView extends ConsumerWidget {
  const CallsView({super.key});

  static void _open(BuildContext context, String chatId, {required bool video}) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(chatId: chatId, startAction: video ? 'video' : 'call'),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final calls = app.callLog.where((c) => app.chatById(c.chatId) != null).toList();
    final bottom = 24 + MediaQuery.paddingOf(context).bottom;

    return ListView(
      padding: EdgeInsets.only(bottom: bottom),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(children: [
            _QuickAction(
              icon: Icons.call_rounded,
              label: tr('Llamar'),
              background: const Color(0xFF1F3D6B),
              foreground: const Color(0xFFCFE1FF),
              onTap: () => _pickContact(context, ref, video: false),
            ),
            const SizedBox(width: 10),
            _QuickAction(
              icon: Icons.videocam_rounded,
              label: tr('Vídeo'),
              background: const Color(0xFF1F3D6B),
              foreground: const Color(0xFFCFE1FF),
              onTap: () => _pickContact(context, ref, video: true),
            ),
            const SizedBox(width: 10),
            _QuickAction(
              icon: Icons.closed_caption_rounded,
              label: tr('Subtítulos'),
              background: const Color(0xFF0E4D2F),
              foreground: const Color(0xFF9BE8C1),
              onTap: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  icon: const Icon(Icons.closed_caption_rounded),
                  title: Text(tr('Subtítulos traducidos')),
                  content: Text(tr(
                      'Durante una llamada toca el botón de subtítulos y verás lo que dice la otra persona, traducido a tu idioma.')),
                  actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Entendido')))],
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text(tr('RECIENTES'),
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: cs.onSurface.withValues(alpha: 0.6))),
            ),
            if (calls.isNotEmpty)
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(tr('¿Borrar el historial de llamadas?')),
                      content: Text(tr('Solo se borra de este móvil.')),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Borrar'))),
                      ],
                    ),
                  );
                  if (ok == true) app.clearCallLog();
                },
                child: Text(tr('Borrar')),
              ),
          ]),
        ),
        if (calls.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 0),
            child: Column(children: [
              Icon(Icons.call_outlined, size: 56, color: cs.onSurface.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              Text(tr('Aún no hay llamadas'),
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(tr('Las llamadas de voz y vídeo de KLK van cifradas de punta a punta.'),
                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
            ]),
          )
        else
          for (final c in calls) _CallTile(record: c, chat: app.chatById(c.chatId)!, onCall: _open),
      ],
    );
  }

  Future<void> _pickContact(BuildContext context, WidgetRef ref, {required bool video}) async {
    final app = ref.read(appProvider);
    final people = app.visibleChats
        .where((c) => !c.isGroup && !c.isNotes && !c.blocked && !isCommunityChat(c.id))
        .toList();
    final id = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.65,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(video ? tr('Videollamada a…') : tr('Llamar a…'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Expanded(
              child: people.isEmpty
                  ? Center(child: Text(tr('Todavía no tienes chats con nadie')))
                  : ListView(children: [
                      for (final c in people)
                        ListTile(
                          leading: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath, radius: 22),
                          title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Icon(video ? Icons.videocam_rounded : Icons.call_rounded),
                          onTap: () => Navigator.pop(ctx, c.id),
                        ),
                    ]),
            ),
          ]),
        ),
      ),
    );
    if (id != null && context.mounted) _open(context, id, video: video);
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: foreground, size: 22),
              ),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _CallTile extends StatelessWidget {
  final CallRecord record;
  final Chat chat;
  final void Function(BuildContext, String, {required bool video}) onCall;
  const _CallTile({required this.record, required this.chat, required this.onCall});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = record;
    final missedIn = r.missedIncoming;
    final kind = r.video ? tr('Videollamada') : tr('Llamada');
    final what = missedIn
        ? tr('Perdida')
        : r.incoming
            ? tr('Entrante')
            : r.missed
                ? tr('Sin respuesta')
                : tr('Saliente');
    final dur = r.durationMs > 0 ? ' · ${formatDuration(r.durationMs)}' : '';
    final arrow = r.incoming ? Icons.call_received_rounded : Icons.call_made_rounded;
    final arrowColor = missedIn ? const Color(0xFFFF5A6E) : (r.missed ? cs.onSurface.withValues(alpha: 0.5) : const Color(0xFF25C26E));

    return Dismissible(
      key: ValueKey(r.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: const Color(0xFFB3122A),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => ProviderScope.containerOf(context).read(appProvider).removeCall(r.id),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 2, 10, 2),
        leading: ChatAvatar(id: chat.id, title: chat.title, photoPath: chat.avatarPath, radius: 24),
        title: Text(
          chat.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w700, color: missedIn ? const Color(0xFFFF5A6E) : null),
        ),
        subtitle: Row(children: [
          Icon(arrow, size: 15, color: arrowColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text('$kind · $what$dur · ${chatTime(r.at)}', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id))),
        trailing: IconButton.filledTonal(
          tooltip: r.video ? tr('Videollamada') : tr('Llamar'),
          icon: Icon(r.video ? Icons.videocam_rounded : Icons.call_rounded),
          onPressed: () => onCall(context, chat.id, video: r.video),
        ),
      ),
    );
  }
}
