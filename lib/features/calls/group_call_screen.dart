import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/l10n/l10n.dart';
import '../messaging/models.dart';
import 'call_controller.dart';
import 'group_call_controller.dart';

/// Pantalla de la llamada / videollamada de grupo: hasta 4 personas en cuadrícula.
class GroupCallScreen extends ConsumerWidget {
  const GroupCallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(groupCallProvider);
    final title = call.chat?.title ?? tr('Grupo');
    final incoming = call.phase == GroupPhase.incoming;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1320),
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 12),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            incoming
                ? '${call.nameOf(call.inviter ?? '')} · ${tr(call.status)}'
                : call.status.isNotEmpty
                    ? tr(call.status)
                    : '${call.people} ${tr('personas')} · ${formatDuration(call.elapsed.inMilliseconds)}',
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 12),
          Expanded(child: incoming ? _Incoming(call: call) : _Grid(call: call)),
          if (incoming) _IncomingButtons(call: call) else _Controls(call: call),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }
}

class _Incoming extends StatelessWidget {
  final GroupCallController call;
  const _Incoming({required this.call});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 120,
            height: 120,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1E2A44)),
            child: Icon(call.video ? Icons.videocam_rounded : Icons.groups_rounded, color: Colors.white, size: 60),
          ),
          const SizedBox(height: 16),
          Text(tr('Te están llamando en el grupo'), style: const TextStyle(color: Colors.white, fontSize: 17)),
        ]),
      );
}

class _Grid extends StatelessWidget {
  final GroupCallController call;
  const _Grid({required this.call});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _Tile(
        name: tr('Tú'),
        renderer: call.localRenderer,
        showVideo: call.video && !call.cameraOff,
        mirror: call.frontCamera,
        muted: call.muted,
      ),
      for (final p in call.peers.values)
        _Tile(name: p.name, renderer: p.renderer, showVideo: p.hasVideo, connecting: !p.connected),
    ];
    final cols = tiles.length <= 1 ? 1 : 2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LayoutBuilder(builder: (context, c) {
        final rows = (tiles.length / cols).ceil();
        final h = (c.maxHeight - (rows - 1) * 8) / rows;
        final w = (c.maxWidth - (cols - 1) * 8) / cols;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final t in tiles) SizedBox(width: tiles.length == 3 && t == tiles.last ? c.maxWidth : w, height: h, child: t),
          ],
        );
      }),
    );
  }
}

class _Tile extends StatelessWidget {
  final String name;
  final RTCVideoRenderer renderer;
  final bool showVideo;
  final bool mirror;
  final bool muted;
  final bool connecting;
  const _Tile({
    required this.name,
    required this.renderer,
    required this.showVideo,
    this.mirror = false,
    this.muted = false,
    this.connecting = false,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Container(
          color: const Color(0xFF1A2438),
          child: Stack(fit: StackFit.expand, children: [
            if (showVideo)
              RTCVideoView(renderer, mirror: mirror, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
            else
              Center(
                child: CircleAvatar(
                  radius: 34,
                  backgroundColor: const Color(0xFF2B3A5C),
                  child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                ),
              ),
            Positioned(
              left: 10,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (muted) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.mic_off, color: Colors.white, size: 14)),
                  Text(connecting ? '$name · ${tr('conectando…')}' : name,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ]),
        ),
      );
}

class _IncomingButtons extends StatelessWidget {
  final GroupCallController call;
  const _IncomingButtons({required this.call});

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _Btn(icon: Icons.call_end, color: const Color(0xFFCE1126), label: tr('Rechazar'), onTap: call.reject),
        if (call.video)
          _Btn(icon: Icons.call, color: const Color(0xFF1E8E3E), label: tr('Solo voz'), onTap: () => call.accept(withVideo: false)),
        _Btn(
          icon: call.video ? Icons.videocam : Icons.call,
          color: const Color(0xFF1E8E3E),
          label: tr('Unirme'),
          onTap: () => call.accept(),
        ),
      ]);
}

class _Controls extends StatelessWidget {
  final GroupCallController call;
  const _Controls({required this.call});

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _Btn(icon: call.muted ? Icons.mic_off : Icons.mic, label: tr('Silencio'), active: call.muted, onTap: call.toggleMute),
        if (call.video) ...[
          _Btn(icon: call.cameraOff ? Icons.videocam_off : Icons.videocam, label: tr('Cámara'), active: call.cameraOff, onTap: call.toggleCamera),
          _Btn(icon: Icons.cameraswitch, label: tr('Girar'), onTap: call.switchCamera),
          _Btn(icon: Icons.auto_awesome, label: tr('Belleza'), onTap: () => _beauty(context)),
        ] else
          _Btn(icon: call.speaker ? Icons.volume_up : Icons.hearing, label: tr('Altavoz'), active: call.speaker, onTap: call.toggleSpeaker),
        _Btn(icon: Icons.call_end, color: const Color(0xFFCE1126), label: tr('Salir'), onTap: call.hangUp),
      ]);

  void _beauty(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Consumer(builder: (_, ref, __) {
            final single = ref.watch(callProvider);
            final g = ref.watch(groupCallProvider);
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('✨ ${tr('Belleza')}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(tr('Suaviza tu piel y da luz. Los demás te ven con el efecto.'), style: const TextStyle(color: Colors.white60)),
              Slider(
                value: single.beauty,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  g.setBeauty(v < 0.05 ? 0 : v);
                },
              ),
            ]);
          }),
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool active;
  const _Btn({required this.icon, required this.label, required this.onTap, this.color, this.active = false});

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Material(
          color: color ?? (active ? Colors.white : Colors.white24),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              HapticFeedback.lightImpact();
              onTap();
            },
            child: SizedBox(
              width: 60,
              height: 60,
              child: Icon(icon, color: color == null && active ? const Color(0xFF0B1320) : Colors.white, size: 28),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ]);
}
