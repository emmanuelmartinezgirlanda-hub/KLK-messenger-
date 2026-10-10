import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/privacy/domain/privacy_settings.dart';
import '../../features/privacy/presentation/privacy_provider.dart';

/// Toda emisión de eventos de presencia pasa por aquí.
/// La privacidad se aplica en la capa de red: si un ajuste está activo,
/// el evento NUNCA sale del dispositivo.
final presenceGateProvider =
    Provider<PresenceGate>((ref) => PresenceGate(ref.watch(privacyProvider)));

class PresenceGate {
  final PrivacySettings s;
  const PresenceGate(this.s);

  bool canSendReadReceipt() => !s.hideReadReceipts;
  bool canSendTyping() => !s.hideTyping;
  bool canSendRecording() => !s.hideRecording;
  bool canSendDelivered() => !s.hideDelivered;

  bool canShareLastSeenWith({required bool isContact}) => switch (s.lastSeen) {
        Audience.todos => true,
        Audience.contactos => isContact,
        Audience.nadie => false,
      };
}

/// Ejemplo de uso en el cliente de mensajería:
///
///   void onMessageOpened(Message m) {
///     final gate = ref.read(presenceGateProvider);
///     if (gate.canSendReadReceipt()) socket.send(ReadReceipt(m.id));
///   }
