import 'package:flutter_test/flutter_test.dart';
import 'package:klk/features/topup/recharge_sheet.dart';

void main() {
  test('números de RD', () {
    expect(normalizeDrPhone('809 555 1234'), '+18095551234');
    expect(normalizeDrPhone('+1 (829) 555-1234'), '+18295551234');
    expect(isDominicanMobile('+18495551234'), isTrue);
    expect(isDominicanMobile('+17865551234'), isFalse);
    expect(isDominicanMobile('+34600000000'), isFalse);
  });

  test('precios', () {
    expect(formatMoney(375, 'EUR'), '3,75 €');
    expect(shortOperator('Altice República Dominicana'), 'Altice');
  });
}
