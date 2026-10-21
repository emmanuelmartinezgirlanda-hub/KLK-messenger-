import 'package:flutter_test/flutter_test.dart';
import 'package:klk/features/san/san.dart';

void main() {
  San make({String period = '2week'}) => San(
        name: 'San de la familia',
        amount: 1000,
        currency: 'RD\$',
        period: period,
        start: DateTime(2026, 1, 31),
        organizer: 'ana',
        slots: const [SanSlot('ana', 'Ana'), SanSlot('luis', 'Luis'), SanSlot('ana', 'Ana'), SanSlot('mari', 'Mari')],
      );

  test('fechas, bote y turno actual', () {
    final s = make();
    expect(s.pot, 4000);
    expect(s.dateOf(1), DateTime(2026, 2, 14));
    expect(make(period: 'month').dateOf(1), DateTime(2026, 2, 28)); // 31 → último día de febrero
    expect(make(period: 'week').dateOf(2), DateTime(2026, 2, 14));
    expect(s.currentRound(DateTime(2026, 1, 1)), 0);
    expect(s.started(DateTime(2026, 1, 1)), isFalse);
    expect(s.currentRound(DateTime(2026, 2, 20)), 1);
    expect(s.slotsOf('ana'), [0, 2]);
  });

  test('reglas de los pagos', () {
    final s = make();
    // Luis avisa que pagó su número (1) en el turno 0
    final a = s.apply({'a': 'pay', 'r': 0, 's': 1, 'v': 'claimed'}, 'luis')!;
    expect(a.payOf(0, 1), SanPay.claimed);
    // Luis no puede confirmar ni tocar el de otro
    expect(s.apply({'a': 'pay', 'r': 0, 's': 1, 'v': 'paid'}, 'luis'), isNull);
    expect(s.apply({'a': 'pay', 'r': 0, 's': 3, 'v': 'claimed'}, 'luis'), isNull);
    // La organizadora confirma
    final b = a.apply({'a': 'pay', 'r': 0, 's': 1, 'v': 'paid'}, 'ana')!;
    expect(b.payOf(0, 1), SanPay.paid);
    // Ya confirmado: Luis no lo puede quitar
    expect(b.apply({'a': 'pay', 'r': 0, 's': 1, 'v': 'none'}, 'luis'), isNull);
    // Fuera de rango
    expect(s.apply({'a': 'pay', 'r': 9, 's': 0, 'v': 'paid'}, 'ana'), isNull);
    // Terminar: solo la organizadora
    expect(s.apply({'a': 'end'}, 'luis'), isNull);
    expect(s.apply({'a': 'end'}, 'ana')!.ended, isTrue);
  });

  test('ida y vuelta en JSON', () {
    final s = make().apply({'a': 'pay', 'r': 2, 's': 0, 'v': 'paid'}, 'ana')!;
    final back = San.tryParse(s.toJson())!;
    expect(back.name, s.name);
    expect(back.slots.length, 4);
    expect(back.payOf(2, 0), SanPay.paid);
    expect(back.start, DateTime(2026, 1, 31));
    expect(San.tryParse({'sl': []}), isNull);
    expect(formatSanMoney(10000, 'RD\$'), 'RD\$ 10.000');
    expect(formatSanMoney(50, '€'), '50 €');
  });
}
