import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class Country {
  final String flag;
  final String name;
  final String dialCode; // "+1", "+34"…
  final String example;
  final String timeZone;
  const Country(this.flag, this.name, this.dialCode, this.example, this.timeZone);
}

/// Países con más diáspora dominicana primero.
const countries = <Country>[
  Country('🇩🇴', 'República Dominicana', '+1', '809 555 1234', 'America/Santo_Domingo'),
  Country('🇺🇸', 'Estados Unidos', '+1', '212 555 1234', 'America/New_York'),
  Country('🇵🇷', 'Puerto Rico', '+1', '787 555 1234', 'America/Puerto_Rico'),
  Country('🇪🇸', 'España', '+34', '612 34 56 78', 'Europe/Madrid'),
  Country('🇮🇹', 'Italia', '+39', '312 345 6789', 'Europe/Rome'),
  Country('🇮🇪', 'Irlanda', '+353', '85 123 4567', 'Europe/Dublin'),
  Country('🇨🇭', 'Suiza', '+41', '78 123 45 67', 'Europe/Zurich'),
  Country('🇨🇱', 'Chile', '+56', '9 1234 5678', 'America/Santiago'),
  Country('🇵🇦', 'Panamá', '+507', '6123 4567', 'America/Panama'),
  Country('🇨🇦', 'Canadá', '+1', '416 555 1234', 'America/Toronto'),
];

/// Une prefijo y número en formato E.164: "+18095551234".
String toE164(Country c, String local) {
  final digits = local.replaceAll(RegExp(r'\D'), '');
  return '${c.dialCode}$digits';
}

bool isValidE164(String p) => RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(p);

/// Convierte un número de la agenda ("(809) 555-1234", "0034 612…", "612 34 56 78")
/// a E.164. [defaultDial] es el prefijo de mi país ("+1", "+34"…).
/// Devuelve null si no parece un número válido.
String? normalizePhone(String raw, String defaultDial) {
  var s = raw.trim().replaceAll(RegExp(r'[^\d+]'), '');
  if (s.isEmpty) return null;
  if (s.startsWith('00')) s = '+${s.substring(2)}';
  if (!s.startsWith('+')) {
    final digits = s.replaceAll('+', '');
    // Números de RD/EE. UU. escritos sin prefijo: 10 cifras o 11 empezando por 1
    if (digits.length == 11 && digits.startsWith('1')) {
      s = '+$digits';
    } else if (digits.length == 10 && defaultDial == '+1') {
      s = '+1$digits';
    } else if (digits.length == 10 && const ['809', '829', '849'].contains(digits.substring(0, 3))) {
      s = '+1$digits'; // un número dominicano en la agenda de alguien que vive fuera
    } else {
      s = '$defaultDial$digits';
    }
  }
  return isValidE164(s) ? s : null;
}

/// Prefijo del país de un número E.164 propio (para normalizar la agenda).
String dialCodeOf(String e164) {
  final codes = countries.map((c) => c.dialCode).toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final c in codes) {
    if (e164.startsWith(c)) return c;
  }
  return '+1';
}

/// Muestra un E.164 de forma legible: "+1 809 555 1234".
String prettyPhone(String e164) {
  for (final c in countries) {
    if (e164.startsWith(c.dialCode)) {
      final rest = e164.substring(c.dialCode.length);
      if (c.dialCode == '+1' && rest.length == 10) {
        return '+1 ${rest.substring(0, 3)} ${rest.substring(3, 6)} ${rest.substring(6)}';
      }
      return '${c.dialCode} $rest';
    }
  }
  return e164;
}

// ---------- "Hora de allá" ----------

bool _tzReady = false;

/// Zona horaria aproximada a partir del número de teléfono.
({String zone, String place})? zoneForPhone(String e164) {
  if (e164.startsWith('+1')) {
    final area = e164.length >= 5 ? e164.substring(2, 5) : '';
    if (const ['809', '829', '849'].contains(area)) {
      return (zone: 'America/Santo_Domingo', place: 'RD');
    }
    if (const ['787', '939'].contains(area)) {
      return (zone: 'America/Puerto_Rico', place: 'Puerto Rico');
    }
    return null; // EE. UU./Canadá tienen varias zonas: no adivinamos.
  }
  const byCode = {
    '+34': ('Europe/Madrid', 'España'),
    '+39': ('Europe/Rome', 'Italia'),
    '+353': ('Europe/Dublin', 'Irlanda'),
    '+41': ('Europe/Zurich', 'Suiza'),
    '+56': ('America/Santiago', 'Chile'),
    '+507': ('America/Panama', 'Panamá'),
  };
  for (final e in byCode.entries) {
    if (e164.startsWith(e.key)) return (zone: e.value.$1, place: e.value.$2);
  }
  return null;
}

/// Hora actual en una zona, p. ej. "4:52 p. m.".
DateTime nowIn(String zone) {
  if (!_tzReady) {
    tzdata.initializeTimeZones();
    _tzReady = true;
  }
  final t = tz.TZDateTime.now(tz.getLocation(zone));
  return DateTime(t.year, t.month, t.day, t.hour, t.minute);
}
