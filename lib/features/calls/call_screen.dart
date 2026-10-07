import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../chat/presentation/chat_avatar.dart';
import '../messaging/models.dart';
import 'call_controller.dart';

/// Pantalla de llamada: entrante, saliente y en curso (voz o vídeo).
class CallScreen extends ConsumerWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    final chat = call.chat;
    final title = chat?.title ?? '';
    final showRemoteVideo = call.phase == CallPhase.active && call.remoteVideo;
    final showLocalVideo = call.video && !call.cameraOff && call.phase != CallPhase.incoming;

    final statusText = switch (call.phase) {
      CallPhase.active => formatDuration(call.elapsed.inMilliseconds),
      _ => call.status,
    };

    return PopScope(
      canPop: call.phase == CallPhase.idle || call.phase == CallPhase.ended,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1320),
        body: Stack(fit: StackFit.expand, children: [
          // Fondo: vídeo del otro, o mi cámara mientras suena, o degradado
          if (showRemoteVideo)
            RTCVideoView(call.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else if (showLocalVideo && call.phase != CallPhase.active)
            RTCVideoView(call.localRenderer,
                mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
          else
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF002D62), Color(0xFF0B1320)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

          // Mi cámara en miniatura durante la videollamada
          if (showLocalVideo && call.phase == CallPhase.active)
            Positioned(
              right: 16,
              top: MediaQuery.paddingOf(context).top + 16,
              width: 110,
              height: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: RTCVideoView(call.localRenderer,
                    mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              ),
            ),

          // Nombre, foto y estado
          SafeArea(
            child: Column(children: [
              const SizedBox(height: 40),
              if (!showRemoteVideo) ...[
                ChatAvatar(id: chat?.id ?? '', title: title, photoPath: chat?.avatarPath, radius: 56),
                const SizedBox(height: 18),
              ],
              Text(title,
                  style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black54)])),
              const SizedBox(height: 6),
              Text(statusText,
                  style: const TextStyle(color: Colors.white70, fontSize: 16,
                      fontFeatures: [FontFeature.tabularFigures()],
                      shadows: [Shadow(blurRadius: 8, color: Colors.black54)])),
              const SizedBox(height: 6),
              Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.lock, size: 13, color: Colors.white54),
                SizedBox(width: 4),
                Text('Cifrada de punta a punta', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ]),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: call.phase == CallPhase.incoming ? _IncomingControls(call: call) : _ActiveControls(call: call),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _IncomingControls extends StatelessWidget {
  final CallController call;
  const _IncomingControls({required this.call});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _RoundButton(icon: Icons.call_end, label: 'Rechazar', color: const Color(0xFFE53935), onTap: call.reject),
          if (call.video)
            _RoundButton(
                icon: Icons.call, label: 'Solo voz', color: const Color(0xFF43A047),
                onTap: () => call.accept(withVideo: false)),
          _RoundButton(
            icon: call.video ? Icons.videocam : Icons.call,
            label: 'Contestar',
            color: const Color(0xFF43A047),
            onTap: () => call.accept(),
          ),
        ],
      );
}

class _ActiveControls extends StatelessWidget {
  final CallController call;
  const _ActiveControls({required this.call});

  @override
  Widget build(BuildContext context) {
    final ended = call.phase == CallPhase.ended;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundButton(
          icon: call.muted ? Icons.mic_off : Icons.mic,
          label: call.muted ? 'Activar' : 'Silenciar',
          active: call.muted,
          onTap: ended ? null : call.toggleMute,
        ),
        _RoundButton(
          icon: call.speaker ? Icons.volume_up : Icons.volume_down,
          label: 'Altavoz',
          active: call.speaker,
          onTap: ended ? null : call.toggleSpeaker,
        ),
        if (call.video) ...[
          _RoundButton(
            icon: call.cameraOff ? Icons.videocam_off : Icons.videocam,
            label: 'Cámara',
            active: call.cameraOff,
            onTap: ended ? null : call.toggleCamera,
          ),
          _RoundButton(icon: Icons.cameraswitch, label: 'Girar', onTap: ended ? null : call.switchCamera),
        ],
      ]),
      const SizedBox(height: 28),
      _RoundButton(
        icon: Icons.call_end,
        label: ended ? '' : 'Colgar',
        color: const Color(0xFFE53935),
        size: 72,
        onTap: ended ? null : call.hangUp,
      ),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final bool active;
  final double size;
  final VoidCallback? onTap;

  const _RoundButton({
    required this.icon,
    required this.label,
    this.color,
    this.active = false,
    this.size = 60,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (active ? Colors.white : Colors.white24);
    final fg = color != null ? Colors.white : (active ? const Color(0xFF0B1320) : Colors.white);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Icon(icon, color: fg, size: size * 0.45)),
        ),
      ),
      if (label.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    ]);
  }
}
