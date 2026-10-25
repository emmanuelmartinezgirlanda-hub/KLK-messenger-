import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:klk/features/business/business.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  BizDeal order() => const BizDeal(
        type: 'order',
        biz: 'colmado',
        bizName: 'Colmado La Esquina',
        lines: [BizLine('Arroz', 2, 35), BizLine('Aceite', 1, 220)],
        address: 'Calle 5',
      );

  test('el perfil va y vuelve igual (y limpia datos malos)', () {
    final p = BizProfile.tryParse({
      'id': 'x',
      'name': 'Barbería El Flow',
      'kind': 'peluqueria',
      'country': 'DO',
      'verified': true,
      'data': {
        'open': 9,
        'close': 19,
        'days': [2, 3, 3, 9, 4],
        'slot': 30,
        'cur': 'BTC',
        'staff': ['Juan', '', 'Miguel'],
        'items': [
          {'id': 'c', 'n': 'Corte', 'p': 300, 'm': 30},
          {'id': '', 'n': 'Sin id'},
          {'id': 'b', 'n': 'Barba', 'p': -5},
        ],
      },
    })!;
    expect(p.kind, BizKind.peluqueria);
    expect(p.kind.usesBookings, isTrue);
    expect(p.days, [2, 3, 4]);
    expect(p.currency, 'RD\$');
    expect(p.staff, ['Juan', 'Miguel']);
    expect(p.items.length, 2);
    expect(p.items.last.price, isNull); // precio negativo = "consultar"
    expect(p.verified, isTrue);

    final again = BizProfile.tryParse(p.toJson())!;
    expect(again.name, p.name);
    expect(again.items.first.minutes, 30);
    expect(p.toRequest().containsKey('verified'), isFalse); // eso solo lo pone KLK
    expect(BizProfile.tryParse({'name': ''}), isNull);
    expect(BizKind.parse('casino'), BizKind.otro);
  });

  test('horas libres para citas', () {
    final p = BizProfile.tryParse({
      'id': 'x',
      'name': 'Salón',
      'kind': 'belleza',
      'data': {'open': 9, 'close': 12, 'days': [1], 'slot': 30},
    })!;
    final monday = DateTime(2026, 11, 2); // lunes
    final slots = p.slotsFor(monday, 60, now: DateTime(2026, 11, 1));
    expect(slots.first, DateTime(2026, 11, 2, 9));
    expect(slots.last, DateTime(2026, 11, 2, 11)); // 11:00 + 60 min = cierre
    expect(slots.length, 5);
    expect(p.slotsFor(DateTime(2026, 11, 3), 30, now: DateTime(2026, 11, 1)), isEmpty); // martes cerrado
    final taken = p.slotsFor(monday, 60, now: DateTime(2026, 11, 1), taken: {DateTime(2026, 11, 2, 10)});
    expect(taken.contains(DateTime(2026, 11, 2, 10)), isFalse);
    expect(p.openAt(DateTime(2026, 11, 2, 10)), isTrue);
    expect(p.openAt(DateTime(2026, 11, 2, 12)), isFalse);
  });

  test('pedido: total, resumen y quién puede cambiar el estado', () {
    final o = order();
    expect(o.total, 290);
    expect(o.count, 3);
    expect(o.summary(), contains('2 × Arroz'));

    // El cliente no puede aceptar su propio pedido
    expect(o.apply({'s': BizStatus.accepted}, 'cliente'), isNull);
    final ok = o.apply({'s': BizStatus.accepted}, 'colmado')!;
    expect(ok.status, BizStatus.accepted);
    // "En camino" solo después de aceptar, y solo el negocio
    expect(o.apply({'s': BizStatus.onTheWay}, 'colmado'), isNull);
    final road = ok.apply({'s': BizStatus.onTheWay}, 'colmado')!;
    expect(road.apply({'s': BizStatus.cancelled}, 'cliente'), isNull); // ya va en camino
    final done = road.apply({'s': BizStatus.done}, 'colmado')!;
    expect(done.closed, isTrue);
    expect(done.apply({'s': BizStatus.rejected}, 'colmado'), isNull);
    // Cancelar mientras está pendiente
    expect(o.apply({'s': BizStatus.cancelled}, 'cliente')!.status, BizStatus.cancelled);
    expect(o.apply({'s': 'raro'}, 'colmado'), isNull);

    // Ida y vuelta por la red
    final wire = BizDeal.tryParse(done.toJson())!;
    expect(wire.status, BizStatus.done);
    expect(wire.lines.length, 2);
    expect(BizDeal.tryParse({'t': 'order', 'biz': 'x'}), isNull); // pedido sin productos
  });

  test('cita: necesita hora y servicio; sin "en camino"', () {
    final c = BizDeal(
      type: 'cita',
      biz: 'barberia',
      bizName: 'El Flow',
      service: 'Corte',
      price: 300,
      minutes: 30,
      at: DateTime(2026, 11, 4, 16),
      staff: 'Juan',
    );
    final wire = BizDeal.tryParse(c.toJson())!;
    expect(wire.at, DateTime(2026, 11, 4, 16));
    expect(wire.total, 300);
    final ok = wire.apply({'s': BizStatus.accepted}, 'barberia')!;
    expect(ok.apply({'s': BizStatus.onTheWay}, 'barberia'), isNull);
    expect(ok.apply({'s': BizStatus.done}, 'barberia')!.status, BizStatus.done);
    expect(BizDeal.tryParse({'t': 'cita', 'biz': 'x', 'svc': 'Corte'}), isNull); // sin hora
  });

  test('libreta del fiao', () {
    var a = FiaoAccount(id: 'c1', name: 'Doña Carmen', entries: [FiaoEntry(850, 'arroz', DateTime(2026, 10, 20))]);
    a = a.add(FiaoEntry(300, '', DateTime(2026, 10, 21)));
    expect(a.balance, 1150);
    a = a.add(FiaoEntry(-1150, 'pagó', DateTime(2026, 10, 25)));
    expect(a.balance, 0);
    final back = FiaoAccount.tryParse(a.toJson())!;
    expect(back.entries.length, 3);
    expect(back.since, DateTime(2026, 10, 20));
  });

  test('días abiertos en texto', () {
    expect(daysLabel([1, 2, 3, 4, 5, 6]), 'Lun a Sáb');
    expect(daysLabel([1, 2, 3, 4, 5, 6, 7]), 'Todos los días');
    expect(daysLabel([1, 3, 5]), 'Lun, Mié, Vie');
  });
}
