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
import '../../../core/util/phone.dart';
import '../../calls/call_controller.dart';
import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import '../../privacy/presentation/privacy_provider.dart';
import 'chat_avatar.dart';
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
    setState(() {});
    await _app.sendText(widget.chatId, text, at: at);
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
    if (caption.isNotEmpty) {
      _input.clear();
      setState(() {});
    }
    try {
      await _app.sendMedia(widget.chatId, media, caption: caption);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> _sendFile(String sourcePath, {MediaType? forceType, String? name}) async {
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
      }
    } on PlatformException catch (e) {
      _snack(e.code.contains('denied') || e.code.contains('access')
          ? 'KLK no tiene permiso. Actívalo en Ajustes del iPhone → KLK.'
          : 'No se pudo abrir: ${e.message ?? e.code}');
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
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              item(Icons.photo_library, 'Galería', const Color(0xFF6A2C91), 'gallery'),
              item(Icons.photo_camera, 'Cámara', const Color(0xFFCE1126), 'camera'),
              item(Icons.videocam, 'Vídeo', const Color(0xFFC46A00), 'video'),
              item(Icons.insert_drive_file, 'Documento', const Color(0xFF002D62), 'file'),
              item(Icons.location_on, 'Ubicación', const Color(0xFF1F7A4D), 'location'),
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

  void _messageActions(Message m) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (m.body.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copiar'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.body));
                Navigator.pop(ctx);
                _snack('Copiado');
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
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
            child: _recording ? _recordingBar(cs) : _composer(),
          ),
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
