import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import '../../../core/media/media_store.dart';
import '../../../core/translate/translator.dart';
import '../../../core/util/phone.dart';
import '../../calls/call_controller.dart';
import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import '../../privacy/presentation/privacy_provider.dart';
import 'chat_avatar.dart';
import 'chat_sheets.dart';
import 'media_bubbles.dart';
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
  Message? _replyTo; // mensaje al que respondo

  // Nota de voz
  final _recorder = AudioRecorder();
  bool _recording = false;
  DateTime? _recStart;
  Timer? _recTimer;

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
    _recTimer?.cancel();
    if (_recording) {
      _recorder.stop();
      _app.setRecording(widget.chatId, false);
    }
    _recorder.dispose();
    if (_input.text.isNotEmpty) _app.setTyping(widget.chatId, false);
    _app.closeChat();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------- Texto ----------

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
    final reply = _replyTo;
    setState(() => _replyTo = null);
    await _app.sendText(widget.chatId, text, at: at, replyTo: reply);
    if (at != null) _snack('Mensaje programado para el ${DateFormat.MMMd('es').add_jm().format(at)}');
  }

  Future<void> _schedule() async {
    if (_input.text.trim().isEmpty) {
      _snack('Escribe primero el mensaje que quieres programar');
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
      _snack('Elige una hora que todavía no haya pasado');
      return;
    }
    await _send(at: at);
  }

  // ---------- Adjuntos ----------

  /// Envía un adjunto; el texto escrito (si hay) va como pie de foto.
  Future<void> _sendMedia(MessageMedia media) async {
    final caption = _input.text.trim();
    final reply = _replyTo;
    _input.clear();
    setState(() => _replyTo = null);
    try {
      await _app.sendMedia(widget.chatId, media, caption: caption, replyTo: reply);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _sendFile(String sourcePath, {MediaType? forceType, String? name, bool viewOnce = false}) async {
    final path = await MediaStore.importFile(sourcePath);
    final ext = p.extension(path).toLowerCase();
    final type = forceType ??
        (const ['.mp4', '.mov', '.m4v', '.3gp'].contains(ext)
            ? MediaType.video
            : const ['.jpg', '.jpeg', '.png', '.heic', '.gif', '.webp'].contains(ext)
                ? MediaType.image
                : MediaType.file);
    final size = await File(path).length();
    await _sendMedia(MessageMedia(
      type: type,
      localPath: path,
      mime: MediaStore.mimeFor(path),
      name: name ?? p.basename(sourcePath),
      size: size,
      viewOnce: viewOnce,
    ));
  }

  Future<void> _attach(String what) async {
    final picker = ImagePicker();
    try {
      switch (what) {
        case 'camera':
          {
            final x = await picker.pickImage(source: ImageSource.camera); // calidad original
            if (x != null) await _sendFile(x.path, forceType: MediaType.image);
          }
        case 'video':
          {
            final x = await picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 5));
            if (x != null) await _sendFile(x.path, forceType: MediaType.video);
          }
        case 'gallery':
          {
            final x = await picker.pickMedia(); // foto o vídeo, sin comprimir
            if (x != null) await _sendFile(x.path);
          }
        case 'file':
          {
            final r = await FilePicker.platform.pickFiles();
            final f = r?.files.single;
            final path = f?.path;
            if (f != null && path != null) await _sendFile(path, forceType: MediaType.file, name: f.name);
          }
        case 'location':
          {
            await _sendLocation();
          }
        case 'viewonce':
          {
            final x = await picker.pickMedia();
            if (x != null) await _sendFile(x.path, viewOnce: true);
            if (x != null) _snack('Enviada para ver una vez: se borrará al abrirla');
          }
        case 'sticker':
          {
            final id = await pickSticker(context);
            if (id != null) await _sendMedia(MessageMedia(type: MediaType.sticker, name: id));
          }
        case 'trip':
          {
            final trip = await pickTrip(context);
            if (trip != null) await _sendMedia(trip);
          }
        case 'translate':
          await _translateDraft();
        case 'money':
          await showMoneyInfo(context, recharge: false);
        case 'recharge':
          await showMoneyInfo(context, recharge: true);
      }
    } on PlatformException catch (e) {
      _snack(e.code.contains('denied') || e.code.contains('access')
          ? 'KLK no tiene permiso. Actívalo en Ajustes del iPhone → KLK.'
          : 'No se pudo abrir: ${e.message ?? e.code}');
    }
  }

  /// Traduce lo que estoy escribiendo a otro idioma (dentro del móvil).
  Future<void> _translateDraft() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      _snack('Escribe primero en español lo que quieres decir y luego toca Traducir');
      return;
    }
    final lang = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
            title: Text('Traducir mi mensaje al…', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('Se traduce dentro de tu móvil. La primera vez descarga el idioma.'),
          ),
          for (final name in translateTargets.keys)
            ListTile(leading: const Icon(Icons.translate), title: Text(name), onTap: () => Navigator.pop(ctx, name)),
        ]),
      ),
    );
    if (lang == null) return;
    _snack('Traduciendo al $lang…');
    try {
      final out = await ref.read(translatorProvider).translateOutgoing(text, translateTargets[lang]!);
      _input.text = out;
      setState(() {});
    } catch (_) {
      _snack('No se pudo traducir. Revisa tu conexión la primera vez.');
    }
  }

  Future<void> _sendLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _snack('Activa la localización del teléfono para enviar tu ubicación');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack('KLK no tiene permiso de ubicación. Actívalo en Ajustes del iPhone → KLK.');
      return;
    }
    _snack('Buscando tu ubicación…');
    final pos = await Geolocator.getCurrentPosition();
    await _sendMedia(MessageMedia(type: MediaType.location, lat: pos.latitude, lng: pos.longitude));
  }

  void _showAttachSheet() {
    final cs = Theme.of(context).colorScheme;
    Widget item(IconData icon, String label, Color color, String what) => InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            Navigator.pop(context);
            _attach(what);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircleAvatar(radius: 28, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 26)),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 12.5, color: cs.onSurface)),
            ]),
          ),
        );

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              item(Icons.photo_library, 'Galería', const Color(0xFF6A2C91), 'gallery'),
              item(Icons.photo_camera, 'Cámara', const Color(0xFFCE1126), 'camera'),
              item(Icons.videocam, 'Vídeo', const Color(0xFFC46A00), 'video'),
              item(Icons.insert_drive_file, 'Documento', const Color(0xFF002D62), 'file'),
              item(Icons.location_on, 'Ubicación', const Color(0xFF1F7A4D), 'location'),
              item(Icons.looks_one_outlined, 'Ver una vez', const Color(0xFF0E4D64), 'viewonce'),
              item(Icons.emoji_emotions_outlined, 'Stickers', const Color(0xFFFFB627), 'sticker'),
              item(Icons.flight_takeoff, "Bajando pa' RD", const Color(0xFF002D62), 'trip'),
              item(Icons.translate, 'Traducir', const Color(0xFF00A6B4), 'translate'),
              item(Icons.payments_outlined, 'Enviar dinero', const Color(0xFF2E7D32), 'money'),
              item(Icons.phone_iphone, 'Recarga', const Color(0xFF7A3B2E), 'recharge'),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Nota de voz ----------

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      _snack('KLK no tiene permiso para el micrófono. Actívalo en Ajustes del iPhone → KLK.');
      return;
    }
    final path = await MediaStore.newPath('.m4a');
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _recStart = DateTime.now();
    });
    _recTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    _app.setRecording(widget.chatId, true);
  }

  Future<void> _stopRecording({required bool send}) async {
    _recTimer?.cancel();
    final path = await _recorder.stop();
    final dur = DateTime.now().difference(_recStart ?? DateTime.now());
    setState(() => _recording = false);
    _app.setRecording(widget.chatId, false);
    if (path == null) return;
    if (!send || dur.inMilliseconds < 800) {
      try {
        await File(path).delete();
      } catch (_) {}
      if (send) _snack('Mantén la grabación al menos un segundo');
      return;
    }
    await _sendMedia(MessageMedia(
      type: MediaType.audio,
      localPath: path,
      mime: 'audio/mp4',
      durationMs: dur.inMilliseconds,
      size: await File(path).length(),
    ));
  }

  // ---------- Acciones sobre un mensaje ----------

  static const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🇩🇴'];

  void _messageActions(Message m) {
    final cs = Theme.of(context).colorScheme;
    final canTranslate = !m.isMine && m.body.isNotEmpty && !m.deleted;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!m.deleted)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (final e in _quickReactions)
                  InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      Navigator.pop(ctx);
                      _app.react(m, e);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: m.reactions['me'] == e ? cs.secondary.withValues(alpha: 0.25) : null,
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ]),
            ),
          if (!m.deleted)
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Responder'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyTo = m);
              },
            ),
          if (!m.deleted && !(m.media?.viewOnce ?? false))
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Reenviar'),
              onTap: () async {
                Navigator.pop(ctx);
                final targets = await pickForwardTargets(
                    context, _app.visibleChats.where((c) => c.id != widget.chatId).toList());
                if (targets != null && targets.isNotEmpty) {
                  await _app.forward(m, targets);
                  _snack('Reenviado a ${targets.length} ${targets.length == 1 ? 'chat' : 'chats'}');
                }
              },
            ),
          if (m.body.isNotEmpty && !m.deleted)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copiar'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.body));
                Navigator.pop(ctx);
                _snack('Copiado');
              },
            ),
          if (canTranslate)
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('Traducir al español'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(translatorProvider).translateIncoming(m.id, m.body);
              },
            ),
          if (m.isMine && !m.deleted)
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined, color: Color(0xFFFF6B7A)),
              title: const Text('Borrar para todos', style: TextStyle(color: Color(0xFFFF6B7A))),
              onTap: () {
                Navigator.pop(ctx);
                _app.deleteForEveryone(m);
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A)),
            title: const Text('Borrar para mí', style: TextStyle(color: Color(0xFFFF6B7A))),
            onTap: () {
              Navigator.pop(ctx);
              _app.deleteMessage(m.id);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _openViewOnce(Message m) async {
    final media = m.media;
    if (media?.localPath == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ViewOnceViewer(media: media!)));
    await _app.markViewOnceOpened(m);
  }

  Future<void> _chatMenu(String action, Chat? chat) async {
    if (chat == null) return;
    switch (action) {
      case 'timer':
        {
          final sec = await pickDisappearing(context, chat.disappearSec);
          if (sec != null) await _app.setDisappearing(widget.chatId, sec == 0 ? null : sec);
        }
      case 'hide':
        {
          if (!chat.hidden && !await _app.hasPin) {
            _snack('Primero crea tu PIN en Ajustes → Chats ocultos');
            return;
          }
          await _app.setHidden(widget.chatId, !chat.hidden);
          _snack(chat.hidden ? 'El chat vuelve a la lista' : 'Chat oculto. Lo verás en Ajustes → Chats ocultos');
          if (!chat.hidden && mounted) Navigator.of(context).pop();
        }
      case 'group':
        await showGroupInfo(context, chat);
    }
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

  // ---------- Interfaz ----------

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final privacy = ref.watch(privacyProvider);
    final translator = ref.watch(translatorProvider);
    final cs = Theme.of(context).colorScheme;
    final chat = app.chats.where((c) => c.id == widget.chatId).firstOrNull;
    final messages = app.messagesFor(widget.chatId);
    final typing = app.isTyping(widget.chatId);
    final recording = app.isRecording(widget.chatId);
    _scrollToEndIfNew(messages.length);

    final title = chat?.title ?? '';
    final zone = chat == null ? null : zoneForPhone(chat.phone);
    final status = recording
        ? 'grabando audio…'
        : typing
            ? 'escribiendo…'
            : (chat?.isGroup ?? false)
                ? 'Grupo'
                : prettyPhone(chat?.phone ?? '');
    final live = typing || recording;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        actions: [
          if (!(chat?.isGroup ?? false)) ...[
            IconButton(
              tooltip: 'Videollamada',
              icon: const Icon(Icons.videocam_outlined),
              onPressed: () => ref.read(callProvider).startCall(widget.chatId, video: true),
            ),
            IconButton(
              tooltip: 'Llamada de voz',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => ref.read(callProvider).startCall(widget.chatId, video: false),
            ),
          ],
          PopupMenuButton<String>(
            onSelected: (a) => _chatMenu(a, chat),
            itemBuilder: (_) => [
              if (chat?.isGroup ?? false) const PopupMenuItem(value: 'group', child: Text('Info del grupo')),
              PopupMenuItem(
                value: 'timer',
                child: Text('Mensajes temporales · ${disappearLabel(chat?.disappearSec)}'),
              ),
              PopupMenuItem(value: 'hide', child: Text((chat?.hidden ?? false) ? 'Mostrar en la lista' : 'Ocultar chat')),
            ],
          ),
        ],
        title: Row(children: [
          ChatAvatar(id: widget.chatId, title: title, photoPath: chat?.avatarPath, radius: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: live ? cs.secondary : cs.onSurface.withValues(alpha: 0.6),
                  fontWeight: live ? FontWeight.w600 : null,
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
              if (zone != null)
                _Chip(icon: Icons.schedule, text: 'En ${zone.place} son las ${DateFormat.jm('es').format(nowIn(zone.zone))}'),
              const _Chip(
                icon: Icons.lock_outline,
                text: 'Mensajes y archivos cifrados de punta a punta. Nadie fuera de este chat puede verlos.',
                accent: true,
              ),
              for (final m in messages)
                GestureDetector(
                  key: ValueKey(m.id),
                  onLongPress: m.kind == MessageKind.system ? null : () => _messageActions(m),
                  child: MessageBubble(
                    message: m,
                    showSender: chat?.isGroup ?? false,
                    showReadReceipts: privacy.canSeeOthersReadReceipts,
                    onRetryMedia: () => _app.retryDownload(m),
                    onOpenViewOnce: () => _openViewOnce(m),
                    translation: translator.results[m.id],
                    translating: translator.working.contains(m.id),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_replyTo != null && !_recording) _replyBar(cs),
              _recording ? _recordingBar(cs) : _composer(),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _replyBar(ColorScheme cs) {
    final m = _replyTo!;
    final who = m.isMine ? 'Tú' : (m.sender.isNotEmpty ? m.sender : 'Respondiendo');
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 4, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: cs.secondary, width: 3)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(who, style: TextStyle(color: cs.secondary, fontWeight: FontWeight.w700, fontSize: 13)),
            Text(m.summary, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
          ]),
        ),
        IconButton(
          tooltip: 'Cancelar respuesta',
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => setState(() => _replyTo = null),
        ),
      ]),
    );
  }

  Widget _composer() {
    final hasText = _input.text.trim().isNotEmpty;
    return Row(children: [
      IconButton(tooltip: 'Adjuntar', onPressed: _showAttachSheet, icon: const Icon(Icons.add_circle_outline, size: 28)),
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
      if (hasText)
        IconButton(
          tooltip: 'Programar mensaje',
          onPressed: _schedule,
          icon: const Icon(Icons.schedule_send_outlined),
        ),
      const SizedBox(width: 4),
      hasText
          ? IconButton.filled(tooltip: 'Enviar', onPressed: () => _send(), icon: const Icon(Icons.send))
          : IconButton.filled(tooltip: 'Grabar nota de voz', onPressed: _startRecording, icon: const Icon(Icons.mic)),
    ]);
  }

  Widget _recordingBar(ColorScheme cs) {
    final elapsed = DateTime.now().difference(_recStart ?? DateTime.now());
    return Row(children: [
      IconButton(
        tooltip: 'Cancelar',
        onPressed: () => _stopRecording(send: false),
        icon: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A), size: 28),
      ),
      const SizedBox(width: 4),
      const Icon(Icons.fiber_manual_record, color: Color(0xFFCE1126), size: 16),
      const SizedBox(width: 8),
      Text('Grabando  ${formatDuration(elapsed.inMilliseconds)}',
          style: const TextStyle(fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
      const Spacer(),
      IconButton.filled(
        tooltip: 'Enviar nota de voz',
        onPressed: () => _stopRecording(send: true),
        icon: const Icon(Icons.send),
      ),
    ]);
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
