import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/util/phone.dart';
import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import '../../privacy/presentation/privacy_provider.dart';
import 'chat_list_view.dart' show avatarColor;
import 'message_bubble.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final AppController _app;
  Timer? _typingOff;
  Timer? _clock;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _app = ref.read(appProvider);
    _app.openChat(widget.chatId);
    // Refresca la "hora de allá" cada minuto.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _typingOff?.cancel();
    _clock?.cancel();
    if (_input.text.isNotEmpty) _app.setTyping(widget.chatId, false);
    _app.closeChat();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {});
    if (v.isEmpty) {
      _typingOff?.cancel();
      _app.setTyping(widget.chatId, false);
      return;
    }
    _app.setTyping(widget.chatId, true);
    _typingOff?.cancel();
    _typingOff = Timer(const Duration(seconds: 5), () => _app.setTyping(widget.chatId, false));
  }

  Future<void> _send({DateTime? at}) async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _typingOff?.cancel();
    setState(() {});
    await _app.sendText(widget.chatId, text, at: at);
    if (at != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Mensaje programado para el ${DateFormat.MMMd('es').add_jm().format(at)}'),
      ));
    }
  }

  Future<void> _schedule() async {
    if (_input.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escribe primero el mensaje que quieres programar')));
      return;
    }
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Día de envío',
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
      helpText: 'Hora de envío',
    );
    if (time == null) return;
    final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (!at.isAfter(DateTime.now())) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Elige una hora que todavía no haya pasado')));
      }
      return;
    }
    await _send(at: at);
  }

  void _scrollToEndIfNew(int count) {
    if (count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final privacy = ref.watch(privacyProvider);
    final cs = Theme.of(context).colorScheme;
    final chat = app.chats.where((c) => c.id == widget.chatId).firstOrNull;
    final messages = app.messagesFor(widget.chatId);
    final typing = app.isTyping(widget.chatId);
    _scrollToEndIfNew(messages.length);

    final title = chat?.title ?? '';
    final zone = chat == null ? null : zoneForPhone(chat.phone);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: avatarColor(widget.chatId),
            child: Text(title.isEmpty ? '?' : title.characters.first,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
              Text(
                typing ? 'escribiendo…' : (chat?.isGroup ?? false) ? 'Grupo' : prettyPhone(chat?.phone ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: typing ? cs.secondary : cs.onSurface.withValues(alpha: 0.6),
                  fontWeight: typing ? FontWeight.w600 : null,
                ),
              ),
            ]),
          ),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            children: [
              if (zone != null) _Chip(icon: Icons.schedule, text: 'En ${zone.place} son las ${DateFormat.jm('es').format(nowIn(zone.zone))}'),
              _Chip(
                icon: Icons.lock_outline,
                text: 'Mensajes cifrados de punta a punta. Nadie fuera de este chat puede leerlos.',
                accent: true,
              ),
              for (final m in messages)
                MessageBubble(
                  key: ValueKey(m.id),
                  message: m,
                  showSender: chat?.isGroup ?? false,
                  showReadReceipts: privacy.canSeeOthersReadReceipts,
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    hintText: 'Escribe un mensaje',
                    filled: true,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Programar mensaje',
                onPressed: _schedule,
                icon: const Icon(Icons.schedule_send_outlined),
              ),
              IconButton.filled(
                tooltip: 'Enviar',
                onPressed: _input.text.trim().isEmpty ? null : () => _send(),
                icon: const Icon(Icons.send),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool accent;
  const _Chip({required this.icon, required this.text, this.accent = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = accent ? cs.secondary : cs.onSurface.withValues(alpha: 0.65);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: accent ? cs.secondary.withValues(alpha: 0.12) : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: color))),
        ]),
      ),
    );
  }
}
