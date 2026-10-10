import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Quién puede ver un dato de presencia.
enum Audience { todos, contactos, nadie }

@immutable
class PrivacySettings {
  final Audience lastSeen;
  final bool hideReadReceipts; // doble check azul
  final bool hideTyping; // "escribiendo..."
  final bool hideRecording; // "grabando audio..."
  final bool allowStorySaving; // ¿otros pueden guardar mis estados?
  final bool appLock; // bloqueo con PIN / biometría
  final bool hideOnline; // no mostrar "en línea" aunque tenga KLK abierto
  final bool hideDelivered; // no enviar el segundo check gris (entregado)
  final DateTime? frozenLastSeen; // última conexión congelada (null = no congelada)
  final bool confirmCalls; // preguntar antes de llamar

  const PrivacySettings({
    this.lastSeen = Audience.contactos,
    this.hideReadReceipts = false,
    this.hideTyping = false,
    this.hideRecording = false,
    this.allowStorySaving = false,
    this.appLock = false,
    this.hideOnline = false,
    this.hideDelivered = false,
    this.frozenLastSeen,
    this.confirmCalls = true,
  });

  bool get lastSeenFrozen => frozenLastSeen != null;

  /// Reciprocidad: si ocultas tus confirmaciones de lectura,
  /// tampoco ves las de los demás. Justo para todos.
  bool get canSeeOthersReadReceipts => !hideReadReceipts;
  bool get canSeeOthersLastSeen => lastSeen != Audience.nadie;

  PrivacySettings copyWith({
    Audience? lastSeen,
    bool? hideReadReceipts,
    bool? hideTyping,
    bool? hideRecording,
    bool? allowStorySaving,
    bool? appLock,
    bool? hideOnline,
    bool? hideDelivered,
    DateTime? frozenLastSeen,
    bool unfreeze = false,
    bool? confirmCalls,
  }) =>
      PrivacySettings(
        lastSeen: lastSeen ?? this.lastSeen,
        hideReadReceipts: hideReadReceipts ?? this.hideReadReceipts,
        hideTyping: hideTyping ?? this.hideTyping,
        hideRecording: hideRecording ?? this.hideRecording,
        allowStorySaving: allowStorySaving ?? this.allowStorySaving,
        appLock: appLock ?? this.appLock,
        hideOnline: hideOnline ?? this.hideOnline,
        hideDelivered: hideDelivered ?? this.hideDelivered,
        frozenLastSeen: unfreeze ? null : (frozenLastSeen ?? this.frozenLastSeen),
        confirmCalls: confirmCalls ?? this.confirmCalls,
      );

  Map<String, dynamic> toJson() => {
        'lastSeen': lastSeen.name,
        'hideReadReceipts': hideReadReceipts,
        'hideTyping': hideTyping,
        'hideRecording': hideRecording,
        'allowStorySaving': allowStorySaving,
        'appLock': appLock,
        'hideOnline': hideOnline,
        'hideDelivered': hideDelivered,
        if (frozenLastSeen != null) 'frozenLastSeen': frozenLastSeen!.toIso8601String(),
        'confirmCalls': confirmCalls,
      };

  factory PrivacySettings.fromJson(Map<String, dynamic> j) => PrivacySettings(
        lastSeen: Audience.values.byName(j['lastSeen'] as String? ?? 'contactos'),
        hideReadReceipts: j['hideReadReceipts'] as bool? ?? false,
        hideTyping: j['hideTyping'] as bool? ?? false,
        hideRecording: j['hideRecording'] as bool? ?? false,
        allowStorySaving: j['allowStorySaving'] as bool? ?? false,
        appLock: j['appLock'] as bool? ?? false,
        hideOnline: j['hideOnline'] as bool? ?? false,
        hideDelivered: j['hideDelivered'] as bool? ?? false,
        frozenLastSeen: DateTime.tryParse(j['frozenLastSeen'] as String? ?? ''),
        confirmCalls: j['confirmCalls'] as bool? ?? true,
      );

  String encode() => jsonEncode(toJson());
  factory PrivacySettings.decode(String s) =>
      PrivacySettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
