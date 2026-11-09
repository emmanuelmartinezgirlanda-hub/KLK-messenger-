import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:klk_native/klk_native.dart';
import 'package:uuid/uuid.dart';

import '../../core/config.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'call_controller.dart';
import 'call_quality.dart';
import 'group_call_screen.dart';

final groupCallProvider = ChangeNotifierProvider<GroupCallController>((ref) => GroupCallController.ensure(ref));

enum GroupPhase { idle, incoming, active, ended }

/// Una persona conectada en la llamada de grupo.
class GroupPeer {
  GroupPeer(this.id, this.name);
  final String id;
  final String name;
  RTCPeerConnection? pc;
  final renderer = RTCVideoRenderer();
  bool rendererReady = false;
  bool hasVideo = false;
  bool connected = false;
  bool remoteSet = false;
  final pendingIce = <RTCIceCandidate>[];
}

/// Llamadas y videollamadas en grupo (hasta [maxPeople] personas contándome a mí).
///
/// Cada móvil se conecta directamente con los demás («malla»): no hace falta un
/// servidor de vídeo y todo sigue cifrado de punta a punta (DTLS-SRTP). La
/// señalización viaja como mensajes cifrados de KLK por el grupo:
/// - gring: «llamada en el grupo» (a todos)
/// - gjoin: «me uno» (a todos; cada uno que ya está dentro me manda una oferta)
/// - goffer / ganswer / gice: solo entre dos personas (campo «to»)
/// - gleave: «me voy» (a todos)
class GroupCallController extends ChangeNotifier {
  GroupCallController._(this._ref);

  static GroupCallController? _instance;
  static GroupCallController? get instance => _instance;
  static GroupCallController ensure(Ref ref) => _instance ??= GroupCallController._(ref);

  static const maxPeople = 4;
  static const _uuid = Uuid();

  final Ref _ref;
  AppController get _app => _ref.read(appProvider);
  CallController get _single => _ref.read(callProvider);

  GroupPhase phase = GroupPhase.idle;
  String? groupId;
  String? callId;
  String? inviter; // quien empezó la llamada (si me llaman)
  bool video = false;
  bool muted = false;
  bool cameraOff = false;
  bool speaker = true;
  bool frontCamera = true;
  String status = '';
  DateTime? startedAt;
  bool _wasConnected = false;

  final peers = <String, GroupPeer>{};
  final localRenderer = RTCVideoRenderer();
  bool _localReady = false;
  MediaStream? _local;
  Timer? _ringTimeout;
  Timer? _aloneTimer;
  Timer? _tick;
  bool _screenOpen = false;
  Route<void>? _route;

  bool get busy => phase != GroupPhase.idle;
  Chat? get chat => groupId == null ? null : _app.chatById(groupId!);
  Duration get elapsed => startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);
  int get people => peers.values.where((p) => p.connected).length + 1;

  String nameOf(String id) {
    for (final m in chat?.members ?? const <GroupMember>[]) {
      if (m.id == id) return m.name.isNotEmpty ? m.name : m.phone;
    }
    return 'Alguien';
  }

  // ---------- Empezar / contestar ----------

  Future<void> start(String groupId, {required bool video}) async {
    if (busy || _single.busy) return;
    this.groupId = groupId;
    callId = _uuid.v4();
    this.video = video;
    speaker = true;
    inviter = null;
    phase = GroupPhase.active;
    status = 'Llamando al grupo…';
    notifyListeners();
    _openScreen();
    try {
      await _prepareMedia();
      await _send({'a': 'gring', 'v': video});
      // Si nadie se une en 60 s, se cuelga sola.
      _ringTimeout = Timer(const Duration(seconds: 60), () {
        if (peers.isEmpty) _finish('Nadie contestó');
      });
    } catch (e) {
      debugPrint('Llamada de grupo: $e');
      await _finish('No se pudo usar el micrófono o la cámara');
    }
  }

  Future<void> accept({bool withVideo = true}) async {
    if (phase != GroupPhase.incoming) return;
    _single.stopRingingExternal();
    _ringTimeout?.cancel();
    video = video && withVideo;
    phase = GroupPhase.active;
    status = 'Conectando…';
    notifyListeners();
    try {
      await _prepareMedia();
      await _send({'a': 'gjoin'});
      _aloneTimer = Timer(const Duration(seconds: 25), () {
        if (peers.values.every((p) => !p.connected)) _finish('No se pudo conectar');
      });
    } catch (e) {
      debugPrint('Unirse a llamada de grupo: $e');
      await _finish('No se pudo usar el micrófono o la cámara');
    }
  }

  Future<void> reject() async {
    if (phase != GroupPhase.incoming) return;
    await _finish('Llamada rechazada');
  }

  Future<void> hangUp() async {
    if (phase == GroupPhase.active) await _send({'a': 'gleave'});
    await _finish('Saliste de la llamada');
  }

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
    final t = _local?.getVideoTracks();
    if (t == null || t.isEmpty) return;
    await Helper.switchCamera(t.first);
    frontCamera = !frontCamera;
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
    notifyListeners();
  }

  /// Modo belleza (el mismo de las llamadas normales).
  Future<void> setBeauty(double level) async {
    await _single.setBeauty(level);
    await _applyBeauty();
    notifyListeners();
  }

  Future<void> _applyBeauty() async {
    if (!KlkNative.supportsBeauty) return;
    for (final t in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      if (t.id != null) await KlkNative.setBeauty(t.id!, _single.beauty);
    }
  }

  // ---------- Señales ----------

  Future<void> onSignal(String from, Map<String, dynamic> s) async {
    final a = s['a'] as String?;
    final id = s['id'] as String?;
    final gid = s['gid'] as String?;
    final to = s['to'] as String?;
    if (to != null && to != _app.myId) return;

    if (a == 'gring') {
      if (busy || _single.busy || gid == null) return;
      groupId = gid;
      callId = id;
      video = s['v'] == true;
      inviter = from;
      phase = GroupPhase.incoming;
      status = video ? 'Videollamada en el grupo' : 'Llamada en el grupo';
      notifyListeners();
      _single.startRingingExternal();
      _openScreen();
      _ringTimeout = Timer(const Duration(seconds: 45), () => _finish('Llamada perdida'));
      return;
    }

    if (id != callId || gid != groupId) return; // de otra llamada

    switch (a) {
      case 'gjoin':
        if (phase != GroupPhase.active || peers.containsKey(from)) return;
        if (peers.length + 1 >= maxPeople) {
          await _send({'a': 'gfull'}, to: from);
          return;
        }
        // Yo ya estaba dentro: le mando la oferta al que entra.
        final p = await _peer(from);
        final offer = await p.pc!.createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
        await p.pc!.setLocalDescription(offer);
        await _send({'a': 'goffer', 'sdp': offer.sdp}, to: from);
      case 'goffer':
        if (phase != GroupPhase.active) return;
        final p = await _peer(from);
        await p.pc!.setRemoteDescription(RTCSessionDescription(s['sdp'] as String, 'offer'));
        p.remoteSet = true;
        await _drain(p);
        final answer = await p.pc!.createAnswer({'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
        await p.pc!.setLocalDescription(answer);
        await _send({'a': 'ganswer', 'sdp': answer.sdp}, to: from);
      case 'ganswer':
        final p = peers[from];
        if (p?.pc == null) return;
        await p!.pc!.setRemoteDescription(RTCSessionDescription(s['sdp'] as String, 'answer'));
        p.remoteSet = true;
        await _drain(p);
      case 'gice':
        final p = peers[from];
        if (p == null) return;
        final c = RTCIceCandidate(s['c'] as String?, s['m'] as String?, (s['i'] as num?)?.toInt());
        if (p.pc != null && p.remoteSet) {
          await p.pc!.addCandidate(c);
        } else {
          p.pendingIce.add(c);
        }
      case 'gleave':
        await _removePeer(from);
        if (phase == GroupPhase.incoming && from == inviter) {
          // Quien llamó colgó antes de que yo contestara.
          await _finish('Llamada perdida');
        }
      case 'gfull':
        await _finish('La llamada ya está llena (máximo $maxPeople personas)');
    }
  }

  // ---------- Internos ----------

  Future<void> _send(Map<String, dynamic> s, {String? to}) async {
    final g = groupId;
    if (g == null) return;
    try {
      await _app.sendGroupCallSignal(g, {...s, 'id': callId, 'gid': g, if (to != null) 'to': to}, to: to);
    } catch (e) {
      debugPrint('Señal de grupo: $e');
    }
  }

  Future<void> _prepareMedia() async {
    if (!_localReady) {
      await localRenderer.initialize();
      _localReady = true;
    }
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': video ? cameraConstraints(group: true) : false,
    });
    localRenderer.srcObject = _local;
    if (video && _single.beauty > 0) await _applyBeauty();
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
    notifyListeners();
  }

  Future<Map<String, dynamic>> _rtcConfig() async {
    var servers = <Map<String, dynamic>>[];
    try {
      servers = [...await _app.callServers().timeout(const Duration(seconds: 4))];
    } catch (_) {}
    if (servers.isEmpty) {
      servers.add({
        'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
      });
    }
    if (KlkConfig.turnUrl.isNotEmpty) {
      servers.add({'urls': KlkConfig.turnUrl, 'username': KlkConfig.turnUser, 'credential': KlkConfig.turnPass});
    }
    return {'iceServers': servers, 'sdpSemantics': 'unified-plan', 'iceCandidatePoolSize': 1};
  }

  Future<GroupPeer> _peer(String id) async {
    final existing = peers[id];
    if (existing?.pc != null) return existing!;
    final p = existing ?? GroupPeer(id, nameOf(id));
    peers[id] = p;
    if (!p.rendererReady) {
      await p.renderer.initialize();
      p.rendererReady = true;
    }
    final pc = await createPeerConnection(await _rtcConfig());
    p.pc = pc;
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      await pc.addTrack(t, _local!);
    }
    if (video) await preferH264(pc);
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _send({'a': 'gice', 'c': c.candidate, 'm': c.sdpMid, 'i': c.sdpMLineIndex}, to: id);
    };
    pc.onTrack = (e) {
      if (e.streams.isEmpty) return;
      p.renderer.srcObject = e.streams.first;
      if (e.track.kind == 'video') p.hasVideo = true;
      notifyListeners();
    };
    pc.onConnectionState = (st) {
      if (st == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (video && !p.connected) unawaited(boostVideoBitrate(pc, group: true));
        p.connected = true;
        _ringTimeout?.cancel();
        _aloneTimer?.cancel();
        if (startedAt == null) {
          startedAt = DateTime.now();
          _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
        }
        _wasConnected = true;
        status = '';
        notifyListeners();
      } else if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          st == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _removePeer(id);
      }
    };
    notifyListeners();
    return p;
  }

  Future<void> _drain(GroupPeer p) async {
    for (final c in List.of(p.pendingIce)) {
      await p.pc?.addCandidate(c);
    }
    p.pendingIce.clear();
  }

  Future<void> _removePeer(String id) async {
    final p = peers.remove(id);
    if (p == null) return;
    await p.pc?.close();
    p.renderer.srcObject = null;
    if (p.rendererReady) await p.renderer.dispose();
    notifyListeners();
    // Me quedé solo después de hablar con alguien: se cuelga en 15 s si nadie vuelve.
    if (phase == GroupPhase.active && peers.isEmpty && _wasConnected) {
      status = 'Todos salieron de la llamada';
      notifyListeners();
      _aloneTimer?.cancel();
      _aloneTimer = Timer(const Duration(seconds: 15), () {
        if (peers.isEmpty) _finish('Llamada finalizada');
      });
    }
  }

  Future<void> _finish(String reason) async {
    if (phase == GroupPhase.idle || phase == GroupPhase.ended) return;
    final wasIncoming = inviter != null;
    final missed = phase == GroupPhase.incoming;
    final talked = startedAt == null ? null : elapsed;
    final g = groupId;
    phase = GroupPhase.ended;
    status = reason;
    notifyListeners();
    _single.stopRingingExternal();
    _ringTimeout?.cancel();
    _aloneTimer?.cancel();
    _tick?.cancel();
    for (final id in List.of(peers.keys)) {
      await _removePeer(id);
    }
    for (final t in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      if (KlkNative.supportsBeauty && t.id != null) await KlkNative.removeBeauty(t.id!);
    }
    for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _local?.dispose();
    _local = null;
    localRenderer.srcObject = null;

    if (g != null) {
      final kind = video ? 'Videollamada de grupo' : 'Llamada de grupo';
      final text = talked != null
          ? '👥 $kind · ${formatDuration(talked.inMilliseconds)}'
          : missed
              ? '📵 $kind perdida'
              : '📵 $kind · $reason';
      try {
        await _app.logCall(g, text,
            incoming: wasIncoming, video: video, missed: talked == null, durationMs: talked?.inMilliseconds ?? 0);
      } catch (_) {}
    }

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    phase = GroupPhase.idle;
    groupId = null;
    callId = null;
    inviter = null;
    startedAt = null;
    _wasConnected = false;
    muted = false;
    cameraOff = false;
    status = '';
    _closeScreen();
    notifyListeners();
  }

  void _openScreen() {
    if (_screenOpen) return;
    final nav = _ref.read(navigatorKeyProvider).currentState;
    if (nav == null) return;
    _screenOpen = true;
    final route = MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const GroupCallScreen());
    _route = route;
    nav.push(route).then((_) {
      if (_route == route) _route = null;
      _screenOpen = false;
    });
  }

  void _closeScreen() {
    final route = _route;
    if (!_screenOpen || route == null) return;
    final nav = _ref.read(navigatorKeyProvider).currentState;
    if (route.isActive) nav?.removeRoute(route);
    _route = null;
    _screenOpen = false;
  }
}
