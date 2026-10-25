import 'package:intl/intl.dart';

/// KLK Business: perfiles de negocio, pedidos y citas.
///
/// Apagado en la App Store hasta que esté probado: se enciende con
/// `--dart-define=KLK_BUSINESS=true` (TestFlight lo lleva encendido).
const bool kBusinessFeatures = bool.fromEnvironment('KLK_BUSINESS', defaultValue: false);

/// Tipo de negocio. El nombre (`colmado`, `peluqueria`…) es el que guarda el servidor.
enum BizKind {
  colmado('Colmado', '🏪', 'Productos'),
  peluqueria('Peluquería / barbería', '💈', 'Servicios'),
  belleza('Uñas y belleza', '💅', 'Servicios'),
  comida('Comida', '🍽️', 'Menú'),
  tienda('Tienda', '🛍️', 'Productos'),
  servicios('Servicios / taller', '🔧', 'Servicios'),
  otro('Otro negocio', '⭐', 'Catálogo');

  const BizKind(this.label, this.emoji, this.catalogLabel);
  final String label;
  final String emoji;
  final String catalogLabel;

  /// Los negocios de citas reservan hora; los demás reciben pedidos.
  bool get usesBookings => this == peluqueria || this == belleza || this == servicios;

  static BizKind parse(String? s) => BizKind.values.asNameMap()[s] ?? BizKind.otro;
}

const bizCurrencies = ['RD\$', 'US\$', '€', '£'];

String bizMoney(double v, String cur) {
  final f = NumberFormat.decimalPattern('es');
  f.maximumFractionDigits = v == v.roundToDouble() ? 0 : 2;
  return '$cur ${f.format(v)}';
}

String _s(Object? v, int max) {
  final t = (v is String ? v : '').trim();
  return t.length > max ? t.substring(0, max) : t;
}

double? _price(Object? v) {
  final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}'.replaceAll(',', '.'));
  if (d == null || d.isNaN || d < 0 || d > 1e7) return null;
  return d;
}

final _imageIdRe = RegExp(r'^[0-9a-fA-F-]{36}$');

/// Id de una foto del negocio (logo o producto) o '' si no vale.
String bizImageId(Object? v) {
  final t = v is String ? v.trim() : '';
  return _imageIdRe.hasMatch(t) ? t : '';
}

/// Un producto o servicio del catálogo.
class BizItem {
  final String id;
  final String name;
  final double? price; // null = "consultar"
  final String desc;
  final String cat; // categoría (Despensa, Bebidas…)
  final int? minutes; // servicios: cuánto dura
  final String img; // id de la foto en el servidor ('' = sin foto)

  const BizItem(
      {required this.id, required this.name, this.price, this.desc = '', this.cat = '', this.minutes, this.img = ''});

  Map<String, dynamic> toJson() => {
        'id': id,
        'n': name,
        if (price != null) 'p': price,
        if (desc.isNotEmpty) 'd': desc,
        if (cat.isNotEmpty) 'c': cat,
        if (minutes != null) 'm': minutes,
        if (img.isNotEmpty) 'img': img,
      };

  static BizItem? tryParse(Object? j) {
    if (j is! Map) return null;
    final name = _s(j['n'], 60);
    final id = _s(j['id'], 40);
    if (name.isEmpty || id.isEmpty) return null;
    final m = (j['m'] as num?)?.toInt();
    return BizItem(
      id: id,
      name: name,
      price: _price(j['p']),
      desc: _s(j['d'], 200),
      cat: _s(j['c'], 30),
      minutes: m == null || m < 5 || m > 600 ? null : m,
      img: bizImageId(j['img']),
    );
  }

  BizItem copyWith(
          {String? name, double? price, bool clearPrice = false, String? desc, String? cat, int? minutes, String? img}) =>
      BizItem(
        id: id,
        name: name ?? this.name,
        price: clearPrice ? null : (price ?? this.price),
        desc: desc ?? this.desc,
        cat: cat ?? this.cat,
        minutes: minutes ?? this.minutes,
        img: img ?? this.img,
      );
}

/// Perfil público de un negocio. Lo publica el dueño; cualquiera lo puede ver.
class BizProfile {
  final String id; // accountId del negocio
  final String name;
  final BizKind kind;
  final String country; // "DO", "ES"…
  final String city;
  final bool verified;

  // Lo demás va en `data`:
  final String about;
  final String address;
  final String delivery; // "Delivery: 50 pesos" ('' = sin delivery)
  final String currency;
  final int openHour; // 0..23
  final int closeHour; // 1..24
  final List<int> days; // días abiertos (1 = lunes … 7 = domingo)
  final int slotMin; // citas: cada cuántos minutos
  final List<String> staff; // citas: quién atiende ("Juan", "Miguel")
  final List<String> quick; // respuestas rápidas
  final List<BizItem> items;
  final String logo; // id de la foto del logo ('' = se ven las iniciales)

  const BizProfile({
    required this.id,
    required this.name,
    required this.kind,
    this.country = '',
    this.city = '',
    this.verified = false,
    this.about = '',
    this.address = '',
    this.delivery = '',
    this.currency = 'RD\$',
    this.openHour = 8,
    this.closeHour = 20,
    this.days = const [1, 2, 3, 4, 5, 6],
    this.slotMin = 30,
    this.staff = const [],
    this.quick = const [],
    this.items = const [],
    this.logo = '',
  });

  static const maxItems = 200;

  Map<String, dynamic> dataJson() => {
        if (about.isNotEmpty) 'about': about,
        if (address.isNotEmpty) 'addr': address,
        if (delivery.isNotEmpty) 'dlv': delivery,
        'cur': currency,
        'open': openHour,
        'close': closeHour,
        'days': days,
        'slot': slotMin,
        if (staff.isNotEmpty) 'staff': staff,
        if (quick.isNotEmpty) 'quick': quick,
        if (logo.isNotEmpty) 'logo': logo,
        'items': [for (final i in items.take(maxItems)) i.toJson()],
      };

  /// Lo que se manda al servidor (PUT /v1/business/me).
  Map<String, dynamic> toRequest() =>
      {'name': name, 'kind': kind.name, 'country': country, 'city': city, 'data': dataJson()};

  Map<String, dynamic> toJson() => {...toRequest(), 'id': id, 'verified': verified};

  static List<String> _strings(Object? v, int maxLen, int maxCount) => [
        if (v is List)
          for (final x in v.take(maxCount))
            if (_s(x, maxLen).isNotEmpty) _s(x, maxLen)
      ];

  static BizProfile? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id'], 64);
    final name = _s(j['name'], 60);
    if (name.isEmpty) return null;
    final d = j['data'] is Map ? j['data'] as Map : const {};
    int hour(Object? v, int def, int min, int max) {
      final h = (v as num?)?.toInt() ?? def;
      return h < min || h > max ? def : h;
    }

    final open = hour(d['open'], 8, 0, 23);
    var close = hour(d['close'], 20, 1, 24);
    if (close <= open) close = (open + 1).clamp(1, 24);
    final days = <int>[
      if (d['days'] is List)
        for (final x in (d['days'] as List))
          if (x is num && x >= 1 && x <= 7) x.toInt()
    ];
    final slot = hour(d['slot'], 30, 10, 240);
    final cur = _s(d['cur'], 4);
    return BizProfile(
      id: id,
      name: name,
      kind: BizKind.parse(j['kind'] as String?),
      country: _s(j['country'], 2),
      city: _s(j['city'], 60),
      verified: j['verified'] == true,
      about: _s(d['about'], 300),
      address: _s(d['addr'], 120),
      delivery: _s(d['dlv'], 80),
      currency: bizCurrencies.contains(cur) ? cur : 'RD\$',
      openHour: open,
      closeHour: close,
      days: days.isEmpty ? const [1, 2, 3, 4, 5, 6] : (days.toSet().toList()..sort()),
      slotMin: slot,
      staff: _strings(d['staff'], 30, 10),
      quick: _strings(d['quick'], 120, 12),
      items: [
        if (d['items'] is List)
          for (final x in (d['items'] as List).take(maxItems))
            if (BizItem.tryParse(x) != null) BizItem.tryParse(x)!
      ],
      logo: bizImageId(d['logo']),
    );
  }

  BizProfile copyWith({
    String? name,
    BizKind? kind,
    String? country,
    String? city,
    String? about,
    String? address,
    String? delivery,
    String? currency,
    int? openHour,
    int? closeHour,
    List<int>? days,
    int? slotMin,
    List<String>? staff,
    List<String>? quick,
    List<BizItem>? items,
    String? logo,
  }) =>
      BizProfile(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        country: country ?? this.country,
        city: city ?? this.city,
        verified: verified,
        about: about ?? this.about,
        address: address ?? this.address,
        delivery: delivery ?? this.delivery,
        currency: currency ?? this.currency,
        openHour: openHour ?? this.openHour,
        closeHour: closeHour ?? this.closeHour,
        days: days ?? this.days,
        slotMin: slotMin ?? this.slotMin,
        staff: staff ?? this.staff,
        quick: quick ?? this.quick,
        items: items ?? this.items,
        logo: logo ?? this.logo,
      );

  String get initials {
    final w = name.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
    if (w.isEmpty) return '?';
    return (w.length == 1 ? w.first.substring(0, w.first.length.clamp(1, 2)) : '${w[0][0]}${w[1][0]}').toUpperCase();
  }

  String get hoursLabel {
    String h(int x) => x == 24 ? '12:00 a. m.' : DateFormat('h:mm a', 'es').format(DateTime(2000, 1, 1, x));
    return '${daysLabel(days)} · ${h(openHour)} – ${h(closeHour)}';
  }

  bool openAt(DateTime t) => days.contains(t.weekday) && t.hour >= openHour && t.hour < closeHour;

  /// Horas libres para una cita de [minutes] el día [day] (sin contar las ocupadas).
  List<DateTime> slotsFor(DateTime day, int minutes, {DateTime? now, Set<DateTime> taken = const {}}) {
    if (!days.contains(day.weekday)) return const [];
    final out = <DateTime>[];
    final start = DateTime(day.year, day.month, day.day, openHour);
    final end = DateTime(day.year, day.month, day.day).add(Duration(hours: closeHour));
    final n = now ?? DateTime.now();
    for (var t = start; !t.add(Duration(minutes: minutes)).isAfter(end); t = t.add(Duration(minutes: slotMin))) {
      if (t.isAfter(n.add(const Duration(minutes: 30))) && !taken.contains(t)) out.add(t);
    }
    return out;
  }
}

const _dayShort = ['', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

String daysLabel(List<int> days) {
  final d = [...days]..sort();
  if (d.length == 7) return 'Todos los días';
  // Días seguidos: "Lun a Sáb"
  var consecutive = d.length > 2;
  for (var i = 1; i < d.length; i++) {
    if (d[i] != d[i - 1] + 1) consecutive = false;
  }
  if (consecutive) return '${_dayShort[d.first]} a ${_dayShort[d.last]}';
  return d.map((x) => _dayShort[x]).join(', ');
}

String dayShort(int weekday) => _dayShort[weekday];

// ---------------------------------------------------------------------------
// Pedidos y citas: viajan cifrados dentro de un mensaje del chat con el negocio.
// ---------------------------------------------------------------------------

/// Estados de un pedido o una cita. Solo pueden avanzar como dice [BizDeal.apply].
class BizStatus {
  static const pending = 'new'; // enviado, el negocio aún no responde
  static const accepted = 'ok';
  static const rejected = 'no';
  static const onTheWay = 'road'; // pedidos: salió el delivery
  static const done = 'done'; // entregado / atendido
  static const cancelled = 'cancel'; // lo canceló el cliente

  static const all = {pending, accepted, rejected, onTheWay, done, cancelled};
}

class BizLine {
  final String name;
  final int qty;
  final double? price; // precio de una unidad
  const BizLine(this.name, this.qty, this.price);

  double? get total => price == null ? null : price! * qty;

  Map<String, dynamic> toJson() => {'n': name, 'q': qty, if (price != null) 'p': price};

  static BizLine? tryParse(Object? j) {
    if (j is! Map) return null;
    final n = _s(j['n'], 60);
    final q = (j['q'] as num?)?.toInt() ?? 1;
    if (n.isEmpty || q < 1 || q > 999) return null;
    return BizLine(n, q, _price(j['p']));
  }
}

/// Un pedido (t = order) o una cita (t = cita) entre un cliente y un negocio.
class BizDeal {
  final String type; // order | cita
  final String biz; // accountId del negocio (quien lo atiende)
  final String bizName;
  final String currency;
  final String status;
  final DateTime? statusAt;

  // Pedido
  final List<BizLine> lines;
  final String address;
  final String note;

  // Cita
  final String service;
  final double? price;
  final int minutes;
  final DateTime? at;
  final String staff;

  const BizDeal({
    required this.type,
    required this.biz,
    required this.bizName,
    this.currency = 'RD\$',
    this.status = BizStatus.pending,
    this.statusAt,
    this.lines = const [],
    this.address = '',
    this.note = '',
    this.service = '',
    this.price,
    this.minutes = 30,
    this.at,
    this.staff = '',
  });

  bool get isOrder => type == 'order';
  bool get isBooking => type == 'cita';

  /// Total del pedido (null si algún producto no tiene precio).
  double? get total {
    if (isBooking) return price;
    var t = 0.0;
    for (final l in lines) {
      final x = l.total;
      if (x == null) return null;
      t += x;
    }
    return t;
  }

  int get count => lines.fold(0, (n, l) => n + l.qty);

  bool get closed =>
      status == BizStatus.rejected || status == BizStatus.done || status == BizStatus.cancelled;

  Map<String, dynamic> toJson() => {
        't': type,
        'biz': biz,
        'bn': bizName,
        'cur': currency,
        'st': status,
        if (statusAt != null) 'sa': statusAt!.toUtc().toIso8601String(),
        if (lines.isNotEmpty) 'l': [for (final l in lines) l.toJson()],
        if (address.isNotEmpty) 'addr': address,
        if (note.isNotEmpty) 'note': note,
        if (service.isNotEmpty) 'svc': service,
        if (price != null) 'p': price,
        if (isBooking) 'min': minutes,
        if (at != null) 'at': at!.toUtc().toIso8601String(),
        if (staff.isNotEmpty) 'stf': staff,
      };

  static BizDeal? tryParse(Object? j) {
    if (j is! Map) return null;
    final type = j['t'];
    if (type != 'order' && type != 'cita') return null;
    final biz = _s(j['biz'], 64);
    if (biz.isEmpty) return null;
    final st = j['st'] is String && BizStatus.all.contains(j['st']) ? j['st'] as String : BizStatus.pending;
    final lines = <BizLine>[
      if (j['l'] is List)
        for (final x in (j['l'] as List).take(100))
          if (BizLine.tryParse(x) != null) BizLine.tryParse(x)!
    ];
    final at = j['at'] is String ? DateTime.tryParse(j['at'] as String)?.toLocal() : null;
    if (type == 'order' && lines.isEmpty) return null;
    if (type == 'cita' && (at == null || _s(j['svc'], 60).isEmpty)) return null;
    final min = (j['min'] as num?)?.toInt() ?? 30;
    final cur = _s(j['cur'], 4);
    return BizDeal(
      type: type as String,
      biz: biz,
      bizName: _s(j['bn'], 60),
      currency: bizCurrencies.contains(cur) ? cur : 'RD\$',
      status: st,
      statusAt: j['sa'] is String ? DateTime.tryParse(j['sa'] as String)?.toLocal() : null,
      lines: lines,
      address: _s(j['addr'], 160),
      note: _s(j['note'], 300),
      service: _s(j['svc'], 60),
      price: _price(j['p']),
      minutes: min < 5 || min > 600 ? 30 : min,
      at: at,
      staff: _s(j['stf'], 30),
    );
  }

  BizDeal withStatus(String s, DateTime when) => BizDeal(
        type: type,
        biz: biz,
        bizName: bizName,
        currency: currency,
        status: s,
        statusAt: when,
        lines: lines,
        address: address,
        note: note,
        service: service,
        price: price,
        minutes: minutes,
        at: at,
        staff: staff,
      );

  /// Un mensaje nuevo recibido: empieza siempre como pendiente.
  BizDeal fresh() => withStatus(BizStatus.pending, DateTime.now());

  /// Aplica un cambio de estado hecho por [who]. Devuelve null si no vale.
  ///  - El negocio acepta, rechaza, pone "en camino" (pedidos) y "entregado/atendido".
  ///  - El cliente solo puede cancelar mientras no esté cerrado ni en camino.
  BizDeal? apply(Map<String, dynamic> ev, String who, {DateTime? now}) {
    final to = ev['s'];
    if (to is! String || !BizStatus.all.contains(to) || to == status || closed) return null;
    final when = now ?? DateTime.now();
    final isBiz = who == biz;
    final ok = switch (to) {
      BizStatus.accepted => isBiz && status == BizStatus.pending,
      BizStatus.rejected => isBiz && (status == BizStatus.pending || status == BizStatus.accepted),
      BizStatus.onTheWay => isBiz && isOrder && status == BizStatus.accepted,
      BizStatus.done => isBiz && (status == BizStatus.accepted || status == BizStatus.onTheWay),
      BizStatus.cancelled => !isBiz && (status == BizStatus.pending || status == BizStatus.accepted),
      _ => false,
    };
    return ok ? withStatus(to, when) : null;
  }

  String get statusLabel => switch (status) {
        BizStatus.pending => isOrder ? 'Esperando al negocio' : 'Esperando confirmación',
        BizStatus.accepted => isOrder ? 'Aceptado' : 'Cita confirmada',
        BizStatus.rejected => isOrder ? 'No lo pueden atender' : 'Cita rechazada',
        BizStatus.onTheWay => 'En camino 🛵',
        BizStatus.done => isOrder ? 'Entregado ✅' : 'Atendido ✅',
        BizStatus.cancelled => 'Cancelado',
        _ => status,
      };

  /// Texto que acompaña al mensaje (lo leen también las versiones viejas de KLK).
  String summary() {
    if (isBooking) {
      final when = at == null ? '' : DateFormat("EEEE d 'de' MMMM, h:mm a", 'es').format(at!);
      return '📅 Cita: $service${staff.isEmpty ? '' : ' con $staff'} — $when';
    }
    final items = lines.map((l) => '${l.qty} × ${l.name}').join(', ');
    final t = total;
    return '🛒 Pedido: $items${t == null ? '' : ' — ${bizMoney(t, currency)}'}';
  }
}

// ---------------------------------------------------------------------------
// Libreta del fiao (solo en el móvil del negocio)
// ---------------------------------------------------------------------------

class FiaoEntry {
  final double amount; // positivo = me debe más; negativo = pagó
  final String note;
  final DateTime at;
  const FiaoEntry(this.amount, this.note, this.at);

  Map<String, dynamic> toJson() => {'a': amount, if (note.isNotEmpty) 'n': note, 'at': at.millisecondsSinceEpoch};
  static FiaoEntry? tryParse(Object? j) {
    if (j is! Map || j['a'] is! num || j['at'] is! num) return null;
    return FiaoEntry((j['a'] as num).toDouble(), _s(j['n'], 120),
        DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()));
  }
}

/// La cuenta de un cliente en la libreta.
class FiaoAccount {
  final String id; // id del chat del cliente ('' si no usa KLK)
  final String name;
  final List<FiaoEntry> entries;
  final DateTime? remindedAt;
  const FiaoAccount({required this.id, required this.name, this.entries = const [], this.remindedAt});

  double get balance => entries.fold(0.0, (t, e) => t + e.amount);
  DateTime? get since => entries.isEmpty ? null : entries.map((e) => e.at).reduce((a, b) => a.isBefore(b) ? a : b);

  FiaoAccount add(FiaoEntry e) => FiaoAccount(id: id, name: name, entries: [...entries, e], remindedAt: remindedAt);
  FiaoAccount reminded(DateTime t) => FiaoAccount(id: id, name: name, entries: entries, remindedAt: t);

  Map<String, dynamic> toJson() => {
        'id': id,
        'n': name,
        'e': [for (final e in entries) e.toJson()],
        if (remindedAt != null) 'r': remindedAt!.millisecondsSinceEpoch,
      };

  static FiaoAccount? tryParse(Object? j) {
    if (j is! Map) return null;
    final name = _s(j['n'], 60);
    if (name.isEmpty) return null;
    return FiaoAccount(
      id: _s(j['id'], 64),
      name: name,
      entries: [
        if (j['e'] is List)
          for (final x in (j['e'] as List))
            if (FiaoEntry.tryParse(x) != null) FiaoEntry.tryParse(x)!
      ],
      remindedAt: j['r'] is num ? DateTime.fromMillisecondsSinceEpoch((j['r'] as num).toInt()) : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Negocios de ejemplo para el modo demo (no existen de verdad).
// ---------------------------------------------------------------------------

List<BizProfile> demoBusinesses() => const [
      BizProfile(
        id: 'demo-biz-colmado',
        name: 'Colmado La Esquina',
        kind: BizKind.colmado,
        country: 'DO',
        city: 'Santo Domingo',
        about: 'Todo lo de la casa, frío y a buen precio.',
        address: 'Calle 5, esquina 8',
        delivery: 'Delivery: RD\$ 50',
        openHour: 8,
        closeHour: 23,
        days: [1, 2, 3, 4, 5, 6, 7],
        quick: ['Abierto hasta las 11', 'Ya va en camino'],
        items: [
          BizItem(id: 'a', name: 'Arroz (libra)', price: 35, cat: 'Despensa'),
          BizItem(id: 'b', name: 'Aceite', price: 220, cat: 'Despensa'),
          BizItem(id: 'c', name: 'Salami', price: 180, cat: 'Despensa'),
          BizItem(id: 'd', name: 'Habichuelas', price: 60, cat: 'Despensa'),
          BizItem(id: 'e', name: 'Refresco 2 L', price: 120, cat: 'Bebidas'),
          BizItem(id: 'f', name: 'Agua (botellón)', price: 75, cat: 'Bebidas'),
        ],
      ),
      BizProfile(
        id: 'demo-biz-barberia',
        name: 'Barbería El Flow',
        kind: BizKind.peluqueria,
        country: 'DO',
        city: 'Santiago',
        about: 'Cortes y barba con estilo.',
        address: 'Av. Las Carreras 12',
        openHour: 9,
        closeHour: 19,
        days: [2, 3, 4, 5, 6],
        slotMin: 30,
        staff: ['Juan', 'Miguel'],
        items: [
          BizItem(id: 'c', name: 'Corte', price: 300, minutes: 30),
          BizItem(id: 'b', name: 'Barba', price: 200, minutes: 30),
          BizItem(id: 'cb', name: 'Corte + barba', price: 450, minutes: 60),
        ],
      ),
    ];
