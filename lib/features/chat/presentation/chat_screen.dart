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
import 'package:klk_native/klk_native.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import '../../../core/features.dart';
import '../../../core/media/media_store.dart';
import '../../../core/translate/translator.dart';
import '../../../core/util/phone.dart';
import '../../calls/call_controller.dart';
import '../../topup/recharge_sheet.dart';
import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import '../../privacy/presentation/privacy_provider.dart';
import '../../theming/domain/klk_theme.dart';
import '../../theming/wallpapers.dart';
import 'chat_avatar.dart';
import 'chat_sheets.dart';
import 'sound_sticker.dart';
import '../../communities/community.dart';
import '../../san/san.dart';
import '../../san/san_screens.dart';
import '../../contacts/contact_actions.dart';
import '../../contacts/contact_info_screen.dart';
import '../../../core/l10n/l10n.dart';
import '../../messaging/custom_stickers.dart';
import '../../messaging/stickers.dart';
import 'media_bubbles.dart';
import 'message_bubble.dart';
import 'starred_screen.dart';
import '../../security/safety_number_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;

  /// Texto ya escrito al abrir (p. ej. "¡Feliz cumpleaños!").
  final String? initialText;

  /// Algo que hacer nada más abrir: 'call', 'video' o 'info'.
  final String? startAction;
  const ChatScreen({super.key, required this.chatId, this.initialText, this.startAction});

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
  Timer? _presenceTimer;
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
  String? _voicePreview; // nota de voz grabada, para escucharla antes de enviarla
  int _voicePreviewMs = 0;
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
    // ¿Está en línea? Se pregunta al abrir y cada 20 s mientras el chat está abierto.
    WidgetsBinding.instance.addPostFrameCallback((_) => _app.watchPresence(widget.chatId));
    final start = widget.startAction;
    if (start != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final chat = _app.chatById(widget.chatId);
        if (start == 'info') {
          _openInfo(chat);
        } else if (start == 'call' || start == 'video') {
          _call(chat, video: start == 'video');
        }
      });
    }
    _presenceTimer = Timer.periodic(const Duration(seconds: 20), (_) => _app.watchPresence(widget.chatId));
  }

  @override
  void dispose() {
    _typingOff?.cancel();
    _clock?.cancel();
    _presenceTimer?.cancel();
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
  /// Lo que se escribe después de @ (para sugerir a quién mencionar), o null.
  String? _mentionQuery;

  String _memberName(GroupMember m) {
    final c = _app.chatById(m.id);
    final n = (c != null && !c.isGroup) ? c.title : m.name;
    return n.trim().isEmpty ? prettyPhone(m.phone) : n.trim();
  }

  /// "@Ana" (solo la primera palabra del nombre, sin espacios).
  String _mentionTag(GroupMember m) => '@${_memberName(m).split(RegExp(r'\s+')).first}';

  void _updateMentionQuery(String v) {
    final chat = _app.chatById(widget.chatId);
    String? q;
    if (chat != null && chat.isGroup && chat.members.isNotEmpty) {
      final at = v.lastIndexOf('@');
      if (at >= 0 && (at == 0 || v[at - 1] == ' ' || v[at - 1] == '\n')) {
        final rest = v.substring(at + 1);
        if (!rest.contains(' ') && !rest.contains('\n') && rest.length <= 20) q = rest;
      }
    }
    if (q != _mentionQuery) setState(() => _mentionQuery = q);
  }

  void _insertMention(GroupMember m) {
    final v = _input.text;
    final at = v.lastIndexOf('@');
    if (at < 0) return;
    final t = '${v.substring(0, at)}${_mentionTag(m)} ';
    _input.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    setState(() => _mentionQuery = null);
  }

  Widget _mentionBar(ColorScheme cs) {
    final chat = _app.chatById(widget.chatId);
    final q = foldForSearch(_mentionQuery ?? '');
    final list = (chat?.members ?? const <GroupMember>[])
        .where((m) => q.isEmpty || foldForSearch(_memberName(m)).contains(q))
        .take(5)
        .toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final m in list)
          ListTile(
            dense: true,
            leading: ChatAvatar(id: m.id, title: _memberName(m), radius: 16),
            title: Text(_memberName(m), style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: m.phone.isEmpty ? null : Text(prettyPhone(m.phone)),
            onTap: () => _insertMention(m),
          ),
      ]),
    );
  }

  void _onChanged(String v) {
    _updateMentionQuery(v);
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
    final chat = _app.chatById(widget.chatId);
    final mentions = <String>[
      if (chat != null && chat.isGroup)
        for (final m in chat.members)
          if (RegExp('${RegExp.escape(_mentionTag(m))}(?![^\\s.,!?])').hasMatch(text)) m.id,
    ];
    setState(() {
      _replyTo = null;
      _mentionQuery = null;
    });
    await _app.sendText(widget.chatId, text, at: at, replyTo: reply, mentions: mentions);
    if (at != null) _snack('Mensaje programado para el ${DateFormat.MMMd('es').add_jm().format(at)}');
  }

  Future<void> _schedule() async {
    if (_input.text.trim().isEmpty) {
      _snack(tr('Escribe primero el mensaje que quieres programar'));
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
      _snack(tr('Elige una hora que todavía no haya pasado'));
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
      _snack(tr('No se pudo usar esa imagen'));
    }
  }

  static const _maxUploadBytes = 64 * 1024 * 1024;

  Future<void> _sendFile(String sourcePath, {MediaType? forceType, String? name, bool viewOnce = false}) async {
    final srcExt = p.extension(sourcePath).toLowerCase();
    final type = forceType ??
        (const ['.mp4', '.mov', '.m4v', '.3gp'].contains(srcExt)
            ? MediaType.video
            : const ['.jpg', '.jpeg', '.png', '.heic', '.gif', '.webp'].contains(srcExt)
                ? MediaType.image
                : MediaType.file);
    var source = sourcePath;
    String? temp;
    if (type == MediaType.video) {
      // Los vídeos del iPhone pesan mucho (4K): se comprimen antes de cifrar y subir.
      _snack(tr('Preparando el vídeo…'));
      try {
        final out = await KlkNative.compressVideo(sourcePath);
        if (out != sourcePath) source = temp = out;
      } catch (_) {
        // Si no se puede comprimir, se intenta con el original.
      }
    }
    final path = await MediaStore.importFile(source);
    if (temp != null) {
      try {
        await File(temp).delete();
      } catch (_) {}
    }
    final size = await File(path).length();
    if (size > _maxUploadBytes) {
      try {
        await File(path).delete();
      } catch (_) {}
      _snack(type == MediaType.video
          ? tr('El vídeo es demasiado largo. Prueba con uno más corto (máximo 64 MB).')
          : tr('El archivo es demasiado grande (máximo 64 MB).'));
      return;
    }
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
        case 'san':
          {
            final san = await Navigator.of(context)
                .push<San>(MaterialPageRoute(builder: (_) => SanCreateScreen(chatId: widget.chatId)));
            if (san != null) await _app.sendSan(widget.chatId, san);
          }
        case 'poll':
          {
            final poll = await pickPoll(context);
            if (poll != null) await _app.sendPoll(widget.chatId, poll.$1, poll.$2, multi: poll.$3);
          }
        case 'viewonce':
          {
            final x = await picker.pickMedia();
            if (x != null) await _sendFile(x.path, viewOnce: true);
            if (x != null) _snack(tr('Enviada para ver una vez: se borrará al abrirla'));
          }
        case 'sticker':
          {
            final id = await pickSticker(context);
            if (id != null && id.startsWith('file:')) {
              await _sendCustomSticker(id.substring(5));
            } else if (id != null && id.startsWith('rec:')) {
              final voice = await recordVoiceSticker(context, id.substring(4));
              if (voice != null) {
                await _sendMedia(MessageMedia(
                  type: MediaType.audio,
                  name: '$voiceStickerPrefix${id.substring(4)}',
                  localPath: voice.path,
                  mime: 'audio/mp4',
                  durationMs: voice.ms,
                  size: await File(voice.path).length(),
                ));
              }
            } else if (id != null && id.startsWith('snd:')) {
              await _sendMedia(MessageMedia(type: MediaType.sticker, name: id.substring(4), mime: soundStickerMime));
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
          await showRechargeSheet(context, chatId: widget.chatId);
      }
    } on PlatformException catch (e) {
      _snack(e.code.contains('denied') || e.code.contains('access')
          ? 'KLK no tiene permiso. Actívalo en Ajustes del iPhone → KLK.'
          : 'No se pudo abrir: ${e.message ?? e.code}');
    } catch (_) {
      _snack(tr('No se pudo enviar. Revisa tu conexión e inténtalo otra vez.'));
    }
  }

  /// Traduce lo que estoy escribiendo a otro idioma (dentro del móvil).
  Future<void> _translateDraft() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      _snack(tr('Escribe primero en español lo que quieres decir y luego toca Traducir'));
      return;
    }
    final lang = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(tr('Traducir mi mensaje al…'), style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr('Se traduce dentro de tu móvil. La primera vez descarga el idioma.')),
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
      _snack(tr('No se pudo traducir. Revisa tu conexión la primera vez.'));
    }
  }

  Future<bool> _locationAllowed() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _snack(tr('Activa la localización del teléfono para enviar tu ubicación'));
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack(tr('KLK no tiene permiso de ubicación. Actívalo en Ajustes del iPhone → KLK.'));
      return false;
    }
    return true;
  }

  Future<void> _sendLocation() async {
    if (!await _locationAllowed()) return;
    _snack(tr('Buscando tu ubicación…'));
    final pos = await Geolocator.getCurrentPosition();
    await _sendMedia(MessageMedia(type: MediaType.location, lat: pos.latitude, lng: pos.longitude));
  }

  /// Ubicación en tiempo real: 15 min, 1 h u 8 h.
  Future<void> _shareLive() async {
    final duration = await pickLiveDuration(context);
    if (duration == null || !await _locationAllowed()) return;
    _snack(tr('Buscando tu ubicación…'));
    final pos = await Geolocator.getCurrentPosition();
    await _app.startLiveLocation(widget.chatId, duration, pos);
  }

  // ---------- Llamadas ----------

  /// Antes de llamar, si allá es de madrugada, pregunta.
  Future<void> _call(Chat? chat, {required bool video}) async {
    final zone = chat == null ? null : zoneForPhone(chat.phone);
    final lateThere = zone != null && (nowIn(zone.zone).hour >= 23 || nowIn(zone.zone).hour < 7);
    // Confirmar antes de llamar (Privacidad → Llamadas), salvo que ya se pregunte por la hora
    if (!lateThere && ref.read(privacyProvider).confirmCalls) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(video ? Icons.videocam_outlined : Icons.call_outlined),
          title: Text(video ? '¿Videollamada a ${chat?.title ?? ''}?' : '¿Llamar a ${chat?.title ?? ''}?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Llamar'))),
          ],
        ),
      );
      if (ok != true) return;
    }
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
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Mejor luego'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Llamar'))),
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
              if (!isCommunityChat(widget.chatId) && !_app.isNotesChat(widget.chatId))
                item(Icons.handshake_rounded, 'San', const Color(0xFF1F7A4D), 'san'),
              item(Icons.looks_one_outlined, 'Ver una vez', const Color(0xFF0E4D64), 'viewonce'),
              item(Icons.emoji_emotions_outlined, 'Stickers', const Color(0xFFFFB627), 'sticker'),
              item(Icons.flight_takeoff, "Bajando pa' RD", const Color(0xFF002D62), 'trip'),
              item(Icons.translate, 'Traducir', const Color(0xFF00A6B4), 'translate'),
              if (kMoneyFeatures) ...[
                item(Icons.payments_outlined, 'Enviar dinero', const Color(0xFF2E7D32), 'money'),
                item(Icons.phone_iphone, 'Recarga', const Color(0xFF7A3B2E), 'recharge'),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Nota de voz ----------

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      _snack(tr('KLK no tiene permiso para el micrófono. Actívalo en Ajustes del iPhone → KLK.'));
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

  Future<void> _stopRecording({required bool send, bool preview = false}) async {
    _recTimer?.cancel();
    final path = await _recorder.stop();
    final dur = DateTime.now().difference(_recStart ?? DateTime.now());
    setState(() => _recording = false);
    _app.setRecording(widget.chatId, false);
    if (path == null) return;
    if (preview && dur.inMilliseconds >= 800) {
      // Escucharla antes de enviarla
      setState(() {
        _voicePreview = path;
        _voicePreviewMs = dur.inMilliseconds;
      });
      return;
    }
    if (!send || dur.inMilliseconds < 800) {
      try {
        await File(path).delete();
      } catch (_) {}
      if (send) _snack(tr('Mantén la grabación al menos un segundo'));
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

  Future<void> _finishVoicePreview({required bool send}) async {
    final path = _voicePreview;
    final ms = _voicePreviewMs;
    setState(() => _voicePreview = null);
    if (path == null) return;
    if (!send) {
      try {
        await File(path).delete();
      } catch (_) {}
      return;
    }
    await _sendMedia(MessageMedia(
      type: MediaType.audio,
      localPath: path,
      mime: 'audio/mp4',
      durationMs: ms,
      size: await File(path).length(),
    ));
  }

  Widget _voicePreviewBar(ColorScheme cs) => Row(children: [
        IconButton(
          tooltip: tr('Borrar nota de voz'),
          onPressed: () => _finishVoicePreview(send: false),
          icon: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A), size: 28),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(24)),
            child: VoiceNotePlayer(
              key: ValueKey(_voicePreview),
              path: _voicePreview!,
              fg: cs.onSurface,
              durationMs: _voicePreviewMs,
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          tooltip: tr('Enviar nota de voz'),
          onPressed: () => _finishVoicePreview(send: true),
          icon: const Icon(Icons.send),
        ),
      ]);

  // ---------- Acciones sobre un mensaje ----------

  static const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🇩🇴'];

  void _messageActions(Message m) {
    final cs = Theme.of(context).colorScheme;
    final canTranslate = !m.isMine && m.body.isNotEmpty && !m.deleted;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
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
              title: Text(tr('Responder')),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyTo = m);
              },
            ),
          if (!m.deleted && m.kind != MessageKind.system)
            ListTile(
              leading: Icon(m.starred ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: m.starred ? const Color(0xFFFFB627) : null),
              title: Text(m.starred ? tr('Quitar de destacados') : tr('Destacar')),
              onTap: () {
                Navigator.pop(ctx);
                _app.toggleStar(m);
                _snack(m.starred ? 'Quitado de destacados' : 'Guardado en destacados ⭐');
              },
            ),
          if (_app.canEdit(m))
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(tr('Editar')),
              subtitle: Text(tr('Durante 15 minutos después de enviarlo')),
              onTap: () {
                Navigator.pop(ctx);
                _editMessage(m);
              },
            ),
          if (!m.deleted && !(m.media?.viewOnce ?? false))
            ListTile(
              leading: const Icon(Icons.forward),
              title: Text(tr('Reenviar')),
              onTap: () async {
                Navigator.pop(ctx);
                final targets = await pickForwardTargets(
                    context, _app.visibleChats.where((c) => c.id != widget.chatId).toList());
                if (targets != null && targets.isNotEmpty) {
                  try {
                    await _app.forward(m, targets);
                    _snack('Reenviado a ${targets.length} ${targets.length == 1 ? 'chat' : 'chats'}');
                  } catch (_) {
                    _snack(tr('No se pudo reenviar. Revisa tu conexión.'));
                  }
                }
              },
            ),
          if (m.body.isNotEmpty && !m.deleted)
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(tr('Copiar')),
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.body));
                Navigator.pop(ctx);
                _snack(tr('Copiado'));
              },
            ),
          if (m.body.length > 20 && !m.deleted)
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: Text(tr('Seleccionar texto')),
              subtitle: Text(tr('Para copiar solo una parte')),
              onTap: () {
                Navigator.pop(ctx);
                showDialog<void>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: Text(tr('Selecciona lo que quieras copiar')),
                    content: SingleChildScrollView(
                      child: SelectableText(m.body, style: const TextStyle(fontSize: 16)),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cerrar')))],
                  ),
                );
              },
            ),
          if (!m.deleted)
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(_app.chatById(widget.chatId)?.pinnedId == m.id ? tr('Desfijar') : tr('Fijar arriba')),
              onTap: () {
                Navigator.pop(ctx);
                final pinned = _app.chatById(widget.chatId)?.pinnedId == m.id;
                _app.pinMessage(widget.chatId, pinned ? null : m);
              },
            ),
          if (!m.deleted && m.media?.type == MediaType.audio && m.media?.transcript == null)
            ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: Text(tr('Pasar a texto')),
              subtitle: Text(tr('Se hace en tu móvil, sin enviar el audio a nadie')),
              onTap: () {
                Navigator.pop(ctx);
                _transcribe(m);
              },
            ),
          if (canTranslate)
            ListTile(
              leading: const Icon(Icons.translate),
              title: Text(tr('Traducir al español')),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(translatorProvider).translateIncoming(m.id, m.body);
              },
            ),
          if (m.isMine && !m.deleted)
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined, color: Color(0xFFFF6B7A)),
              title: Text(tr('Borrar para todos'), style: TextStyle(color: Color(0xFFFF6B7A))),
              onTap: () {
                Navigator.pop(ctx);
                _app.deleteForEveryone(m);
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A)),
            title: Text(tr('Borrar para mí'), style: TextStyle(color: Color(0xFFFF6B7A))),
            onTap: () {
              Navigator.pop(ctx);
              _app.deleteMessage(m.id);
            },
          ),
        ]),
        ),
      ),
    );
  }

  Future<void> _editMessage(Message m) async {
    final ctrl = TextEditingController(text: m.body);
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Editar mensaje')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: Text(tr('Guardar'))),
        ],
      ),
    );
    ctrl.dispose();
    if (text == null || text.trim().isEmpty || text.trim() == m.body) return;
    if (!_app.canEdit(m)) {
      _snack(tr('Ya pasaron 15 minutos: no se puede editar'));
      return;
    }
    await _app.editMessage(m, text);
  }

  Future<void> _openViewOnce(Message m) async {
    final media = m.media;
    if (media?.localPath == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ViewOnceViewer(media: media!)));
    await _app.markViewOnceOpened(m);
  }

  /// Info del contacto (o del grupo), como al tocar su nombre en WhatsApp.
  Future<void> _openInfo(Chat? chat) async {
    if (chat == null || chat.isNotes) return;
    if (chat.isGroup) {
      await showGroupInfo(context, chat);
      return;
    }
    final action = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => ContactInfoScreen(chatId: chat.id)));
    if (action == null || !mounted) return;
    final fresh = _app.chatById(widget.chatId) ?? chat;
    if (action == 'call' || action == 'video') {
      await _call(fresh, video: action == 'video');
    } else {
      await _chatMenu(action, fresh);
    }
  }

  /// Foto de quien grabó la nota de voz (yo, el contacto o el miembro del grupo).
  Widget _voiceAvatar(Message m, Chat? chat, AppController app) {
    if (m.isMine) {
      return ChatAvatar(
          id: 'me', title: app.profile.name.isEmpty ? tr('Yo') : app.profile.name, photoPath: app.profile.photoPath, radius: 26);
    }
    if (chat != null && chat.isGroup) {
      final member = chat.members.where((x) => x.name == m.sender).firstOrNull;
      final contact = member == null ? null : app.chatById(member.id);
      return ChatAvatar(id: member?.id ?? m.sender, title: m.sender, photoPath: contact?.avatarPath, radius: 26);
    }
    return ChatAvatar(id: widget.chatId, title: chat?.title ?? '', photoPath: chat?.avatarPath, radius: 26);
  }

  PopupMenuEntry<String> _menuItem(String value, IconData icon, String label, {bool danger = false}) {
    final cs = Theme.of(context).colorScheme;
    final color = danger ? const Color(0xFFE5484D) : null;
    return PopupMenuItem<String>(
      value: value,
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Icon(icon, size: 21, color: color ?? cs.onSurface.withValues(alpha: 0.78)),
        const SizedBox(width: 14),
        Expanded(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: color)),
        ),
      ]),
    );
  }

  /// Menú ⋮ del chat: con iconos, por grupos y con lo peligroso en rojo al final.
  List<PopupMenuEntry<String>> _menuItems(Chat? chat, bool blocked) {
    final isContact = chat != null && !chat.isGroup && !chat.isNotes;
    const gap = PopupMenuDivider(height: 9);
    return [
      if (chat != null && !chat.isNotes)
        _menuItem('info', Icons.info_outline_rounded, chat.isGroup ? tr('Info. del grupo') : tr('Info. del contacto')),
      _menuItem('search', Icons.search_rounded, tr('Buscar')),
      _menuItem('starred', Icons.star_outline_rounded, tr('Mensajes destacados')),
      gap,
      if (chat != null && !chat.isNotes) ...[
        _menuItem(chat.muted ? 'unmute' : 'mute',
            chat.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
            chat.muted ? tr('Activar sonido') : tr('Silenciar')),
        _menuItem('timer', Icons.timer_outlined, '${tr('Mensajes temporales')} · ${disappearLabel(chat.disappearSec)}'),
      ],
      _menuItem('wallpaper', Icons.wallpaper_outlined, tr('Fondo de pantalla')),
      gap,
      if (isContact) _menuItem('safety', Icons.verified_user_outlined, tr('Código de seguridad')),
      if (chat != null && !chat.isNotes)
        _menuItem(
            'rename',
            chat.isGroup || !isUnsavedContact(chat) ? Icons.edit_outlined : Icons.person_add_alt_1_outlined,
            chat.isGroup
                ? tr('Cambiar nombre (solo para mí)')
                : (isUnsavedContact(chat) ? tr('Añadir a contactos') : tr('Editar contacto'))),
      if (chat != null)
        _menuItem('archive', chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            chat.archived ? tr('Desarchivar chat') : tr('Archivar chat')),
      _menuItem('hide', (chat?.hidden ?? false) ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          (chat?.hidden ?? false) ? tr('Mostrar en la lista') : tr('Ocultar chat')),
      gap,
      if (isContact) ...[
        _menuItem('block', Icons.block_rounded, blocked ? tr('Desbloquear') : tr('Bloquear'), danger: true),
        _menuItem('report', Icons.thumb_down_outlined, tr('Denunciar'), danger: true),
      ],
      if (chat != null) _menuItem('clear', Icons.cleaning_services_outlined, tr('Vaciar chat'), danger: true),
      if (chat != null && !chat.isNotes)
        _menuItem('delete', Icons.delete_outline_rounded, chat.isGroup ? tr('Eliminar grupo') : tr('Eliminar chat'),
            danger: true),
    ];
  }

  Future<void> _chatMenu(String action, Chat? chat) async {
    if (chat == null) return;
    switch (action) {
      case 'info':
        await _openInfo(chat);
      case 'timer':
        {
          final sec = await pickDisappearing(context, chat.disappearSec);
          if (sec != null) await _app.setDisappearing(widget.chatId, sec == 0 ? null : sec);
        }
      case 'mute':
        {
          final d = await pickMuteDuration(context);
          if (d == null) return;
          await _app.setMuted(widget.chatId, duration: d == Duration.zero ? null : d);
          _snack(tr('Chat silenciado 🔕'));
        }
      case 'unmute':
        await _app.setMuted(widget.chatId, unmute: true);
        _snack(tr('Sonido activado 🔔'));
      case 'archive':
        await _app.setArchived(widget.chatId, !chat.archived);
        _snack(chat.archived ? 'Chat desarchivado' : 'Chat archivado');
      case 'safety':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SafetyNumberScreen(chatId: widget.chatId)));
      case 'starred':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => StarredScreen(chatId: widget.chatId)));
      case 'hide':
        {
          if (!chat.hidden && !await _app.hasPin) {
            _snack(tr('Primero crea tu PIN en Ajustes → Chats ocultos'));
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
      case 'clear':
        await clearChatFlow(context, _app, chat);
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
                content: Text(tr('No recibirás sus mensajes, llamadas ni estados, y no verá tu foto, tu nombre ni tus estados.')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(tr('Bloquear')),
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
            _snack(tr('Denuncia enviada. Gracias por ayudar a que KLK sea un sitio seguro.'));
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
    final seen = (chat?.isGroup ?? true) || !ref.watch(privacyProvider).canSeeOthersLastSeen
        ? null
        : presenceLabel(app.presence[widget.chatId], DateTime.now());
    final status = (chat?.isNotes ?? false)
        ? 'Mensajes para ti · solo en este móvil'
        : recording
        ? tr('grabando audio…')
        : typing
            ? tr('escribiendo…')
            : (chat?.isGroup ?? false)
                ? (chat != null && chat.members.isNotEmpty ? '${chat.members.length + 1} miembros' : 'Grupo')
                : (seen ?? '');
    final live = typing || recording || seen == tr('en línea');

    return Scaffold(
      appBar: _searching
          ? AppBar(
              leading: IconButton(
                tooltip: tr('Cerrar búsqueda'),
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
                decoration: InputDecoration(hintText: tr('Buscar en este chat'), border: InputBorder.none),
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
          if (!(chat?.isGroup ?? false) && !blocked && !(chat?.isNotes ?? false)) ...[
            IconButton(
              tooltip: tr('Videollamada'),
              icon: const Icon(Icons.videocam_outlined),
              onPressed: () => _call(chat, video: true),
            ),
            IconButton(
              tooltip: tr('Llamada de voz'),
              icon: const Icon(Icons.call_outlined),
              onPressed: () => _call(chat, video: false),
            ),
          ],
          PopupMenuButton<String>(
            tooltip: tr('Más opciones'),
            icon: const Icon(Icons.more_vert_rounded),
            position: PopupMenuPosition.under,
            offset: const Offset(-6, 6),
            elevation: 10,
            shadowColor: Colors.black38,
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            surfaceTintColor: Colors.transparent,
            constraints: const BoxConstraints(minWidth: 250, maxWidth: 300),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            onSelected: (a) => _chatMenu(a, chat),
            itemBuilder: (_) => _menuItems(chat, blocked),
          ),
        ],
        title: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openInfo(chat),
          child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
          Hero(
            tag: 'avatar-${widget.chatId}',
            child: ChatAvatar(id: widget.chatId, title: title, photoPath: chat?.avatarPath, radius: 19),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
              if (status.isNotEmpty)
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
        ),
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
                  _Chip(icon: Icons.search_off, text: tr('No hay mensajes con esas palabras')),
                if (zone != null && !_searching)
                  _Chip(icon: Icons.schedule, text: 'En ${zone.place} son las ${DateFormat.jm('es').format(nowIn(zone.zone))}'),
                if (!_searching && chat != null && isUnsavedContact(chat))
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                        label: Text(tr('Añadir a contactos')),
                        onPressed: () => editContactName(context, _app, chat),
                      ),
                    ),
                  ),
                if (!_searching)
                _Chip(
                  icon: Icons.lock_outline,
                  text: tr('Mensajes y archivos cifrados de punta a punta. Nadie fuera de este chat puede verlos.'),
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
                    voiceAvatar: m.media?.type == MediaType.audio ? _voiceAvatar(m, chat, app) : null,
                    voiceHeard: m.isMine && m.status == MessageStatus.read,
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
                    if (_mentionQuery != null && !_recording) _mentionBar(cs),
                    if (_replyTo != null && !_recording) _replyBar(cs),
                    _recording
                        ? _recordingBar(cs)
                        : (_voicePreview != null ? _voicePreviewBar(cs) : _composer()),
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
                  Text(tr('Mensaje fijado'), style: TextStyle(fontSize: 12, color: cs.secondary, fontWeight: FontWeight.w700)),
                  Text(m.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              IconButton(
                tooltip: tr('Desfijar'),
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
          Expanded(child: Text(tr('Bloqueaste a este contacto. No puedes escribirle ni llamarle.'))),
          TextButton(
            onPressed: () => _app.setBlocked(widget.chatId, false),
            child: Text(tr('Desbloquear')),
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
          tooltip: tr('Cancelar respuesta'),
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
              tooltip: tr('Adjuntar'),
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
                decoration: InputDecoration(
                  hintText: tr('Mensaje'),
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
              tooltip: _emoji ? tr('Teclado') : 'Emojis',
              onPressed: _toggleEmoji,
              icon: Icon(_emoji ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined, color: muted),
            ),
            if (hasText)
              IconButton(
                tooltip: tr('Programar mensaje'),
                onPressed: _schedule,
                icon: Icon(Icons.schedule_send_outlined, color: muted),
              )
            else
              IconButton(
                tooltip: tr('Cámara'),
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
          tooltip: hasText ? tr('Enviar') : 'Grabar nota de voz',
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
        tooltip: tr('Cancelar'),
        onPressed: () => _stopRecording(send: false),
        icon: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A), size: 28),
      ),
      const SizedBox(width: 4),
      const Icon(Icons.fiber_manual_record, color: Color(0xFFCE1126), size: 16),
      const SizedBox(width: 8),
      Text('Grabando  ${formatDuration(elapsed.inMilliseconds)}',
          style: const TextStyle(fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
      const Spacer(),
      IconButton(
        tooltip: tr('Parar y escuchar antes de enviar'),
        onPressed: () => _stopRecording(send: false, preview: true),
        icon: const Icon(Icons.stop_circle_outlined, size: 30),
      ),
      IconButton.filled(
        tooltip: tr('Enviar nota de voz'),
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
