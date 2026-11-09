import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Calidad de vídeo de las llamadas.
///
/// Por defecto WebRTC pide la cámara a 640×480, usa VP8 (por software en el
/// iPhone) y empieza con muy pocos kbps, así que la videollamada se veía borrosa
/// aunque el móvil sea bueno. Aquí pedimos HD, preferimos H.264 (lo codifica el
/// chip del iPhone: mucha más calidad con la misma conexión) y subimos el tope
/// de kbps. Si la conexión es mala, WebRTC baja la calidad solo.

/// Cámara para videollamadas: 720p a 30 fps (en grupo, algo menos por persona).
Map<String, dynamic> cameraConstraints({bool group = false, bool front = true}) => {
      'facingMode': front ? 'user' : 'environment',
      'width': group ? 960 : 1280,
      'height': group ? 540 : 720,
      'frameRate': 30,
    };

/// Antes de crear la oferta o la respuesta: H.264 primero.
Future<void> preferH264(RTCPeerConnection pc) async {
  try {
    final caps = await getRtpSenderCapabilities('video');
    final codecs = caps.codecs ?? const <RTCRtpCodecCapability>[];
    bool isH264(RTCRtpCodecCapability c) => c.mimeType.toLowerCase() == 'video/h264';
    final h264 = codecs.where(isH264).toList();
    if (h264.isEmpty) return;
    // Primero el perfil «high» (mejor calidad), luego el resto de H.264 y después los demás.
    h264.sort((a, b) {
      final ah = (a.sdpFmtpLine ?? '').contains('profile-level-id=64') ? 0 : 1;
      final bh = (b.sdpFmtpLine ?? '').contains('profile-level-id=64') ? 0 : 1;
      return ah - bh;
    });
    final ordered = [...h264, ...codecs.where((c) => !isH264(c))];
    for (final t in await pc.getTransceivers()) {
      if (t.sender.track?.kind == 'video' || t.receiver.track?.kind == 'video') {
        await t.setCodecPreferences(ordered);
      }
    }
  } catch (e) {
    debugPrint('Códec de vídeo: $e');
  }
}

/// Cuando la llamada ya conectó: más kbps para el vídeo (2,5 Mbps; 1,2 en grupo).
Future<void> boostVideoBitrate(RTCPeerConnection pc, {bool group = false}) async {
  final max = group ? 1200000 : 2500000;
  try {
    for (final s in await pc.getSenders()) {
      if (s.track?.kind != 'video') continue;
      final p = s.parameters;
      final enc = p.encodings;
      if (enc == null || enc.isEmpty) {
        p.encodings = [RTCRtpEncoding(maxBitrate: max, maxFramerate: 30, scaleResolutionDownBy: 1.0)];
      } else {
        for (final e in enc) {
          e.maxBitrate = max;
          e.maxFramerate = 30;
          e.scaleResolutionDownBy = 1.0;
        }
      }
      // Si la conexión va justa, baja un poco de todo en vez de congelar la imagen.
      p.degradationPreference = RTCDegradationPreference.BALANCED;
      await s.setParameters(p);
    }
  } catch (e) {
    debugPrint('Calidad de vídeo: $e');
  }
}
