import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../../core/l10n/l10n.dart';
import '../../core/media/media_store.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';

/// Walkie-talkie: mantienes pulsado el botón, hablas y sueltas. Al otro le
/// suena sola (si tiene esta pantalla o el chat abierto). Por debajo es una
/// nota de voz normal, cifrada igual que las demás, marcada como «walkie».
class WalkieScreen extends ConsumerStatefulWidget {
  const WalkieScreen({super.key, required this.chatId});
  final String chatId;

  /// Chat cuyo walkie está abierto ahora (para que el chat no lo suene dos veces).
  static String? activeChat;

  @override
  ConsumerState<WalkieScreen> createState() => _WalkieScreenState();
}

class _WalkieScreenState extends ConsumerState<WalkieScreen> with SingleTickerProviderStateMixin {
  late final AppController _app;
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _queue = <String>[]; // audios recibidos por sonar
  StreamSubscription? _sub;
  late final AnimationController _pulse;

  bool _talking = false;
  bool _playing = false;
  DateTime? _start;
  Timer? _tick;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _app = ref.read(appProvider);
    WalkieScreen.activeChat = widget.chatId;
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _sub = _app.walkieIncoming.where((w) => w.chatId == widget.chatId).listen((w) {
      _queue.add(w.path);
      _playNext();
    });
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() => _playing = false);
        _playNext();
      }
    });
  }

  @override
  void dispose() {
    if (WalkieScreen.activeChat == widget.chatId) WalkieScreen.activeChat = null;
    _sub?.cancel();
    _tick?.cancel();
    _pulse.dispose();
    _player.dispose();
    if (_talking) {
      _recorder.stop();
      _app.setRecording(widget.chatId, false);
    }
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _playNext() async {
    if (_playing || _talking || _queue.isEmpty || !mounted) return;
    final path = _queue.removeAt(0);
    setState(() {
      _playing = true;
      _status = tr('Te están hablando…');
    });
    HapticFeedback.heavyImpact();
    try {
      await _player.setFilePath(path);
      await _player.play();
    } catch (_) {
      if (mounted) setState(() => _playing = false);
      _playNext();
    }
  }

  Future<void> _down() async {
    if (_talking) return;
    if (!await _recorder.hasPermission()) {
      _snack(tr('KLK no tiene permiso para el micrófono. Actívalo en Ajustes del iPhone → KLK.'));
      return;
    }
    await _player.stop();
    final path = await MediaStore.newPath('.m4a');
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    HapticFeedback.mediumImpact();
    setState(() {
      _talking = true;
      _playing = false;
      _start = DateTime.now();
      _status = tr('Hablando… suelta para enviar');
    });
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    _app.setRecording(widget.chatId, true);
  }

  Future<void> _up({bool cancel = false}) async {
    if (!_talking) return;
    _tick?.cancel();
    final path = await _recorder.stop();
    final ms = DateTime.now().difference(_start ?? DateTime.now()).inMilliseconds;
    _app.setRecording(widget.chatId, false);
    HapticFeedback.lightImpact();
    setState(() => _talking = false);
    if (path == null) return;
    if (cancel || ms < 600) {
      try {
        await File(path).delete();
      } catch (_) {}
      setState(() => _status = cancel ? tr('Cancelado') : tr('Mantén pulsado mientras hablas'));
      _playNext();
      return;
    }
    setState(() => _status = tr('Enviado ✓'));
    try {
      await _app.sendMedia(
        widget.chatId,
        MessageMedia(
          type: MediaType.audio,
          localPath: path,
          mime: 'audio/mp4',
          name: walkieAudioName,
          durationMs: ms,
          size: await File(path).length(),
        ),
      );
    } catch (e) {
      _snack(tr('No se pudo enviar. Revisa tu conexión.'));
    }
    _playNext();
  }

  void _snack(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final chat = app.chatById(widget.chatId);
    final otherTalking = app.isRecording(widget.chatId);
    final secs = _talking ? DateTime.now().difference(_start!).inSeconds : 0;
    final active = _talking || _playing || otherTalking;
    final color = _talking
        ? const Color(0xFFCE1126)
        : (_playing || otherTalking)
            ? const Color(0xFF1E8E3E)
            : const Color(0xFF002D62);
    final status = _talking
        ? '${tr('Hablando…')} 0:${secs.toString().padLeft(2, '0')}'
        : otherTalking
            ? '${chat?.title ?? ''} ${tr('está hablando…')}'
            : _playing
                ? _status
                : (_status.isEmpty ? tr('Mantén pulsado para hablar') : _status);

    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text('📻 ${tr('Walkie-talkie')}'),
      ),
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 12),
          Text(chat?.title ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(tr('Lo que digas le suena solo, como un walkie'),
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 14)),
          const Spacer(),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(status,
                key: ValueKey(status),
                textAlign: TextAlign.center,
                style: TextStyle(color: color == const Color(0xFF002D62) ? Colors.white70 : color,
                    fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 28),
          Listener(
            onPointerDown: (_) => _down(),
            onPointerUp: (_) => _up(),
            onPointerCancel: (_) => _up(cancel: true),
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) {
                final s = active ? 1 + _pulse.value * 0.06 : 1.0;
                return Transform.scale(scale: s, child: child);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 230,
                height: 230,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  border: Border.all(color: Colors.white24, width: 6),
                  boxShadow: [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: active ? 50 : 24, spreadRadius: active ? 6 : 0)],
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(_talking ? Icons.mic : (_playing || otherTalking) ? Icons.volume_up_rounded : Icons.mic_none_rounded,
                      color: Colors.white, size: 84),
                  const SizedBox(height: 6),
                  Text(_talking ? tr('Suelta para enviar') : tr('Mantén y habla'),
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Text(
              tr('Los mensajes también se guardan en el chat como notas de voz, cifrados de punta a punta.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ]),
      ),
    );
  }
}
