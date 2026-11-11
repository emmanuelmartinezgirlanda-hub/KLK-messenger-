/// Lee el archivo que crea WhatsApp con «Exportar chat» (iPhone y Android, en
/// español, inglés y otros idiomas) y lo convierte en mensajes.
///
/// Formatos que entiende:
///   iPhone:  [09/11/26, 21:07:12] Mamá: Hola mi hijo
///            ‎[09/11/26, 21:08:00] Mamá: ‎<adjunto: 00000012-PHOTO-2026-11-09-21-08-00.jpg>
///   Android: 9/11/26, 21:07 - Mamá: Hola mi hijo
///            9/11/26, 21:08 - Mamá: IMG-20261109-WA0001.jpg (archivo adjunto)
///   Con hora AM/PM:  [11/9/26, 9:07:12 p. m.] Mamá: …
library;

class WaMessage {
  WaMessage({required this.at, required this.sender, required this.body, this.attachment});
  final DateTime at;
  final String sender;
  String body;
  String? attachment; // nombre del archivo dentro del .zip
}

class WaChat {
  WaChat(this.messages);
  final List<WaMessage> messages;

  /// Personas que escriben, de más a menos mensajes.
  List<String> get participants {
    final count = <String, int>{};
    for (final m in messages) {
      count[m.sender] = (count[m.sender] ?? 0) + 1;
    }
    final list = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
    return list;
  }
}

// Marcas invisibles que mete WhatsApp (dirección de texto, espacios finos…).
final _invisible = RegExp(r'[\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]');

final _line = RegExp(
  r'^\[?(\d{1,4})[./-](\d{1,2})[./-](\d{1,4}),?\s+(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?\s*([aApP]\.?\s?[mM]\.?)?\]?\s*(?:[-–]\s*)?([^:]{1,80}?):\s?(.*)$',
);
// Línea de sistema (sin «Nombre:»), p. ej. «Los mensajes están cifrados…»: se salta.
final _systemLine = RegExp(
  r'^\[?(\d{1,4})[./-](\d{1,2})[./-](\d{1,4}),?\s+(\d{1,2})[:.](\d{2})',
);

final _iosAttach = RegExp(r'<(?:adjunto|attached|anexo|allegato|pièce jointe|joint)\s*:\s*([^>]+)>', caseSensitive: false);
final _androidAttach = RegExp(
    r'^(\S+\.(?:jpg|jpeg|png|webp|gif|heic|mp4|mov|3gp|opus|ogg|m4a|mp3|aac|pdf|docx?|xlsx?|pptx?|txt|zip|vcf|webm))\s*\((?:archivo adjunto|file attached|arquivo anexado|allegato|fichier joint)\)',
    caseSensitive: false);

/// Mensajes que WhatsApp pone en lugar de lo que no exportó.
final _omitted = RegExp(
    r'^(?:<?\s*(?:Multimedia omitido|Media omitted|imagen omitida|image omitted|video omitido|video omitted|audio omitido|audio omitted|sticker omitido|sticker omitted|documento omitido|document omitted|GIF omitido|GIF omitted)\s*>?)$',
    caseSensitive: false);

WaChat parseWhatsApp(String text) {
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final raw = <List<String?>>[]; // [a, b, c, h, m, s, ampm, sender, body]
  final bodies = <StringBuffer>[];

  for (final original in lines) {
    final line = original.replaceAll(_invisible, '').replaceAll(' ', ' ').replaceAll(' ', ' ');
    final m = _line.firstMatch(line);
    if (m != null) {
      raw.add([for (var i = 1; i <= 8; i++) m.group(i)]);
      bodies.add(StringBuffer(m.group(9) ?? ''));
      continue;
    }
    if (_systemLine.hasMatch(line)) {
      // Aviso de WhatsApp sin remitente: corta el mensaje anterior.
      raw.add(const [null]);
      bodies.add(StringBuffer());
      continue;
    }
    if (bodies.isNotEmpty) {
      bodies.last
        ..write('\n')
        ..write(line);
    }
  }

  // ¿Día/mes o mes/día? Si algún primer número pasa de 12 es día; si es el
  // segundo, el formato es de EE. UU. Si no se sabe, día/mes (español).
  var dayFirst = true;
  var yearFirst = false;
  for (final r in raw) {
    if (r.length < 8) continue;
    final a = int.parse(r[0]!), b = int.parse(r[1]!);
    if (r[0]!.length == 4) {
      yearFirst = true;
      break;
    }
    if (a > 12) {
      dayFirst = true;
      break;
    }
    if (b > 12) {
      dayFirst = false;
      break;
    }
  }

  final out = <WaMessage>[];
  for (var i = 0; i < raw.length; i++) {
    final r = raw[i];
    if (r.length < 8) continue;
    final n0 = int.parse(r[0]!), n1 = int.parse(r[1]!), n2 = int.parse(r[2]!);
    int y, mo, d;
    if (yearFirst) {
      y = n0;
      mo = n1;
      d = n2;
    } else {
      y = n2 < 100 ? 2000 + n2 : n2;
      d = dayFirst ? n0 : n1;
      mo = dayFirst ? n1 : n0;
    }
    var h = int.parse(r[3]!);
    final min = int.parse(r[4]!);
    final s = int.tryParse(r[5] ?? '') ?? 0;
    final ampm = (r[6] ?? '').toLowerCase().replaceAll(RegExp(r'[^ap]'), '');
    if (ampm == 'p' && h < 12) h += 12;
    if (ampm == 'a' && h == 12) h = 0;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) continue;
    final at = DateTime(y, mo, d, h, min, s);
    final sender = r[7]!.trim();
    var body = bodies[i].toString().trim();
    String? attachment;
    final ia = _iosAttach.firstMatch(body);
    if (ia != null) {
      attachment = ia.group(1)!.trim();
      body = body.replaceFirst(ia.group(0)!, '').trim();
    } else {
      final aa = _androidAttach.firstMatch(body);
      if (aa != null) {
        attachment = aa.group(1)!.trim();
        body = body.substring(aa.end).trim();
      }
    }
    if (attachment == null && _omitted.hasMatch(body)) body = '📎 (adjunto no exportado)';
    if (body.isEmpty && attachment == null) continue;
    out.add(WaMessage(at: at, sender: sender, body: body, attachment: attachment));
  }
  return WaChat(out);
}
