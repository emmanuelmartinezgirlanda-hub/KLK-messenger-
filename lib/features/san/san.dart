import 'package:intl/intl.dart';

/// Un número del san: quién lo tiene (una persona puede tener varios).
class SanSlot {
  final String id; // accountId de la persona
  final String name;
  const SanSlot(this.id, this.name);

  Map<String, dynamic> toJson() => {'id': id, 'n': name};
  factory SanSlot.fromJson(Map<String, dynamic> j) => SanSlot(j['id'] as String? ?? '', j['n'] as String? ?? '');
}

/// Estado de un pago: el organizador lo confirma; la persona puede avisar "ya pagué".
enum SanPay { none, claimed, paid }

/// El San: ahorro en grupo a la dominicana. KLK solo lleva la cuenta: el dinero
/// lo mueven ellos como siempre. Viaja dentro de un mensaje cifrado del grupo y
/// los cambios (pagos) llegan como pequeños avisos cifrados que cada móvil aplica.
class San {
  final String name;
  final double amount; // lo que pone cada número en cada vuelta
  final String currency; // "RD$", "US$", "€", "£"
  final String period; // week | 2week | month
  final DateTime start; // día del primer turno
  final String organizer; // accountId de quien lo organiza
  final List<SanSlot> slots; // orden de los turnos (sorteado)
  final Map<String, SanPay> pays; // "turno:número" -> estado
  final bool ended; // el organizador lo dio por terminado
  /// Entrega del dinero de cada turno: "sent" (el organizador lo envió) o
  /// "got" (quien cobra confirmó que le llegó).
  final Map<int, String> outs;

  const San({
    required this.name,
    required this.amount,
    required this.currency,
    required this.period,
    required this.start,
    required this.organizer,
    required this.slots,
    this.pays = const {},
    this.ended = false,
    this.outs = const {},
  });

  int get rounds => slots.length;
  double get pot => amount * slots.length; // lo que se lleva a quien le toca

  /// Fecha del turno [r] (0 = el primero).
  DateTime dateOf(int r) => switch (period) {
        'week' => DateTime(start.year, start.month, start.day + 7 * r),
        '2week' => DateTime(start.year, start.month, start.day + 14 * r),
        _ => _addMonths(start, r),
      };

  static DateTime _addMonths(DateTime d, int n) {
    final y = d.year + (d.month - 1 + n) ~/ 12;
    final m = (d.month - 1 + n) % 12 + 1;
    final last = DateTime(y, m + 1, 0).day;
    return DateTime(y, m, d.day > last ? last : d.day);
  }

  /// Turno en curso: el último cuya fecha ya llegó (o el primero si aún no empezó).
  /// Si todos los turnos ya pasaron, devuelve el último.
  int currentRound(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    var r = 0;
    for (var i = 0; i < rounds; i++) {
      if (!dateOf(i).isAfter(today)) r = i;
    }
    return r;
  }

  bool started(DateTime now) => !dateOf(0).isAfter(DateTime(now.year, now.month, now.day));

  SanPay payOf(int round, int slot) => pays['$round:$slot'] ?? SanPay.none;

  int paidCount(int round) => [for (var s = 0; s < slots.length; s++) payOf(round, s)].where((p) => p == SanPay.paid).length;

  bool roundComplete(int round) => paidCount(round) == slots.length;

  /// ¿Se envió ya el dinero del turno [round]? null, "sent" o "got".
  String? outOf(int round) => outs[round];

  /// ¿Ya se terminó? (lo terminaron o el último turno está cobrado del todo).
  bool finished(DateTime now) => ended || (roundComplete(rounds - 1) && currentRound(now) == rounds - 1);

  /// Mis números (posiciones en el orden).
  List<int> slotsOf(String accountId) => [for (var i = 0; i < slots.length; i++) if (slots[i].id == accountId) i];

  /// Fecha de fin (el último turno).
  DateTime get endDate => dateOf(rounds - 1);

  String money(double v) => formatSanMoney(v, currency);

  String get periodLabel => switch (period) { 'week' => 'cada semana', '2week' => 'cada quincena', _ => 'cada mes' };
  String get periodShort => switch (period) { 'week' => 'semanal', '2week' => 'quincenal', _ => 'mensual' };

  San copyWith({Map<String, SanPay>? pays, bool? ended, Map<int, String>? outs}) => San(
        name: name,
        amount: amount,
        currency: currency,
        period: period,
        start: start,
        organizer: organizer,
        slots: slots,
        pays: pays ?? this.pays,
        ended: ended ?? this.ended,
        outs: outs ?? this.outs,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'n': name,
        'a': amount,
        'c': currency,
        'p': period,
        's': DateFormat('yyyy-MM-dd').format(start),
        'o': organizer,
        'sl': [for (final s in slots) s.toJson()],
        if (pays.isNotEmpty) 'py': {for (final e in pays.entries) if (e.value != SanPay.none) e.key: e.value.name},
        if (ended) 'e': true,
        if (outs.isNotEmpty) 'out': {for (final e in outs.entries) '${e.key}': e.value},
      };

  static San? tryParse(Object? raw) {
    if (raw is! Map) return null;
    try {
      final j = raw.cast<String, dynamic>();
      final slots = [for (final s in (j['sl'] as List? ?? const [])) SanSlot.fromJson((s as Map).cast<String, dynamic>())];
      if (slots.isEmpty || slots.length > 60) return null;
      final start = DateTime.tryParse(j['s'] as String? ?? '');
      if (start == null) return null;
      final pays = <String, SanPay>{};
      for (final e in ((j['py'] as Map?) ?? const {}).entries) {
        final v = SanPay.values.asNameMap()[e.value];
        if (v != null && v != SanPay.none) pays[e.key as String] = v;
      }
      final outs = <int, String>{};
      for (final e in ((j['out'] as Map?) ?? const {}).entries) {
        final r = int.tryParse('${e.key}');
        if (r != null && r >= 0 && r < slots.length && (e.value == 'sent' || e.value == 'got')) outs[r] = e.value as String;
      }
      return San(
        name: (j['n'] as String? ?? 'San').trim(),
        amount: (j['a'] as num?)?.toDouble() ?? 0,
        currency: j['c'] as String? ?? 'RD\$',
        period: const ['week', '2week', 'month'].contains(j['p']) ? j['p'] as String : 'month',
        start: DateTime(start.year, start.month, start.day),
        organizer: j['o'] as String? ?? '',
        slots: slots,
        pays: pays,
        ended: j['e'] == true,
        outs: outs,
      );
    } catch (_) {
      return null;
    }
  }

  /// Aplica un cambio que llega de alguien del grupo. Reglas:
  /// - Confirmar o quitar un pago: solo el organizador.
  /// - Avisar "ya pagué": la persona de ese número (o el organizador).
  /// - Terminar el san: solo el organizador.
  /// Devuelve el san nuevo, o null si el cambio no vale.
  San? apply(Map<String, dynamic> ev, String from) {
    final organizerSays = from == organizer;
    switch (ev['a']) {
      case 'pay':
        final r = (ev['r'] as num?)?.toInt() ?? -1;
        final s = (ev['s'] as num?)?.toInt() ?? -1;
        if (r < 0 || r >= rounds || s < 0 || s >= slots.length) return null;
        final v = SanPay.values.asNameMap()[ev['v']] ?? SanPay.none;
        final cur = payOf(r, s);
        if (v == SanPay.claimed) {
          if (!organizerSays && slots[s].id != from) return null;
          if (cur == SanPay.paid) return null; // ya estaba confirmado
        } else if (!organizerSays) {
          // Quien avisó puede retirar su aviso, nada más.
          if (!(v == SanPay.none && cur == SanPay.claimed && slots[s].id == from)) return null;
        }
        final next = Map<String, SanPay>.from(pays);
        if (v == SanPay.none) {
          next.remove('$r:$s');
        } else {
          next['$r:$s'] = v;
        }
        return copyWith(pays: next);
      case 'end':
        return organizerSays ? copyWith(ended: true) : null;
      case 'sent': // el organizador envió el dinero del turno
      case 'unsent': // …o lo desmarca (se equivocó)
      case 'got': // quien cobra confirma que le llegó
        final r = (ev['r'] as num?)?.toInt() ?? -1;
        if (r < 0 || r >= rounds) return null;
        final next = Map<int, String>.from(outs);
        if (ev['a'] == 'got') {
          if (slots[r].id != from && !organizerSays) return null;
          if (outs[r] == null) return null;
          next[r] = 'got';
        } else {
          if (!organizerSays) return null;
          if (ev['a'] == 'sent') {
            if (outs[r] == 'got') return null;
            next[r] = 'sent';
          } else {
            if (outs[r] != 'sent') return null;
            next.remove(r);
          }
        }
        return copyWith(outs: next);
    }
    return null;
  }
}

String formatSanMoney(double v, String currency) {
  final n = NumberFormat.decimalPatternDigits(locale: 'es', decimalDigits: v == v.roundToDouble() ? 0 : 2).format(v);
  return switch (currency) {
    '€' => '$n €',
    '£' => '£$n',
    _ => '$currency $n',
  };
}

/// Fecha corta y clara: "vie 24 oct".
String sanDate(DateTime d, String lang) => DateFormat('EEE d MMM', lang).format(d);

/// Datos para cobrar el san. Los pone cada persona y solo se mandan (cifrados)
/// a quien organiza. Nunca viajan dentro del san del grupo.
class SanBank {
  final String holder; // titular
  final String account; // IBAN o número de cuenta
  final String bank; // nombre del banco (opcional)
  final String note; // otra forma: Bizum, Zelle, PayPal… (opcional)
  final DateTime at;

  const SanBank({required this.holder, required this.account, this.bank = '', this.note = '', required this.at});

  bool get isEmpty => account.trim().isEmpty && note.trim().isEmpty;

  /// La cuenta medio tapada: "IE12 •••• 4567".
  String get masked {
    final a = account.replaceAll(' ', '');
    if (a.length <= 8) return a;
    return '${a.substring(0, 4)} •••• ${a.substring(a.length - 4)}';
  }

  /// Misma cuenta (sin mirar espacios ni mayúsculas).
  bool sameAccount(SanBank o) =>
      account.replaceAll(' ', '').toUpperCase() == o.account.replaceAll(' ', '').toUpperCase() &&
      note.trim() == o.note.trim();

  Map<String, dynamic> toJson() => {
        'h': holder,
        'acc': account,
        if (bank.isNotEmpty) 'b': bank,
        if (note.isNotEmpty) 'nt': note,
        't': at.millisecondsSinceEpoch,
      };

  static SanBank? tryParse(Object? raw) {
    if (raw is! Map) return null;
    String str(Object? v, int max) => v is String ? (v.length > max ? v.substring(0, max) : v).trim() : '';
    final b = SanBank(
      holder: str(raw['h'], 80),
      account: str(raw['acc'], 60),
      bank: str(raw['b'], 60),
      note: str(raw['nt'], 120),
      at: DateTime.fromMillisecondsSinceEpoch((raw['t'] as num?)?.toInt() ?? 0),
    );
    return b.isEmpty ? null : b;
  }
}
