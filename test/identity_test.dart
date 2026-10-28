import 'package:flutter_test/flutter_test.dart';
import 'package:klk/core/util/phone.dart';
import 'package:klk/features/contacts/my_qr_screen.dart';

void main() {
  test('enlace y QR de quien entró con correo van por su @usuario', () {
    expect(contactLink('https://srv.test', 'mail:ana@correo.com', 'Ana'), '');
    expect(contactLink('https://srv.test', 'mail:ana@correo.com', 'Ana', username: 'ana.do'), 'https://srv.test/u/ana.do');
    expect(contactLink('https://srv.test', '+18095551234', 'Ana', username: 'ana.do'), 'https://srv.test/c/18095551234?n=Ana');
    expect(parseContactLink('https://srv.test/u/ana.do'), ('@ana.do', ''));
    expect(parseContactLink('https://srv.test/c/18095551234?n=Ana'), ('+18095551234', 'Ana'));
    expect(parseContactLink('https://srv.test/u/A'), isNull);
  });

  test('una cuenta de correo se muestra con su correo', () {
    expect(prettyPhone('mail:ana@correo.com'), 'ana@correo.com');
    expect(prettyPhone('+18095551234'), '+1 809 555 1234');
  });
}
