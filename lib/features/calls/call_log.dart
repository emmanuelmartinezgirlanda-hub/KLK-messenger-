/// Una llamada del historial (pestaña «Llamadas»). Solo se guarda en este móvil.
class CallRecord {
  final String id;
  final String chatId;
  final DateTime at;
  final bool video;
  final bool incoming;
  final bool missed;
  final int durationMs; // 0 si no se llegó a hablar

  const CallRecord({
    required this.id,
    required this.chatId,
    required this.at,
    required this.video,
    required this.incoming,
    required this.missed,
    this.durationMs = 0,
  });

  /// Perdida de verdad: me llamaron y no contesté.
  bool get missedIncoming => missed && incoming;

  Map<String, dynamic> toJson() => {
        'i': id,
        'c': chatId,
        't': at.millisecondsSinceEpoch,
        if (video) 'v': true,
        if (incoming) 'in': true,
        if (missed) 'm': true,
        if (durationMs > 0) 'd': durationMs,
      };

  static CallRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['i'];
    final chatId = raw['c'];
    final t = raw['t'];
    if (id is! String || chatId is! String || t is! num) return null;
    return CallRecord(
      id: id,
      chatId: chatId,
      at: DateTime.fromMillisecondsSinceEpoch(t.toInt()),
      video: raw['v'] == true,
      incoming: raw['in'] == true,
      missed: raw['m'] == true,
      durationMs: (raw['d'] as num?)?.toInt() ?? 0,
    );
  }
}
