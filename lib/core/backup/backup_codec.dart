import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Error legible de la copia de seguridad.
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}

/// Formato de la copia de seguridad de KLK (archivo .klk).
///
/// Todo va cifrado con una clave derivada de la contraseña que elige el usuario
/// (PBKDF2-HMAC-SHA256 + AES-256-GCM). Ni KLK ni Apple pueden abrirla sin ella.
///
///   "KLKB" | versión (1 byte) | iteraciones (4 bytes) | sal (16) | nonce (12) | mac (16) | datos cifrados
///
/// Dentro, los datos son una lista de entradas: [largo del nombre][nombre][largo][bytes].
class BackupCodec {
  static const _magic = [0x4B, 0x4C, 0x4B, 0x42]; // "KLKB"
  static const _version = 1;
  static const defaultIterations = 150000;
  static const minPasswordLength = 8;
  static final _aes = AesGcm.with256bits();

  static Future<SecretKey> _derive(String password, List<int> salt, int iterations) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
          .deriveKeyFromPassword(password: password, nonce: salt);

  /// Empaqueta y cifra las entradas.
  static Future<Uint8List> seal(Map<String, List<int>> entries, String password,
      {int iterations = defaultIterations}) async {
    if (password.length < minPasswordLength) {
      throw const BackupException('La contraseña debe tener al menos 8 caracteres');
    }
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    final key = await _derive(password, salt, iterations);
    final box = await _aes.encrypt(pack(entries), secretKey: key);
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(_version)
      ..add(_u32(iterations))
      ..add(salt)
      ..add(box.nonce)
      ..add(box.mac.bytes)
      ..add(box.cipherText);
    return out.takeBytes();
  }

  /// Descifra y desempaqueta. Lanza [BackupException] si la contraseña no es
  /// correcta o el archivo no es una copia de KLK.
  static Future<Map<String, Uint8List>> open(List<int> data, String password) async {
    const header = 4 + 1 + 4 + 16 + 12 + 16;
    if (data.length < header || !_startsWithMagic(data)) {
      throw const BackupException('Ese archivo no es una copia de seguridad de KLK');
    }
    if (data[4] != _version) {
      throw const BackupException('Esta copia es de una versión más nueva de KLK. Actualiza la app.');
    }
    final iterations = _readU32(data, 5);
    if (iterations < 10000 || iterations > 5000000) {
      throw const BackupException('La copia está dañada');
    }
    final salt = data.sublist(9, 25);
    final nonce = data.sublist(25, 37);
    final mac = data.sublist(37, 53);
    final cipher = data.sublist(53);
    final key = await _derive(password, salt, iterations);
    try {
      final clear = await _aes.decrypt(SecretBox(cipher, nonce: nonce, mac: Mac(mac)), secretKey: key);
      return unpack(clear);
    } on SecretBoxAuthenticationError {
      throw const BackupException('Contraseña incorrecta (o la copia está dañada)');
    }
  }

  static bool _startsWithMagic(List<int> d) {
    for (var i = 0; i < _magic.length; i++) {
      if (d[i] != _magic[i]) return false;
    }
    return true;
  }

  /// [largo nombre: 4][nombre utf8][largo datos: 8][datos] …
  static Uint8List pack(Map<String, List<int>> entries) {
    final b = BytesBuilder(copy: false);
    entries.forEach((name, bytes) {
      final n = utf8.encode(name);
      b
        ..add(_u32(n.length))
        ..add(n)
        ..add(_u64(bytes.length))
        ..add(bytes);
    });
    return b.takeBytes();
  }

  static Map<String, Uint8List> unpack(List<int> data) {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final out = <String, Uint8List>{};
    var i = 0;
    while (i < bytes.length) {
      if (i + 4 > bytes.length) throw const BackupException('La copia está dañada');
      final nl = _readU32(bytes, i);
      i += 4;
      if (nl > 1024 || i + nl + 8 > bytes.length) throw const BackupException('La copia está dañada');
      final name = utf8.decode(bytes.sublist(i, i + nl));
      i += nl;
      final dl = _readU64(bytes, i);
      i += 8;
      if (dl < 0 || i + dl > bytes.length) throw const BackupException('La copia está dañada');
      out[name] = Uint8List.sublistView(bytes, i, i + dl);
      i += dl;
    }
    return out;
  }

  static List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  static List<int> _u64(int v) => [..._u32((v ~/ 4294967296) & 0xffffffff), ..._u32(v & 0xffffffff)];

  static int _readU32(List<int> d, int o) => (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

  static int _readU64(List<int> d, int o) => _readU32(d, o) * 4294967296 + _readU32(d, o + 4);
}
