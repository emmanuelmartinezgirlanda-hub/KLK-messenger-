import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../../../core/media/media_store.dart';
import '../../messaging/stickers.dart';

/// Reproduce la voz de los stickers con sonido (uno a la vez).
class SoundStickerPlayer {
  static AudioPlayer? _player;
  static final playing = ValueNotifier<String?>(null); // id del mensaje que suena
  static final _autoPlayed = <String>{};

  static Future<void> play(String stickerId, {String? messageId, String? filePath}) async {
    try {
      final p = _player ??= AudioPlayer();
      await p.stop();
      if (filePath != null) {
        await p.setFilePath(filePath);
      } else {
        await p.setAsset(soundStickerAsset(stickerId));
      }
      playing.value = messageId ?? stickerId;
      await p.play();
    } catch (e) {
      debugPrint('Sticker con sonido: $e');
    } finally {
      if (playing.value == (messageId ?? stickerId)) playing.value = null;
    }
  }

  /// Suena solo la primera vez que aparece un sticker recién llegado.
  static bool takeAutoplay(String messageId) => _autoPlayed.add(messageId);
}

/// Insignia del altavoz sobre el sticker.
class SoundBadge extends StatelessWidget {
  final bool active;
  const SoundBadge({super.key, this.active = false});

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF25C26E) : Colors.black.withValues(alpha: 0.62),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        child: Icon(active ? Icons.graphic_eq_rounded : Icons.volume_up_rounded, color: Colors.white, size: 15),
      );
}

/// Sticker con sonido dentro del chat: toca para oírlo.
class SoundSticker extends StatefulWidget {
  final String id;
  final String messageId;
  final bool autoplay;
  final String? filePath; // voz grabada por el usuario (si no, la de KLK)
  const SoundSticker({super.key, required this.id, required this.messageId, this.autoplay = false, this.filePath});

  @override
  State<SoundSticker> createState() => _SoundStickerState();
}

class _SoundStickerState extends State<SoundSticker> {
  @override
  void initState() {
    super.initState();
    if (widget.autoplay && SoundStickerPlayer.takeAutoplay(widget.messageId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) SoundStickerPlayer.play(widget.id, messageId: widget.messageId, filePath: widget.filePath);
      });
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => SoundStickerPlayer.play(widget.id, messageId: widget.messageId, filePath: widget.filePath),
        child: ValueListenableBuilder<String?>(
          valueListenable: SoundStickerPlayer.playing,
          builder: (_, now, __) {
            final active = now == widget.messageId;
            return AnimatedScale(
              scale: active ? 1.06 : 1,
              duration: const Duration(milliseconds: 180),
              child: Stack(clipBehavior: Clip.none, children: [
                Image.asset(stickerAsset(widget.id), width: 150, height: 150),
                Positioned(right: 4, bottom: 4, child: SoundBadge(active: active)),
              ]),
            );
          },
        ),
      );
}

/// Graba tu voz para un sticker (máx. 6 s). Devuelve el audio o null.
Future<({String path, int ms})?> recordVoiceSticker(BuildContext context, String stickerId) =>
    showModalBottomSheet<({String path, int ms})>(
      context: context,
      showDragHandle: true,
      isDismissible: false,
      builder: (_) => _VoiceStickerRecorder(stickerId: stickerId),
    );

class _VoiceStickerRecorder extends StatefulWidget {
  final String stickerId;
  const _VoiceStickerRecorder({required this.stickerId});

  @override
  State<_VoiceStickerRecorder> createState() => _VoiceStickerRecorderState();
}

class _VoiceStickerRecorderState extends State<_VoiceStickerRecorder> {
  static const _max = Duration(seconds: 6);
  final _rec = AudioRecorder();
  String? _path;
  int _ms = 0;
  bool _recording = false;
  DateTime? _start;
  Timer? _tick;
  bool _sent = false;

  @override
  void dispose() {
    _tick?.cancel();
    _rec.dispose();
    if (!_sent && _path != null) {
      File(_path!).delete().catchError((_) => File(_path!));
    }
    super.dispose();
  }

  Future<void> _startRec() async {
    if (!await _rec.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('KLK no tiene permiso para el micrófono. Actívalo en Ajustes del móvil → KLK.')));
      }
      return;
    }
    if (_path != null) {
      try {
        await File(_path!).delete();
      } catch (_) {}
    }
    final path = await MediaStore.newPath('.m4a');
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _start = DateTime.now();
      _path = null;
    });
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final ms = DateTime.now().difference(_start!).inMilliseconds;
      if (ms >= _max.inMilliseconds) {
        _stopRec();
      } else {
        setState(() => _ms = ms);
      }
    });
  }

  Future<void> _stopRec() async {
    if (!_recording) return;
    _tick?.cancel();
    final path = await _rec.stop();
    final ms = DateTime.now().difference(_start ?? DateTime.now()).inMilliseconds.clamp(0, _max.inMilliseconds);
    if (!mounted) return;
    setState(() {
      _recording = false;
      _ms = ms;
      _path = ms >= 500 ? path : null;
    });
    if (_path != null) {
      SoundStickerPlayer.play(widget.stickerId, messageId: 'preview', filePath: _path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final secs = (_ms / 1000).toStringAsFixed(1);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Tu voz en un sticker', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Mantén pulsado el micrófono y di algo (hasta 6 segundos).',
              textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65))),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _path == null
                ? null
                : () => SoundStickerPlayer.play(widget.stickerId, messageId: 'preview', filePath: _path),
            child: Stack(clipBehavior: Clip.none, children: [
              Image.asset(stickerAsset(widget.stickerId), width: 140, height: 140),
              if (_path != null)
                ValueListenableBuilder<String?>(
                  valueListenable: SoundStickerPlayer.playing,
                  builder: (_, now, __) =>
                      Positioned(right: 4, bottom: 4, child: SoundBadge(active: now == 'preview')),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _ms / _max.inMilliseconds,
                backgroundColor: cs.surfaceContainerHighest,
                color: _recording ? const Color(0xFFE63946) : cs.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(_recording ? 'Grabando… $secs s' : (_path == null ? ' ' : '$secs s · toca el sticker para oírlo'),
              style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: _recording ? null : () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
            ),
            GestureDetector(
              onLongPressStart: (_) => _startRec(),
              onLongPressEnd: (_) => _stopRec(),
              onTap: () => _recording ? _stopRec() : _startRec(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: _recording ? 78 : 66,
                height: _recording ? 78 : 66,
                decoration: BoxDecoration(
                  color: _recording ? const Color(0xFFE63946) : cs.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded, color: Colors.white, size: 32),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: _path == null || _recording
                    ? null
                    : () {
                        _sent = true;
                        Navigator.pop(context, (path: _path!, ms: _ms));
                      },
                child: const Text('Enviar', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Pestaña «Con sonido» del selector: los de KLK, o elige uno y ponle tu voz.
class SoundStickerTab extends StatefulWidget {
  final Widget Function(List<KlkSticker> list, {required bool sound, String prefix}) grid;
  const SoundStickerTab({super.key, required this.grid});

  @override
  State<SoundStickerTab> createState() => _SoundStickerTabState();
}

class _SoundStickerTabState extends State<SoundStickerTab> {
  bool _mine = false;

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.record_voice_over_rounded), label: Text('Voz KLK')),
              ButtonSegment(value: true, icon: Icon(Icons.mic_rounded), label: Text('Con mi voz')),
            ],
            selected: {_mine},
            onSelectionChanged: (v) => setState(() => _mine = v.first),
          ),
        ),
        if (_mine)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Elige un sticker y graba lo que quieras decir.',
                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Mantén pulsado para oírlo antes de enviarlo.',
                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
          ),
        Expanded(
          child: _mine
              ? widget.grid(klkStickers, sound: false, prefix: 'rec:')
              : widget.grid(soundStickers.stickers, sound: true),
        ),
      ]);
}
