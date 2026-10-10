import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../messaging/models.dart';
import '../../theming/domain/klk_theme.dart';
import 'media_bubbles.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool showSender;

  /// Reciprocidad: si oculto mis confirmaciones de lectura, no veo las ajenas.
  final bool showReadReceipts;

  /// Reintentar la descarga de un adjunto.
  final VoidCallback? onRetryMedia;

  /// Abrir una foto/vídeo de "ver una vez".
  final VoidCallback? onOpenViewOnce;

  /// Traducción del mensaje (si el usuario la pidió) y si se está traduciendo.
  final String? translation;
  final bool translating;

  /// Encuestas, ubicación en vivo y notas de voz a texto.
  final void Function(int option)? onVote;
  final VoidCallback? onStopLive;
  final VoidCallback? onTranscribe;
  final bool transcribing;

  /// Texto buscado (se resalta).
  final String? highlight;

  const MessageBubble({
    super.key,
    required this.message,
    this.showSender = false,
    this.showReadReceipts = true,
    this.onRetryMedia,
    this.onOpenViewOnce,
    this.translation,
    this.translating = false,
    this.onVote,
    this.onStopLive,
    this.onTranscribe,
    this.transcribing = false,
    this.highlight,
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
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 1.5, offset: Offset(0, 1))],
          ),
          child: Text(message.body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.7))),
        ),
      );
    }

    final style = Theme.of(context).extension<BubbleStyle>()!;
    final mine = message.isMine;
    final media = message.media;
    final isSticker = !message.deleted && media?.type == MediaType.sticker;
    final bg = mine ? style.mine : style.theirs;
    final fg = isSticker ? cs.onSurface : (mine ? style.mineText : style.theirsText);
    final r = Radius.circular(style.radius);
    final scheduled = message.status == MessageStatus.scheduled;
    final time = DateFormat.jm('es').format(message.scheduledFor ?? message.createdAt);

    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message.expiresAt != null) ...[
          Icon(Icons.timer_outlined, size: 12, color: fg.withValues(alpha: 0.6)),
          const SizedBox(width: 3),
        ],
        if (scheduled) ...[
          Icon(Icons.schedule, size: 13, color: fg.withValues(alpha: 0.7)),
          const SizedBox(width: 3),
        ],
        Text(time, style: TextStyle(color: fg.withValues(alpha: 0.65), fontSize: 11)),
        if (mine && !scheduled && !message.deleted) ...[
          const SizedBox(width: 3),
          _StatusIcon(status: message.status, color: fg, readColor: const Color(0xFF1D9BF0), showRead: showReadReceipts),
        ],
      ],
    );

    Widget content;
    if (message.deleted) {
      content = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.block, size: 16, color: fg.withValues(alpha: 0.6)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(mine ? 'Eliminaste este mensaje' : 'Este mensaje se eliminó',
              style: TextStyle(color: fg.withValues(alpha: 0.7), fontStyle: FontStyle.italic)),
        ),
        const SizedBox(width: 8),
        meta,
      ]);
    } else {
      content = Column(
        // Con adjunto, la hora queda alineada a la derecha bajo la foto/audio.
        crossAxisAlignment: media == null ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSender && message.sender.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2, left: 2),
              child: Text(message.sender,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: cs.secondary)),
            ),
          if (message.replyPreview != null) _ReplyQuote(text: message.replyPreview!, fg: fg, accent: cs.secondary),
          if (media != null)
            MediaContent(
              message: message,
              fg: fg,
              onRetry: onRetryMedia,
              onOpenViewOnce: onOpenViewOnce,
              onVote: onVote,
              onStopLive: onStopLive,
              onTranscribe: onTranscribe,
              transcribing: transcribing,
            ),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 8,
            children: [
              if (message.body.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(left: media == null ? 0 : 6, top: media == null ? 0 : 4),
                  child: _highlighted(message.body, TextStyle(color: fg, fontSize: 15.5, height: 1.35), cs.secondary),
                ),
              meta,
            ],
          ),
          if (translating || translation != null)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: fg.withValues(alpha: 0.2)))),
              child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.translate, size: 14, color: fg.withValues(alpha: 0.6)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(translating ? 'Traduciendo…' : translation!,
                      style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 14.5, fontStyle: FontStyle.italic)),
                ),
              ]),
            ),
        ],
      );
    }

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
      margin: EdgeInsets.fromLTRB(mine ? 48 : 10, 2, mine ? 10 : 48, message.reactions.isEmpty ? 2 : 14),
      padding: isSticker
          ? EdgeInsets.zero
          : (media == null || message.deleted
              ? const EdgeInsets.fromLTRB(13, 8, 10, 6)
              : const EdgeInsets.fromLTRB(5, 5, 8, 5)),
      decoration: isSticker
          ? null
          : BoxDecoration(
              color: bg,
              border: scheduled ? Border.all(color: fg.withValues(alpha: 0.6), width: 1.2) : null,
              boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 1.5, offset: Offset(0, 1))],
              borderRadius: BorderRadius.only(
                topLeft: mine ? r : const Radius.circular(3),
                topRight: mine ? const Radius.circular(3) : r,
                bottomLeft: r,
                bottomRight: r,
              ),
            ),
      child: content,
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Opacity(
        opacity: scheduled ? 0.75 : 1,
        child: message.reactions.isEmpty
            ? bubble
            : Stack(clipBehavior: Clip.none, children: [
                bubble,
                Positioned(
                  bottom: 0,
                  right: mine ? 18 : null,
                  left: mine ? null : 18,
                  child: _Reactions(reactions: message.reactions),
                ),
              ]),
      ),
    );
  }

  /// Resalta [highlight] dentro del texto (sin importar tildes ni mayúsculas).
  Widget _highlighted(String text, TextStyle style, Color accent) {
    final q = highlight == null ? '' : foldForSearch(highlight!.trim());
    if (q.isEmpty) return Text(text, style: style);
    final folded = foldForSearch(text);
    if (folded.length != text.length) return Text(text, style: style);
    final spans = <TextSpan>[];
    var i = 0;
    while (true) {
      final j = folded.indexOf(q, i);
      if (j < 0) {
        spans.add(TextSpan(text: text.substring(i)));
        break;
      }
      if (j > i) spans.add(TextSpan(text: text.substring(i, j)));
      spans.add(TextSpan(
        text: text.substring(j, j + q.length),
        style: TextStyle(backgroundColor: accent.withValues(alpha: 0.45), fontWeight: FontWeight.w700),
      ));
      i = j + q.length;
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

class _ReplyQuote extends StatelessWidget {
  final String text;
  final Color fg, accent;
  const _ReplyQuote({required this.text, required this.fg, required this.accent});

  @override
  Widget build(BuildContext context) {
    final i = text.indexOf(': ');
    final who = i > 0 ? text.substring(0, i) : '';
    final body = i > 0 ? text.substring(i + 2) : text;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      constraints: const BoxConstraints(minWidth: 120),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (who.isNotEmpty)
          Text(who, style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 12.5)),
        Text(body, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 13)),
      ]),
    );
  }
}

class _Reactions extends StatelessWidget {
  final Map<String, String> reactions;
  const _Reactions({required this.reactions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Agrupa: 👍 2  ❤️ 1
    final counts = <String, int>{};
    for (final e in reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.surface, width: 2),
      ),
      child: Text(
        counts.entries.map((e) => e.value > 1 ? '${e.key} ${e.value}' : e.key).join(' '),
        style: const TextStyle(fontSize: 13),
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
