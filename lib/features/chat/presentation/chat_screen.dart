import 'dart:async';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
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
import '../../theming/domain/klk_theme.dart';
import '../../theming/wallpapers.dart';
import 'chat_avatar.dart';
import 'chat_sheets.dart';
import '../../contacts/contact_actions.dart';
import '../../messaging/custom_stickers.dart';
import 'media_bubbles.dart';
import 'message_bubble.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;

  /// Texto ya escrito al abrir (p. ej. "¡Feliz cumpleaños!").
  final String? initialText;
  const ChatScreen({super.key, required this.chatId, this.initialText});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _emoji = false; // panel de emojis abierto
  final _scroll = ScrollController();
  late final AppController _app;
  Timer? _typingOff;
  Timer? _clock;
  int _lastCount = 0;
  Message? _replyTo; // mensaje al que respondo

  // Buscar dentro del chat
  bool _searching = false;
  final _search = TextEditingController();

  // Notas de voz que se están pasando a texto
  final Set<String> _transcribing = {};

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
    final initial = widget.initialText;
    if (initial != null && initial.isNotEmpty) _input.text = initial;
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
    _focus.dispose();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------- Texto ----------

  // Ojo: aquí no se llama a setState. Antes cada letra reconstruía el chat
  // entero (todos los mensajes) y en chats largos el teclado se quedaba colgado.
  // El botón enviar/micrófono escucha al controlador por su cuenta (_composer).
  void _onChanged(String v) {
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

  /// Sticker propio: se envía cifrado como archivo (el original se queda en "Míos").
  Future<void> _sendCustomSticker(String sourcePath) async {
    try {
      final path = await MediaStore.importFile(sourcePath);
      await _app.sendMedia(
        widget.chatId,
        MessageMedia(
          type: MediaType.sticker,
          name: customStickerName,
          localPath: path,
          mime: 'image/png',
          size: await File(path).length(),
        ),
      );
    } catch (e) {
      _snack('No se pudo enviar el sticker: $e');
    }
  }

  /// Imagen pegada desde el teclado (stickers, emojis creados, GIF…): se guarda en
  /// "Míos" y se envía como sticker.
  Future<void> _onKeyboardContent(KeyboardInsertedContent c) async {
    final data = c.data;
    if (data == null || data.isEmpty) return;
    try {
      final path = await CustomStickers.saveBytes(data);
      await _sendCustomSticker(path);
    } catch (_) {
      _snack('No se pudo usar esa imagen');
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
        case 'live':
          await _shareLive();
        case 'poll':
          {
            final poll = await pickPoll(context);
            if (poll != null) await _app.sendPoll(widget.chatId, poll.$1, poll.$2, multi: poll.$3);
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
            if (id != null && id.startsWith('file:')) {
              await _sendCustomSticker(id.substring(5));
            } else if (id != null) {
              await _sendMedia(MessageMedia(type: MediaType.sticker, name: id));
            }
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
    } catch (_) {
      _snack('No se pudo enviar. Revisa tu conexión e inténtalo otra vez.');
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

  Future<bool> _locationAllowed() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _snack('Activa la localización del teléfono para enviar tu ubicación');
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack('KLK no tiene permiso de ubicación. Actívalo en Ajustes del iPhone → KLK.');
      return false;
    }
    return true;
  }

  Future<void> _sendLocation() async {
    if (!await _locationAllowed()) return;
    _snack('Buscando tu ubicación…');
    final pos = await Geolocator.getCurrentPosition();
    await _sendMedia(MessageMedia(type: MediaType.location, lat: pos.latitude, lng: pos.longitude));
  }

  /// Ubicación en tiempo real: 15 min, 1 h u 8 h.
  Future<void> _shareLive() async {
    final duration = await pickLiveDuration(context);
    if (duration == null || !await _locationAllowed()) return;
    _snack('Buscando tu ubicación…');
    final pos = await Geolocator.getCurrentPosition();
    await _app.startLiveLocation(widget.chatId, duration, pos);
  }

  // ---------- Llamadas ----------

  /// Antes de llamar, si allá es de madrugada, pregunta.
  Future<void> _call(Chat? chat, {required bool video}) async {
    final zone = chat == null ? null : zoneForPhone(chat.phone);
    if (zone != null) {
      final there = nowIn(zone.zone);
      if (there.hour >= 23 || there.hour < 7) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.bedtime_outlined),
            title: Text('En ${zone.place} son las ${DateFormat.jm('es').format(there)}'),
            content: Text('Puede que ${chat!.title} esté durmiendo. ¿Llamar de todas formas?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Mejor luego')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Llamar')),
            ],
          ),
        );
        if (ok != true) return;
      }
    }
    await ref.read(callProvider).startCall(widget.chatId, video: video);
  }

  // ---------- Notas de voz a texto ----------

  Future<void> _transcribe(Message m) async {
    if (_transcribing.contains(m.id)) return;
    setState(() => _transcribing.add(m.id));
    try {
      await _app.transcribe(m);
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _transcribing.remove(m.id));
    }
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
              item(Icons.share_location, 'En vivo', const Color(0xFF00897B), 'live'),
              item(Icons.poll_outlined, 'Encuesta', const Color(0xFF3949AB), 'poll'),
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
                  try {
                    await _app.forward(m, targets);
                    _snack('Reenviado a ${targets.length} ${targets.length == 1 ? 'chat' : 'chats'}');
                  } catch (_) {
                    _snack('No se pudo reenviar. Revisa tu conexión.');
                  }
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
          if (!m.deleted)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(_app.chatById(widget.chatId)?.pinnedId == m.id ? 'Desfijar' : 'Fijar arriba'),
              onTap: () {
                Navigator.pop(ctx);
                final pinned = _app.chatById(widget.chatId)?.pinnedId == m.id;
                _app.pinMessage(widget.chatId, pinned ? null : m);
              },
            ),
          if (!m.deleted && m.media?.type == MediaType.audio && m.media?.transcript == null)
            ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: const Text('Pasar a texto'),
              subtitle: const Text('Se hace en tu móvil, sin enviar el audio a nadie'),
              onTap: () {
                Navigator.pop(ctx);
                _transcribe(m);
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
      case 'search':
        setState(() {
          _searching = true;
          _search.clear();
        });
      case 'wallpaper':
        await _pickWallpaper();
      case 'rename':
        await editContactName(context, _app, chat);
      case 'delete':
        {
          final nav = Navigator.of(context);
          if (await deleteContactFlow(context, _app, chat)) nav.pop();
        }
      case 'block':
        {
          if (!chat.blocked) {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text('¿Bloquear a ${chat.title}?'),
                content: const Text('No recibirás sus mensajes, llamadas ni estados, y no verá tu foto, tu nombre ni tus estados.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Bloquear'),
                  ),
                ],
              ),
            );
            if (ok != true) return;
          }
          await _app.setBlocked(widget.chatId, !chat.blocked);
        }
      case 'report':
        {
          final r = await pickReport(context, chat.title);
          if (r == null) return;
          try {
            await _app.report(widget.chatId, r.$1, includeMessages: r.$2, block: r.$3);
            _snack('Denuncia enviada. Gracias por ayudar a que KLK sea un sitio seguro.');
          } catch (e) {
            _snack('No se pudo enviar la denuncia: $e');
          }
        }
    }
  }

  Future<void> _pickWallpaper() => showWallpaperPicker(context);

  void _scrollToEndIfNew(int count) {
    if (count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) => _goToEnd(0));
  }

  /// La lista se construye a medida que se ve, así que el final real puede
  /// estar más abajo de lo que se calculó: se repite hasta llegar.
  Future<void> _goToEnd(int attempt) async {
    if (!mounted || !_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (attempt == 0) {
      await _scroll.animateTo(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      _scroll.jumpTo(target);
    }
    if (attempt < 4 && mounted && _scroll.hasClients && _scroll.position.maxScrollExtent > _scroll.offset + 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goToEnd(attempt + 1));
    }
  }

  // ---------- Interfaz ----------

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final privacy = ref.watch(privacyProvider);
    final translator = ref.watch(translatorProvider);
    final cs = Theme.of(context).colorScheme;
    final chat = app.chats.where((c) => c.id == widget.chatId).firstOrNull;
    final allMessages = app.messagesFor(widget.chatId);
    final query = foldForSearch(_search.text.trim());
    final messages = _searching && query.isNotEmpty
        ? allMessages
            .where((m) =>
                !m.deleted &&
                m.kind != MessageKind.system &&
                (foldForSearch(m.body).contains(query) ||
                    foldForSearch(m.media?.pollQuestion ?? '').contains(query) ||
                    foldForSearch(m.media?.transcript ?? '').contains(query)))
            .toList()
        : allMessages;
    final pinned = app.pinnedMessage(widget.chatId);
    final wallpaper = ref.watch(wallpaperProvider);
    final blocked = chat?.blocked ?? false;
    final typing = app.isTyping(widget.chatId);
    final recording = app.isRecording(widget.chatId);
    if (!_searching) _scrollToEndIfNew(messages.length);

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
      appBar: _searching
          ? AppBar(
              leading: IconButton(
                tooltip: 'Cerrar búsqueda',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _searching = false;
                  _search.clear();
                  _lastCount = -1; // al cerrar, vuelve al final
                }),
              ),
              title: TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Buscar en este chat', border: InputBorder.none),
              ),
              actions: [
                if (query.isNotEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text('${messages.length}', style: TextStyle(color: cs.secondary, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            )
          : AppBar(
        titleSpacing: 0,
        actions: [
          if (!(chat?.isGroup ?? false) && !blocked) ...[
            IconButton(
              tooltip: 'Videollamada',
              icon: const Icon(Icons.videocam_outlined),
              onPressed: () => _call(chat, video: true),
            ),
            IconButton(
              tooltip: 'Llamada de voz',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => _call(chat, video: false),
            ),
          ],
          PopupMenuButton<String>(
            onSelected: (a) => _chatMenu(a, chat),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'search', child: Text('Buscar')),
              if (chat?.isGroup ?? false) const PopupMenuItem(value: 'group', child: Text('Info del grupo')),
              PopupMenuItem(
                value: 'timer',
                child: Text('Mensajes temporales · ${disappearLabel(chat?.disappearSec)}'),
              ),
              const PopupMenuItem(value: 'wallpaper', child: Text('Fondo de pantalla')),
              if (chat != null)
                PopupMenuItem(
                  value: 'rename',
                  child: Text(chat.isGroup
                      ? 'Cambiar nombre (solo para mí)'
                      : (isUnsavedContact(chat) ? 'Añadir a contactos' : 'Editar contacto')),
                ),
              PopupMenuItem(value: 'hide', child: Text((chat?.hidden ?? false) ? 'Mostrar en la lista' : 'Ocultar chat')),
              if (!(chat?.isGroup ?? true)) ...[
                PopupMenuItem(value: 'block', child: Text(blocked ? 'Desbloquear' : 'Bloquear')),
                const PopupMenuItem(value: 'report', child: Text('Denunciar')),
              ],
              if (chat != null)
                PopupMenuItem(
                  value: 'delete',
                  child: Text(chat.isGroup ? 'Eliminar grupo' : 'Eliminar contacto',
                      style: const TextStyle(color: Color(0xFFCE1126))),
                ),
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
        if (pinned != null && !_searching) _pinnedBar(pinned, cs),
        Expanded(
          child: Stack(fit: StackFit.expand, children: [
            Positioned.fill(child: ChatWallpaper(id: wallpaper)),
            Builder(builder: (context) {
              // Avisos de arriba + mensajes. Se construye solo lo que se ve en pantalla.
              final header = <Widget>[
              if (_searching && query.isNotEmpty && messages.isEmpty)
                  const _Chip(icon: Icons.search_off, text: 'No hay mensajes con esas palabras'),
                if (zone != null && !_searching)
                  _Chip(icon: Icons.schedule, text: 'En ${zone.place} son las ${DateFormat.jm('es').format(nowIn(zone.zone))}'),
                if (!_searching && chat != null && isUnsavedContact(chat))
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                        label: const Text('Añadir a contactos'),
                        onPressed: () => editContactName(context, _app, chat),
                      ),
                    ),
                  ),
                if (!_searching)
                const _Chip(
                  icon: Icons.lock_outline,
                  text: 'Mensajes y archivos cifrados de punta a punta. Nadie fuera de este chat puede verlos.',
                  accent: true,
                ),
              ];
              return ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: header.length + messages.length,
                itemBuilder: (context, i) {
                  if (i < header.length) return header[i];
                  final m = messages[i - header.length];
                  if (translator.auto && !m.isMine && !m.deleted && m.body.isNotEmpty) {
                    translator.autoTranslate(m.id, m.body);
                  }
                  return GestureDetector(
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
                    onVote: (i) => _app.vote(m, i),
                    onStopLive: () => _app.stopLiveLocation(m.id),
                    onTranscribe: () => _transcribe(m),
                    transcribing: _transcribing.contains(m.id),
                    highlight: _searching ? _search.text : null,
                  ),
                );
                },
              );
            }),
          ]),
        ),
        ColoredBox(
          color: Theme.of(context).extension<BubbleStyle>()?.chatBg ?? cs.surface,
          child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
            child: blocked
                ? _blockedBar(cs)
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_replyTo != null && !_recording) _replyBar(cs),
                    _recording ? _recordingBar(cs) : _composer(),
                    if (_emoji && !_recording) _emojiPanel(),
                  ]),
          ),
        ),
        ),
      ]),
    );
  }

  Widget _pinnedBar(Message m, ColorScheme cs) => Material(
        color: cs.surfaceContainerHighest,
        child: InkWell(
          onTap: () => _messageActions(m),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(children: [
              Icon(Icons.push_pin, size: 18, color: cs.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Mensaje fijado', style: TextStyle(fontSize: 12, color: cs.secondary, fontWeight: FontWeight.w700)),
                  Text(m.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              IconButton(
                tooltip: 'Desfijar',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _app.pinMessage(widget.chatId, null),
              ),
            ]),
          ),
        ),
      );

  Widget _blockedBar(ColorScheme cs) => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          const Icon(Icons.block, color: Color(0xFFFF6B7A)),
          const SizedBox(width: 10),
          const Expanded(child: Text('Bloqueaste a este contacto. No puedes escribirle ni llamarle.')),
          TextButton(
            onPressed: () => _app.setBlocked(widget.chatId, false),
            child: const Text('Desbloquear'),
          ),
        ]),
      );

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

  void _toggleEmoji() {
    if (_emoji) {
      setState(() => _emoji = false);
      _focus.requestFocus();
    } else {
      _focus.unfocus();
      setState(() => _emoji = true);
    }
  }

  Widget _emojiPanel() => SizedBox(
        height: 290,
        child: EmojiPicker(
          textEditingController: _input,
          config: Config(height: 290, checkPlatformCompatibility: true),
        ),
      );

  Widget _composer() => ValueListenableBuilder<TextEditingValue>(
        valueListenable: _input,
        builder: (context, value, _) => _composerRow(value.text.trim().isNotEmpty),
      );

  Widget _composerRow(bool hasText) {
    final cs = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    final muted = cs.onSurface.withValues(alpha: 0.55);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: light ? Colors.white : const Color(0xFF1F2C34),
            borderRadius: BorderRadius.circular(26),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1))],
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconButton(
              tooltip: 'Adjuntar',
              onPressed: _showAttachSheet,
              icon: Icon(Icons.add, size: 26, color: muted),
            ),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                onTap: () {
                  if (_emoji) setState(() => _emoji = false);
                },
                // Stickers, emojis creados y GIF pegados desde el teclado
                contentInsertionConfiguration: ContentInsertionConfiguration(
                  allowedMimeTypes: const ['image/png', 'image/gif', 'image/jpeg', 'image/webp', 'image/heic'],
                  onContentInserted: _onKeyboardContent,
                ),
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                onChanged: _onChanged,
                style: const TextStyle(fontSize: 16.5),
                decoration: const InputDecoration(
                  hintText: 'Mensaje',
                  filled: false,
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
            IconButton(
              tooltip: _emoji ? 'Teclado' : 'Emojis',
              onPressed: _toggleEmoji,
              icon: Icon(_emoji ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined, color: muted),
            ),
            if (hasText)
              IconButton(
                tooltip: 'Programar mensaje',
                onPressed: _schedule,
                icon: Icon(Icons.schedule_send_outlined, color: muted),
              )
            else
              IconButton(
                tooltip: 'Cámara',
                onPressed: () => _attach('camera'),
                icon: Icon(Icons.photo_camera_outlined, color: muted),
              ),
          ]),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 48,
        height: 48,
        child: FloatingActionButton(
          heroTag: null,
          elevation: 1,
          shape: const CircleBorder(),
          tooltip: hasText ? 'Enviar' : 'Grabar nota de voz',
          onPressed: hasText ? () => _send() : _startRecording,
          child: Icon(hasText ? Icons.send_rounded : Icons.mic_rounded, size: 24),
        ),
      ),
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
