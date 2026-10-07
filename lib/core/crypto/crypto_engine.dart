import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Motor de cifrado de extremo a extremo.
///
/// La app solo depende de esta interfaz. La implementación de producción será
/// vodozemac (Double Ratchet, Apache-2.0) vía puente Rust; ver README.md en
/// esta carpeta. Mientras tanto se usa [ProvisionalCrypto].
abstract class CryptoEngine {
  /// Clave pública de identidad en formato del servidor (33 bytes, 0x05 + X25519).
  List<int> get identityPublic;

  /// Clave "pre-firmada" que el servidor exige publicar.
  Future<({int keyId, List<int> publicKey, List<int> signature})> signedPreKey();

  /// Cifra [plaintext] para el destinatario cuya identidad es [peerIdentity].
  Future<List<int>> encrypt(List<int> plaintext, List<int> peerIdentity);

  /// Descifra. Devuelve el texto y la identidad que dijo tener el remitente.
  Future<({List<int> plaintext, List<int> senderIdentity})> decrypt(List<int> sealed);
}

/// Cifrado PROVISIONAL "KLK-v0" (no auditado; sustituir antes del lanzamiento).
///
/// Cada mensaje:
///  1. Genera una clave efímera X25519.
///  2. secreto = HKDF-SHA256( DH(efímera, IK_dest) || DH(IK_remitente, IK_dest) )
///  3. Cifra con AES-256-GCM.
///
/// Da confidencialidad y autentica al remitente (el segundo DH exige su clave
/// privada). NO da secreto hacia delante completo ni ratchet: eso lo aporta
/// el Double Ratchet de vodozemac.
class ProvisionalCrypto implements CryptoEngine {
  ProvisionalCrypto._(this._identity, this._identityPub);

  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _info = utf8.encode('KLK-v0');

  final SimpleKeyPair _identity;
  final List<int> _identityPub; // 32 bytes

  /// Crea el motor a partir de la semilla privada (32 bytes).
  static Future<ProvisionalCrypto> fromSeed(List<int> seed) async {
    final kp = await _x25519.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return ProvisionalCrypto._(kp, pub.bytes);
  }

  @override
  List<int> get identityPublic => [0x05, ..._identityPub];

  @override
  Future<({int keyId, List<int> publicKey, List<int> signature})> signedPreKey() async {
    // El servidor exige una signedPreKey para listar el dispositivo.
    // En KLK-v0 no se usa: se publica la propia identidad y una firma vacía.
    // vodozemac publicará aquí sus claves de un solo uso firmadas.
    return (keyId: 1, publicKey: identityPublic, signature: List<int>.filled(64, 0));
  }

  @override
  Future<List<int>> encrypt(List<int> plaintext, List<int> peerIdentity) async {
    final peer = SimplePublicKey(_strip(peerIdentity), type: KeyPairType.x25519);
    final eph = await _x25519.newKeyPair();
    final ephPub = (await eph.extractPublicKey()).bytes;

    final key = await _deriveKey(
      await _x25519.sharedSecretKey(keyPair: eph, remotePublicKey: peer),
      await _x25519.sharedSecretKey(keyPair: _identity, remotePublicKey: peer),
      ephPub,
    );
    final box = await _aes.encrypt(plaintext, secretKey: key, nonce: _aes.newNonce());
    final envelope = {
      'v': 0,
      's': base64Encode(identityPublic),
      'e': base64Encode(ephPub),
      'n': base64Encode(box.nonce),
      'c': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    };
    return utf8.encode(jsonEncode(envelope));
  }

  @override
  Future<({List<int> plaintext, List<int> senderIdentity})> decrypt(List<int> sealed) async {
    final j = jsonDecode(utf8.decode(sealed)) as Map<String, dynamic>;
    if (j['v'] != 0) throw const FormatException('versión de cifrado desconocida');
    final senderIdentity = base64Decode(j['s'] as String);
    final ephPub = base64Decode(j['e'] as String);

    final key = await _deriveKey(
      await _x25519.sharedSecretKey(
          keyPair: _identity, remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519)),
      await _x25519.sharedSecretKey(
          keyPair: _identity,
          remotePublicKey: SimplePublicKey(_strip(senderIdentity), type: KeyPairType.x25519)),
      ephPub,
    );
    final box = SecretBox(
      base64Decode(j['c'] as String),
      nonce: base64Decode(j['n'] as String),
      mac: Mac(base64Decode(j['m'] as String)),
    );
    final plaintext = await _aes.decrypt(box, secretKey: key);
    return (plaintext: plaintext, senderIdentity: senderIdentity);
  }

  Future<SecretKey> _deriveKey(SecretKey dh1, SecretKey dh2, List<int> salt) async {
    final ikm = [...await dh1.extractBytes(), ...await dh2.extractBytes()];
    return _hkdf.deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: _info);
  }

  static List<int> _strip(List<int> k) => k.length == 33 && k[0] == 0x05 ? k.sublist(1) : k;
}
