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

  const PrivacySettings({
    this.lastSeen = Audience.contactos,
    this.hideReadReceipts = false,
    this.hideTyping = false,
    this.hideRecording = false,
    this.allowStorySaving = false,
    this.appLock = false,
  });

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
  }) =>
      PrivacySettings(
        lastSeen: lastSeen ?? this.lastSeen,
        hideReadReceipts: hideReadReceipts ?? this.hideReadReceipts,
        hideTyping: hideTyping ?? this.hideTyping,
        hideRecording: hideRecording ?? this.hideRecording,
        allowStorySaving: allowStorySaving ?? this.allowStorySaving,
        appLock: appLock ?? this.appLock,
      );

  Map<String, dynamic> toJson() => {
        'lastSeen': lastSeen.name,
        'hideReadReceipts': hideReadReceipts,
        'hideTyping': hideTyping,
        'hideRecording': hideRecording,
        'allowStorySaving': allowStorySaving,
        'appLock': appLock,
      };

  factory PrivacySettings.fromJson(Map<String, dynamic> j) => PrivacySettings(
        lastSeen: Audience.values.byName(j['lastSeen'] as String? ?? 'contactos'),
        hideReadReceipts: j['hideReadReceipts'] as bool? ?? false,
        hideTyping: j['hideTyping'] as bool? ?? false,
        hideRecording: j['hideRecording'] as bool? ?? false,
        allowStorySaving: j['allowStorySaving'] as bool? ?? false,
        appLock: j['appLock'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());
  factory PrivacySettings.decode(String s) =>
      PrivacySettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
