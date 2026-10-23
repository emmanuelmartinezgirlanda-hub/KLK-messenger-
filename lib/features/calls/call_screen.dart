import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_screen.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'call_controller.dart';
import 'video_filters.dart';
import '../../core/l10n/l10n.dart';
import '../plus/plus_screen.dart';
import '../plus/plus_state.dart';

/// Pantalla de llamada (entrante, saliente y en curso), al estilo de WhatsApp:
/// botones de cristal abajo, mi cámara en una ventanita que se puede mover,
/// y se puede minimizar para seguir usando KLK mientras hablas.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  bool _controls = true;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  /// En videollamada, los botones se esconden solos para ver mejor la imagen.
  void _poke({bool toggle = false}) {
    _hide?.cancel();
    setState(() => _controls = toggle ? !_controls : true);
    if (_controls) {
      _hide = Timer(const Duration(seconds: 6), () {
        final call = ref.read(callProvider);
        if (mounted && call.phase == CallPhase.active && call.remoteVideo) setState(() => _controls = false);
      });
    }
  }

  void _minimize() {
    HapticFeedback.selectionClick();
    Navigator.of(context).maybePop();
  }

  void _openChat(CallController call) {
    final id = call.chatId;
    final nav = Navigator.of(context);
    nav.maybePop();
    if (id != null && ref.read(appProvider).openChatId != id) {
      nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final chat = call.chat;
    final title = chat?.title ?? '';
    final ended = call.phase == CallPhase.ended;
    final showRemoteVideo = call.phase == CallPhase.active && call.remoteVideo;
    final showLocalVideo = call.video && !call.cameraOff && call.phase != CallPhase.incoming && !ended;
    final controls = _controls || !showRemoteVideo || call.phase != CallPhase.active;
    final pad = MediaQuery.paddingOf(context);

    final statusText = switch (call.phase) {
      CallPhase.active when call.reconnecting => tr('Reconectando… (mala señal)'),
      CallPhase.active => formatDuration(call.elapsed.inMilliseconds),
      _ => call.status,
    };

    const shadow = [Shadow(blurRadius: 10, color: Colors.black54)];

    return Scaffold(
      backgroundColor: const Color(0xFF0B1320),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: showRemoteVideo ? () => _poke(toggle: true) : null,
        child: Stack(fit: StackFit.expand, children: [
          // Fondo: vídeo del otro, o mi cámara mientras suena, o degradado
          if (showRemoteVideo)
            withVideoFilter(call.remoteFilter,
                RTCVideoView(call.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))
          else if (showLocalVideo && call.phase != CallPhase.active)
            withVideoFilter(
                call.myFilter,
                RTCVideoView(call.localRenderer,
                    mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover))
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

          // Sin vídeo del otro: su foto grande en el centro
          if (!showRemoteVideo)
            Align(
              alignment: const Alignment(0, -0.35),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ChatAvatar(id: chat?.id ?? '', title: title, photoPath: chat?.avatarPath, radius: 60),
                const SizedBox(height: 18),
                Text(title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700, shadows: shadow)),
                const SizedBox(height: 6),
                Text(statusText,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 17,
                        fontFeatures: [FontFeature.tabularFigures()],
                        shadows: shadow)),
                const SizedBox(height: 8),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock, size: 13, color: Colors.white54),
                  const SizedBox(width: 4),
                  Text(tr('Cifrada de punta a punta'), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ]),
            ),

          // Mi cámara en una ventanita que se arrastra a cualquier esquina
          if (showLocalVideo && call.phase == CallPhase.active)
            _SelfView(
              call: call,
              top: pad.top + 84,
              bottom: pad.bottom + 120,
              onEffects: () => _showEffects(context),
            ),

          // Arriba: minimizar · nombre y tiempo · chat
          AnimatedOpacity(
            opacity: controls ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: IgnorePointer(
              ignoring: !controls,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, pad.top + 8, 16, 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _GlassCircle(
                    icon: Icons.close_fullscreen_rounded,
                    tooltip: tr('Minimizar'),
                    onTap: _minimize,
                  ),
                  Expanded(
                    child: showRemoteVideo
                        ? Column(children: [
                            const SizedBox(height: 4),
                            Text(title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, shadows: shadow)),
                            Text(statusText,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                    shadows: shadow)),
                          ])
                        : const SizedBox.shrink(),
                  ),
                  _GlassCircle(
                    icon: Icons.chat_bubble_rounded,
                    tooltip: tr('Abrir el chat'),
                    onTap: chat == null ? null : () => _openChat(call),
                  ),
                ]),
              ),
            ),
          ),

          // Abajo: subtítulos y botones
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedSlide(
              offset: controls ? Offset.zero : const Offset(0, 1.2),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: Padding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, pad.bottom + 14),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (call.captionsOn || call.sendingCaptions || call.captionError != null) _Captions(call: call),
                  if (call.phase == CallPhase.incoming)
                    _IncomingControls(call: call)
                  else
                    _GlassBar(
                      call: call,
                      onMore: () => _showMore(context),
                    ),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  void _showMore(BuildContext context) {
    _poke();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      showDragHandle: true,
      builder: (ctx) => Consumer(builder: (ctx, ref, _) {
        final call = ref.watch(callProvider);
        final active = call.phase == CallPhase.active;
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.closed_caption_rounded, color: Colors.white),
              title: Text(tr('Subtítulos traducidos'), style: const TextStyle(color: Colors.white)),
              subtitle: Text(tr('Lee lo que dice la otra persona, en tu idioma'),
                  style: const TextStyle(color: Colors.white60)),
              trailing: Switch(
                value: call.captionsOn,
                onChanged: !active
                    ? null
                    : (_) => plusActive.value || call.captionsOn
                        ? call.toggleCaptions()
                        : showPlusRequired(context, 'Los subtítulos traducidos'),
              ),
            ),
            if (call.video) ...[
              ListTile(
                leading: const Icon(Icons.auto_fix_high_rounded, color: Colors.white),
                title: Text(tr('Efectos de cámara'), style: const TextStyle(color: Colors.white)),
                onTap: call.cameraOff
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _showEffects(context);
                      },
              ),
              ListTile(
                leading: const Icon(Icons.cameraswitch_rounded, color: Colors.white),
                title: Text(tr('Girar la cámara'), style: const TextStyle(color: Colors.white)),
                onTap: call.cameraOff ? null : call.switchCamera,
              ),
            ],
            ListTile(
              leading: const Icon(Icons.chat_bubble_rounded, color: Colors.white),
              title: Text(tr('Abrir el chat'), style: const TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _openChat(call);
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_rounded, color: Color(0xFF5FD39A)),
              title: Text(tr('Cifrada de punta a punta'), style: const TextStyle(color: Colors.white)),
              subtitle: Text(tr('Nadie más puede ver ni escuchar esta llamada, ni siquiera KLK.'),
                  style: const TextStyle(color: Colors.white60)),
            ),
            const SizedBox(height: 8),
          ]),
        );
      }),
    );
  }

  void _showEffects(BuildContext context) {
    _poke();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Efectos'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(tr('La otra persona te ve con el mismo efecto.'), style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 14),
            Consumer(builder: (_, ref, __) => _FilterStrip(call: ref.watch(callProvider))),
          ]),
        ),
      ),
    );
  }
}

/// Botón redondo de cristal (arriba de la pantalla y en mi ventanita).
class _GlassCircle extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final bool light;
  const _GlassCircle({required this.icon, required this.tooltip, this.onTap, this.size = 52, this.light = false});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Material(
              color: light ? Colors.white : Colors.black.withValues(alpha: 0.38),
              child: InkWell(
                onTap: onTap == null
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        onTap!();
                      },
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Icon(icon, color: light ? Colors.black : Colors.white, size: size * 0.46),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Barra de cristal de abajo: más · vídeo · altavoz · micrófono · colgar.
class _GlassBar extends StatelessWidget {
  final CallController call;
  final VoidCallback onMore;
  const _GlassBar({required this.call, required this.onMore});

  @override
  Widget build(BuildContext context) {
    final ended = call.phase == CallPhase.ended;
    return ClipRRect(
      borderRadius: BorderRadius.circular(44),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.32),
            borderRadius: BorderRadius.circular(44),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _BarButton(icon: Icons.more_horiz_rounded, label: tr('Más'), onTap: ended ? null : onMore),
            if (call.video)
              _BarButton(
                icon: call.cameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
                label: call.cameraOff ? tr('Encender cámara') : tr('Apagar cámara'),
                on: !call.cameraOff,
                onTap: ended ? null : call.toggleCamera,
              ),
            _BarButton(
              icon: call.speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
              label: tr('Altavoz'),
              on: call.speaker,
              onTap: ended ? null : call.toggleSpeaker,
            ),
            _BarButton(
              icon: call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              label: call.muted ? tr('Activar micrófono') : tr('Silenciar'),
              on: call.muted,
              onTap: ended ? null : call.toggleMute,
            ),
            _BarButton(
              icon: Icons.call_end_rounded,
              label: tr('Colgar'),
              color: const Color(0xFFE5243B),
              onTap: ended ? null : call.hangUp,
            ),
          ]),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final Color? color;
  final VoidCallback? onTap;
  const _BarButton({required this.icon, required this.label, this.on = false, this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (on ? Colors.white : Colors.black.withValues(alpha: 0.45));
    final fg = color != null ? Colors.white : (on ? Colors.black : Colors.white);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        toggled: color == null ? on : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 58,
          height: 58,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap == null
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      onTap!();
                    },
              child: Icon(icon, color: onTap == null ? fg.withValues(alpha: 0.4) : fg, size: 28),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mi cámara en pequeño. Se arrastra y se pega a la esquina más cercana.
class _SelfView extends StatefulWidget {
  final CallController call;
  final double top;
  final double bottom;
  final VoidCallback onEffects;
  const _SelfView({required this.call, required this.top, required this.bottom, required this.onEffects});

  @override
  State<_SelfView> createState() => _SelfViewState();
}

class _SelfViewState extends State<_SelfView> {
  static const _w = 124.0, _h = 184.0, _m = 14.0;
  Offset? _pos; // esquina de arriba a la izquierda
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final minX = _m, maxX = size.width - _w - _m;
    final minY = widget.top, maxY = size.height - widget.bottom - _h;
    final pos = _pos ?? Offset(maxX, maxY);

    return AnimatedPositioned(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      left: pos.dx.clamp(minX, maxX),
      top: pos.dy.clamp(minY, maxY < minY ? minY : maxY),
      width: _w,
      height: _h,
      child: GestureDetector(
        onPanStart: (_) => setState(() => _dragging = true),
        onPanUpdate: (d) => setState(() => _pos = pos + d.delta),
        onPanEnd: (_) {
          final p = _pos ?? pos;
          setState(() {
            _dragging = false;
            _pos = Offset(
              p.dx + _w / 2 < size.width / 2 ? minX : maxX,
              p.dy + _h / 2 < (minY + maxY + _h) / 2 ? minY : maxY,
            );
          });
          HapticFeedback.selectionClick();
        },
        child: Stack(fit: StackFit.expand, children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 18, offset: Offset(0, 8))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: withVideoFilter(
                widget.call.myFilter,
                RTCVideoView(widget.call.localRenderer,
                    mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
              ),
            ),
          ),
          Positioned(
            right: 6,
            top: 6,
            child: Column(children: [
              _GlassCircle(
                icon: Icons.cameraswitch_rounded,
                tooltip: tr('Girar la cámara'),
                size: 40,
                onTap: widget.call.switchCamera,
              ),
              const SizedBox(height: 8),
              _GlassCircle(
                icon: Icons.auto_fix_high_rounded,
                tooltip: tr('Efectos'),
                size: 40,
                light: true,
                onTap: widget.onEffects,
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
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _RoundButton(icon: Icons.call_end, label: tr('Rechazar'), color: const Color(0xFFE53935), onTap: call.reject),
            if (call.video)
              _RoundButton(
                  icon: Icons.call,
                  label: tr('Solo voz'),
                  color: const Color(0xFF43A047),
                  onTap: () => call.accept(withVideo: false)),
            _RoundButton(
              icon: call.video ? Icons.videocam : Icons.call,
              label: tr('Contestar'),
              color: const Color(0xFF43A047),
              onTap: () => call.accept(),
            ),
          ],
        ),
      );
}

/// Subtítulos traducidos: lo que dice el otro, en mi idioma.
class _Captions extends StatelessWidget {
  final CallController call;
  const _Captions({required this.call});

  @override
  Widget build(BuildContext context) {
    final translated = call.remoteCaptionTranslated;
    final original = call.remoteCaption;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (call.captionsOn)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(16)),
            child: original.isEmpty
                ? Text(tr('Subtítulos activados. Cuando hable, lo verás aquí en tu idioma.'),
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14))
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(translated ?? original,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600, height: 1.3)),
                    if (translated != null) ...[
                      const SizedBox(height: 6),
                      Text(original,
                          textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 13.5)),
                    ],
                  ]),
          ),
        if (call.sendingCaptions)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('🎙️ ${call.chat?.title ?? 'La otra persona'} activó subtítulos: tu voz se pasa a texto en tu móvil.',
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          ),
        if (call.captionError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(call.captionError!,
                textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFFC46B), fontSize: 13)),
          ),
      ]),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final double size;
  final VoidCallback? onTap;

  const _RoundButton({required this.icon, required this.label, this.color, this.size = 68, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = color ?? Colors.white24;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Icon(icon, color: Colors.white, size: size * 0.45)),
        ),
      ),
      if (label.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
      ],
    ]);
  }
}

/// Filtros de color para mi cámara (se ven igual en el otro móvil).
class _FilterStrip extends StatelessWidget {
  final CallController call;
  const _FilterStrip({required this.call});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: videoFilters.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final on = call.myFilter == i;
            return ChoiceChip(
              label: Text(videoFilters[i].name),
              selected: on,
              onSelected: (_) => call.setFilter(i),
              labelStyle: TextStyle(color: on ? const Color(0xFF0B1320) : Colors.white, fontSize: 13),
              selectedColor: Colors.white,
              backgroundColor: Colors.white24,
              side: BorderSide.none,
              showCheckmark: false,
            );
          },
        ),
      );
}

/// Barra verde arriba cuando la llamada está minimizada: tócala para volver.
class OngoingCallBanner extends ConsumerWidget {
  const OngoingCallBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    final show = call.busy && !call.screenOpen && call.phase != CallPhase.ended;
    final text = switch (call.phase) {
      CallPhase.incoming => tr('Llamada entrante · toca para contestar'),
      CallPhase.active => '${call.chat?.title ?? ''} · ${formatDuration(call.elapsed.inMilliseconds)}',
      _ => '${call.chat?.title ?? ''} · ${call.status}',
    };
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedSlide(
        offset: show ? Offset.zero : const Offset(0, -1.5),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        child: SafeArea(
          bottom: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Material(
                color: const Color(0xFF1FA855),
                borderRadius: BorderRadius.circular(22),
                elevation: 6,
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: show ? call.reopenScreen : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(call.video ? Icons.videocam_rounded : Icons.call_rounded, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [FontFeature.tabularFigures()])),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
