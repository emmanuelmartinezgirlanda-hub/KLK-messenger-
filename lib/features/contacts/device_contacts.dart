import 'dart:io';

import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/util/phone.dart';

/// Un contacto de la agenda con su número ya en formato E.164.
class PhoneContact {
  final String name;
  final String phone;
  final String? accountId; // no nulo si usa KLK
  const PhoneContact({required this.name, required this.phone, this.accountId});

  bool get onKlk => accountId != null;
  PhoneContact withAccount(String? id) => PhoneContact(name: name, phone: phone, accountId: id);
}

/// Lee la agenda del teléfono. La agenda no sale del móvil: solo se
/// envían los números al servidor para saber cuáles usan KLK.
class DeviceContacts {
  static Future<bool> requestPermission() async {
    final status = await FlutterContacts.permissions.request(PermissionType.read);
    // iOS 18+: el usuario puede compartir solo algunos contactos ("limitado").
    return status == PermissionStatus.granted || status == PermissionStatus.limited;
  }

  static Future<List<PhoneContact>> load(String defaultDial) async {
    final list = await FlutterContacts.getAll(properties: {ContactProperty.name, ContactProperty.phone});
    final seen = <String>{};
    final out = <PhoneContact>[];
    for (final c in list) {
      final name = (c.displayName ?? '').trim();
      for (final ph in c.phones) {
        final normalized = ph.normalizedNumber ?? '';
        final raw = normalized.isNotEmpty ? normalized : ph.number;
        final e164 = normalizePhone(raw, defaultDial);
        if (e164 != null && seen.add(e164)) {
          out.add(PhoneContact(name: name.isEmpty ? prettyPhone(e164) : name, phone: e164));
        }
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Contactos de ejemplo para el modo demo.
  static const demo = [
    PhoneContact(name: 'Abuela Carmen', phone: '+18095550112'),
    PhoneContact(name: 'Carlos Peña', phone: '+353851234560'),
    PhoneContact(name: 'Doña Altagracia', phone: '+18295550133'),
    PhoneContact(name: 'Franchesca', phone: '+12125550144'),
    PhoneContact(name: 'José Miguel', phone: '+34611222338'),
    PhoneContact(name: 'Lisbeth', phone: '+34622333446'),
    PhoneContact(name: 'Manolo el barbero', phone: '+18495550157'),
    PhoneContact(name: 'Pedro Santana', phone: '+34633444552'),
    PhoneContact(name: 'Wanda', phone: '+17875550161'),
    PhoneContact(name: 'Yokasta', phone: '+18095550179'),
  ];

  /// Abre Mensajes con una invitación para unirse a KLK.
  static Future<void> invite(String phone) async {
    const text = '¡Klk! Estoy usando KLK, la app de mensajería de los dominicanos en el mundo. '
        'Es privada y gratis. Descárgala y escríbeme 🇩🇴';
    final sep = Platform.isIOS ? '&' : '?';
    final uri = Uri.parse('sms:$phone${sep}body=${Uri.encodeComponent(text)}');
    await launchUrl(uri);
  }
}
