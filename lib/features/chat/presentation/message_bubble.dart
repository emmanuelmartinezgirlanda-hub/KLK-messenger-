import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../messaging/models.dart';
import '../../theming/domain/klk_theme.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool showSender;

  /// Reciprocidad: si oculto mis confirmaciones de lectura, no veo las ajenas.
  final bool showReadReceipts;

  const MessageBubble({
    super.key,
    required this.message,
    this.showSender = false,
    this.showReadReceipts = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (message.kind == MessageKind.system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: cs.secondary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(message.body,
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: cs.secondary)),
        ),
      );
    }

    final style = Theme.of(context).extension<BubbleStyle>()!;
    final mine = message.isMine;
    final bg = mine ? style.mine : style.theirs;
    final fg = mine ? style.mineText : style.theirsText;
    final r = Radius.circular(style.radius);
    final scheduled = message.status == MessageStatus.scheduled;
    final time = DateFormat.jm('es').format(message.scheduledFor ?? message.createdAt);

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Opacity(
        opacity: scheduled ? 0.75 : 1,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2.5),
          padding: const EdgeInsets.fromLTRB(13, 8, 10, 6),
          decoration: BoxDecoration(
            color: bg,
            border: scheduled ? Border.all(color: fg.withValues(alpha: 0.6), width: 1.2) : null,
            borderRadius: BorderRadius.only(
              topLeft: r,
              topRight: r,
              bottomLeft: mine ? r : const Radius.circular(5),
              bottomRight: mine ? const Radius.circular(5) : r,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSender && message.sender.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(message.sender,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: cs.secondary)),
                ),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: 8,
                children: [
                  Text(message.body, style: TextStyle(color: fg, fontSize: 15.5, height: 1.35)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (scheduled) ...[
                        Icon(Icons.schedule, size: 13, color: fg.withValues(alpha: 0.7)),
                        const SizedBox(width: 3),
                      ],
                      Text(time, style: TextStyle(color: fg.withValues(alpha: 0.65), fontSize: 11)),
                      if (mine && !scheduled) ...[
                        const SizedBox(width: 3),
                        _StatusIcon(status: message.status, color: fg, readColor: cs.secondary, showRead: showReadReceipts),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final MessageStatus status;
  final Color color, readColor;
  final bool showRead;
  const _StatusIcon({required this.status, required this.color, required this.readColor, required this.showRead});

  @override
  Widget build(BuildContext context) {
    final dim = color.withValues(alpha: 0.65);
    return switch (status) {
      MessageStatus.failed => const Icon(Icons.error_outline, size: 15, color: Color(0xFFFF6B7A)),
      MessageStatus.sending || MessageStatus.scheduled => Icon(Icons.access_time, size: 13, color: dim),
      MessageStatus.sent => Icon(Icons.done, size: 15, color: dim),
      MessageStatus.delivered => Icon(Icons.done_all, size: 15, color: dim),
      MessageStatus.read => Icon(Icons.done_all, size: 15, color: showRead ? readColor : dim),
    };
  }
}
