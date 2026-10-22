import 'package:flutter_test/flutter_test.dart';
import 'package:klk/features/san/san.dart';

void main() {
  final san = San(
    name: 'Prueba',
    amount: 100,
    currency: '€',
    period: 'month',
    start: DateTime(2026, 1, 1),
    organizer: 'org',
    slots: const [SanSlot('a', 'Ana'), SanSlot('b', 'Beto')],
  );

  test('solo el organizador marca el envío y solo quien cobra confirma', () {
    expect(san.apply({'a': 'sent', 'r': 0}, 'a'), isNull);
    final sent = san.apply({'a': 'sent', 'r': 0}, 'org')!;
    expect(sent.outOf(0), 'sent');
    expect(sent.apply({'a': 'got', 'r': 0}, 'b'), isNull);
    final got = sent.apply({'a': 'got', 'r': 0}, 'a')!;
    expect(got.outOf(0), 'got');
    expect(got.apply({'a': 'sent', 'r': 0}, 'org'), isNull);
    expect(san.apply({'a': 'got', 'r': 0}, 'a'), isNull, reason: 'no se confirma algo que no se envió');
    final back = San.tryParse(got.toJson())!;
    expect(back.outOf(0), 'got');
    expect(back.outOf(1), isNull);
    expect(sent.apply({'a': 'unsent', 'r': 0}, 'org')!.outOf(0), isNull);
  });

  test('datos del banco', () {
    final b = SanBank(holder: 'Ana', account: 'IE12 BOFI 9000 0112 3456 78', at: DateTime(2026));
    expect(b.masked, 'IE12 •••• 5678');
    final back = SanBank.tryParse(b.toJson())!;
    expect(back.sameAccount(b), isTrue);
    expect(SanBank.tryParse({'h': 'x'}), isNull);
    expect(b.sameAccount(SanBank(holder: 'Ana', account: 'ES00 1111', at: DateTime(2026))), isFalse);
  });
}
