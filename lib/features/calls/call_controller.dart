import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../../core/config.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'call_screen.dart';

/// Clave del navegador global, para poder abrir la pantalla de llamada
/// desde cualquier sitio (p. ej. cuando entra una llamada).
final navigatorKeyProvider = Provider<GlobalKey<NavigatorState>>((_) => GlobalKey<NavigatorState>());

final callProvider = ChangeNotifierProvider<CallController>((ref) => CallController(ref));

enum CallPhase { idle, outgoing, incoming, connecting, active, ended }

/// Llamadas de voz y vídeo con WebRTC.
///
/// - El audio y el vídeo viajan directamente entre los dos móviles,
///   cifrados con DTLS-SRTP (como WhatsApp y Signal).
/// - La "señalización" (oferta, respuesta, candidatos de red, colgar) viaja
///   como mensajes cifrados de KLK, así que el servidor no ve nada.
class CallController extends ChangeNotifier {
  CallController(this._ref) {
    _app.onCallSignal = _onSignal;
  }

  final Ref _ref;
  static const _uuid = Uuid();
  AppController get _app => _ref.read(appProvider);

  CallPhase phase = CallPhase.idle;
  String? chatId;
  String? callId;
  bool video = false;
  bool incoming = false;
  bool muted = false;
  bool speaker = false;
  bool cameraOff = false;
  bool remoteVideo = false;
  DateTime? startedAt;
  String status = '';

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  Map<String, dynamic>? _pendingOffer;
  final List<RTCIceCandidate> _pendingIce = [];
  bool _remoteSet = false;
  Timer? _ringTimeout;
  Timer? _vibrate;
  Timer? _tick;
  bool _screenOpen = false;

  bool get busy => phase != CallPhase.idle;
  Chat? get chat => chatId == null ? null : _app.chatById(chatId!);

  Duration get elapsed => startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  static Map<String, dynamic> get _rtcConfig => {
        'iceServers': [
          {
            'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
          },
          if (KlkConfig.turnUrl.isNotEmpty)
            {'urls': KlkConfig.turnUrl, 'username': KlkConfig.turnUser, 'credential': KlkConfig.turnPass},
        ],
        'sdpSemantics': 'unified-plan',
      };

  // ---------- Llamar ----------

  Future<void> startCall(String chatId, {required bool video}) async {
    if (busy) return;
    this.chatId = chatId;
    callId = _uuid.v4();
    this.video = video;
    incoming = false;
    speaker = video;
    _setPhase(CallPhase.outgoing, 'Llamando…');
    _openScreen();

    try {
      await _prepareMedia();
      if (_app.isDemo) {
        _demoAnswer();
        return;
      }
      await _createPeer();
      final offer = await _pc!.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': video});
      await _pc!.setLocalDescription(offer);
      await _signal({'a': 'offer', 'sdp': offer.sdp, 'v': video});
      _setPhase(CallPhase.outgoing, 'Sonando…');
      _ringTimeout = Timer(const Duration(seconds: 45), () => _finish('Sin respuesta', notifyPeer: true, missed: true));
    } catch (e) {
      debugPrint('Llamada: $e');
      await _finish(_permissionMessage(e));
    }
  }

  /// Contesta una llamada entrante (con vídeo si la llamada es de vídeo y [withVideo]).
  Future<void> accept({bool withVideo = true}) async {
    final offer = _pendingOffer;
    if (phase != CallPhase.incoming || offer == null) return;
    _stopRinging();
    video = video && withVideo;
    speaker = video;
    _setPhase(CallPhase.connecting, 'Conectando…');
    try {
      await _prepareMedia();
      await _createPeer();
      await _pc!.setRemoteDescription(RTCSessionDescription(offer['sdp'] as String, 'offer'));
      _remoteSet = true;
      await _drainIce();
      final answer = await _pc!.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
      await _pc!.setLocalDescription(answer);
      await _signal({'a': 'answer', 'sdp': answer.sdp});
    } catch (e) {
      debugPrint('Contestar: $e');
      await _finish(_permissionMessage(e), notifyPeer: true);
    }
  }

  Future<void> reject() async {
    if (phase != CallPhase.incoming) return;
    await _signal({'a': 'reject'});
    await _finish('Llamada rechazada', missed: true);
  }

  Future<void> hangUp() => _finish(phase == CallPhase.active ? 'Llamada finalizada' : 'Llamada cancelada',
      notifyPeer: true, missed: phase == CallPhase.outgoing);

  // ---------- Controles ----------

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    cameraOff = !cameraOff;
    for (final t in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !cameraOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? [];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
    notifyListeners();
  }

  // ---------- Señales recibidas ----------

  Future<void> _onSignal(String from, Map<String, dynamic> s) async {
    final action = s['a'] as String?;
    final id = s['id'] as String?;

    if (action == 'offer') {
      if (busy) {
        // Ya estoy en otra llamada: aviso de que estoy ocupado.
        await _app.sendCallSignal(from, {'a': 'busy', 'id': id});
        return;
      }
      chatId = from;
      callId = id;
      video = s['v'] == true;
      incoming = true;
      _pendingOffer = s;
      _remoteSet = false;
      _pendingIce.clear();
      _setPhase(CallPhase.incoming, video ? 'Videollamada entrante' : 'Llamada entrante');
      _startRinging();
      _openScreen();
      _ringTimeout = Timer(const Duration(seconds: 45), () => _finish('Llamada perdida', missed: true));
      return;
    }

    if (from != chatId || id != callId) return; // señal de otra llamada

    switch (action) {
      case 'answer':
        {
          _ringTimeout?.cancel();
          _setPhase(CallPhase.connecting, 'Conectando…');
          await _pc?.setRemoteDescription(RTCSessionDescription(s['sdp'] as String, 'answer'));
          _remoteSet = true;
          await _drainIce();
        }
      case 'ice':
        {
          final c = RTCIceCandidate(s['c'] as String?, s['m'] as String?, (s['i'] as num?)?.toInt());
          if (_pc != null && _remoteSet) {
            await _pc!.addCandidate(c);
          } else {
            _pendingIce.add(c);
          }
        }
      case 'reject':
        await _finish('No puede contestar ahora');
      case 'busy':
        await _finish('Está en otra llamada');
      case 'end':
        await _finish(phase == CallPhase.incoming ? 'Llamada perdida' : 'Llamada finalizada',
            missed: phase == CallPhase.incoming);
    }
  }

  // ---------- Internos ----------

  Future<void> _prepareMedia() async {
    if (!_renderersReady) {
      await localRenderer.initialize();
      await remoteRenderer.initialize();
      _renderersReady = true;
    }
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video ? {'facingMode': 'user'} : false,
    });
    localRenderer.srcObject = _local;
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _createPeer() async {
    final pc = await createPeerConnection(_rtcConfig);
    _pc = pc;
    for (final t in _local!.getTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _signal({'a': 'ice', 'c': c.candidate, 'm': c.sdpMid, 'i': c.sdpMLineIndex});
    };
    pc.onTrack = (e) {
      if (e.streams.isEmpty) return;
      remoteRenderer.srcObject = e.streams.first;
      if (e.track.kind == 'video') remoteVideo = true;
      notifyListeners();
    };
    pc.onConnectionState = (st) {
      if (st == RTCPeerConnectionState.RTCPeerConnectionStateConnected && phase != CallPhase.active) {
        _ringTimeout?.cancel();
        startedAt = DateTime.now();
        _setPhase(CallPhase.active, '');
        _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
      } else if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _finish('Se perdió la conexión', notifyPeer: true);
      }
    };
  }

  Future<void> _drainIce() async {
    for (final c in List.of(_pendingIce)) {
      await _pc?.addCandidate(c);
    }
    _pendingIce.clear();
  }

  Future<void> _signal(Map<String, dynamic> s) async {
    final id = chatId;
    if (id == null) return;
    try {
      await _app.sendCallSignal(id, {...s, 'id': callId});
    } catch (e) {
      debugPrint('Señal de llamada: $e');
    }
  }

  void _setPhase(CallPhase p, String text) {
    phase = p;
    status = text;
    notifyListeners();
  }

  void _startRinging() {
    _vibrate?.cancel();
    HapticFeedback.heavyImpact();
    _vibrate = Timer.periodic(const Duration(milliseconds: 1500), (_) => HapticFeedback.heavyImpact());
  }

  void _stopRinging() {
    _vibrate?.cancel();
    _vibrate = null;
  }

  Future<void> _finish(String reason, {bool notifyPeer = false, bool missed = false}) async {
    if (phase == CallPhase.idle || phase == CallPhase.ended) return;
    if (notifyPeer) await _signal({'a': 'end'});

    final talked = startedAt == null ? null : elapsed;
    final id = chatId;
    _ringTimeout?.cancel();
    _tick?.cancel();
    _stopRinging();

    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _local?.dispose();
    _local = null;
    await _pc?.close();
    _pc = null;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    _pendingOffer = null;
    _pendingIce.clear();
    _remoteSet = false;

    // Registro en el chat
    if (id != null) {
      final kind = video ? 'Videollamada' : 'Llamada de voz';
      final text = talked != null
          ? '${incoming ? '📞' : '📱'} $kind · ${formatDuration(talked.inMilliseconds)}'
          : missed && incoming
              ? '📵 $kind perdida'
              : '📵 $kind · $reason';
      await _app.logCall(id, text, incoming: incoming);
    }

    _setPhase(CallPhase.ended, reason);
    await Future.delayed(const Duration(milliseconds: 1500));
    phase = CallPhase.idle;
    chatId = null;
    callId = null;
    startedAt = null;
    muted = false;
    cameraOff = false;
    remoteVideo = false;
    notifyListeners();
    _closeScreen();
  }

  String _permissionMessage(Object e) {
    final t = e.toString().toLowerCase();
    if (t.contains('permission') || t.contains('notallowed') || t.contains('denied')) {
      return video ? 'KLK no tiene permiso para la cámara o el micrófono' : 'KLK no tiene permiso para el micrófono';
    }
    return 'No se pudo conectar la llamada';
  }

  void _openScreen() {
    if (_screenOpen) return;
    final nav = _ref.read(navigatorKeyProvider).currentState;
    if (nav == null) return;
    _screenOpen = true;
    nav.push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CallScreen())).then((_) {
      _screenOpen = false;
    });
  }

  void _closeScreen() {
    if (!_screenOpen) return;
    _ref.read(navigatorKeyProvider).currentState?.maybePop();
  }

  // ---------- Modo demo ----------

  /// Sin servidor: simula que el contacto contesta a los 3 segundos.
  /// La cámara y el micrófono propios funcionan de verdad.
  void _demoAnswer() {
    _setPhase(CallPhase.outgoing, 'Sonando…');
    _ringTimeout = Timer(const Duration(seconds: 3), () {
      startedAt = DateTime.now();
      _setPhase(CallPhase.active, '');
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    });
  }

  @override
  void dispose() {
    _ringTimeout?.cancel();
    _vibrate?.cancel();
    _tick?.cancel();
    if (_renderersReady) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}
