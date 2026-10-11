import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Almacén clave → bytes donde se guardan las claves y sesiones de Signal.
/// En la app es una tabla de la base de datos cifrada (SQLCipher).
abstract class SignalKeyValue {
  Future<Uint8List?> get(String key);
  Future<void> put(String key, List<int> value);
  Future<void> delete(String key);
  Future<List<String>> keys(String prefix);
}

/// Almacén en memoria (para tests).
class MemorySignalKeyValue implements SignalKeyValue {
  final _m = <String, Uint8List>{};
  @override
  Future<Uint8List?> get(String key) async => _m[key];
  @override
  Future<void> put(String key, List<int> value) async => _m[key] = Uint8List.fromList(value);
  @override
  Future<void> delete(String key) async => _m.remove(key);
  @override
  Future<List<String>> keys(String prefix) async => _m.keys.where((k) => k.startsWith(prefix)).toList();
}

/// Claves que el servidor entrega para empezar a hablar con alguien (X3DH).
class RemoteBundle {
  final int registrationId;
  final int deviceId;
  final List<int> identityKey;
  final int signedPreKeyId;
  final List<int> signedPreKey;
  final List<int> signature;
  final int? preKeyId;
  final List<int>? preKey;

  const RemoteBundle({
    required this.registrationId,
    required this.deviceId,
    required this.identityKey,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signature,
    this.preKeyId,
    this.preKey,
  });

  /// Las versiones viejas de KLK publicaban una firma vacía (todo ceros):
  /// ese contacto aún no tiene el cifrado nuevo.
  bool get isLegacy => signature.every((b) => b == 0);
}

/// Cifrado de punta a punta con el Signal Protocol (X3DH + Double Ratchet),
/// el mismo que usan Signal y WhatsApp: cada mensaje lleva una clave nueva,
/// así que robar una clave no abre los mensajes de antes ni los de después.
class SignalEngine {
  SignalEngine._(this._kv, this._identity, this._regId) {
    _store = _KlkSignalStore(this);
  }

  final SignalKeyValue _kv;
  final IdentityKeyPair _identity;
  final int _regId;
  late final _KlkSignalStore _store;

  /// Cada mensaje del Double Ratchet va en un sobre de este tipo.
  static const typeWhisper = CiphertextMessage.whisperType; // 2
  static const typePreKey = CiphertextMessage.prekeyType; // 3

  static const _signedPreKeyMaxAge = Duration(days: 30);

  /// Abre el motor a partir de la semilla de identidad (32 bytes) de siempre:
  /// la clave pública no cambia, así que la cuenta sigue siendo la misma.
  static Future<SignalEngine> open({required List<int> seed, required SignalKeyValue kv}) async {
    final identity = generateIdentityKeyPairFromPrivate(seed);
    final saved = await kv.get('meta:regId');
    int regId;
    if (saved == null) {
      regId = generateRegistrationId(false);
      await kv.put('meta:regId', utf8.encode('$regId'));
    } else {
      regId = int.parse(utf8.decode(saved));
    }
    return SignalEngine._(kv, identity, regId);
  }

  /// Clave pública de identidad (33 bytes: 0x05 + X25519), la que conoce el servidor.
  List<int> get identityPublic => _identity.getPublicKey().serialize();
  int get registrationId => _regId;

  // Las operaciones se hacen de una en una: dos mensajes a la vez no deben
  // avanzar la misma sesión al mismo tiempo.
  Future<void> _tail = Future.value();
  Future<T> _locked<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  // ---------- Claves que publico ----------

  /// Mi "signed prekey" vigente. Se renueva cada 30 días.
  /// [rotated] = true si es nueva y hay que subirla al servidor.
  Future<({int keyId, List<int> publicKey, List<int> signature, bool rotated})> signedPreKey() => _locked(() async {
        SignedPreKeyRecord? newest;
        for (final k in await _kv.keys('spk:')) {
          final b = await _kv.get(k);
          if (b == null) continue;
          final r = SignedPreKeyRecord.fromSerialized(b);
          if (newest == null || r.id > newest.id) newest = r;
        }
        final now = DateTime.now();
        final fresh = newest != null &&
            now.difference(DateTime.fromMillisecondsSinceEpoch(newest.timestamp.toInt())) < _signedPreKeyMaxAge;
        var rotated = false;
        if (!fresh) {
          final id = ((newest?.id ?? 0) % 0xFFFFFF) + 1;
          newest = generateSignedPreKey(_identity, id);
          await _kv.put('spk:$id', newest.serialize());
          rotated = true;
          // Las antiguas se guardan un tiempo para los mensajes que aún vengan de camino.
          for (final k in await _kv.keys('spk:')) {
            if (k == 'spk:$id') continue;
            final b = await _kv.get(k);
            if (b == null) continue;
            final r = SignedPreKeyRecord.fromSerialized(b);
            if (now.difference(DateTime.fromMillisecondsSinceEpoch(r.timestamp.toInt())) > _signedPreKeyMaxAge * 2) {
              await _kv.delete(k);
            }
          }
        }
        final spk = newest!;
        return (
          keyId: spk.id,
          publicKey: spk.getKeyPair().publicKey.serialize().toList(),
          signature: spk.signature.toList(),
          rotated: rotated,
        );
      });

  /// Genera [count] claves de un solo uso nuevas (se suben al servidor).
  Future<List<({int keyId, List<int> publicKey})>> newPreKeys(int count) => _locked(() async {
        final saved = await _kv.get('meta:nextPreKey');
        final start = saved == null ? 1 : int.parse(utf8.decode(saved));
        final records = generatePreKeys(start, count);
        for (final r in records) {
          await _kv.put('pk:${r.id}', r.serialize());
        }
        final next = ((start + count - 1) % 0xFFFFFE) + 1;
        await _kv.put('meta:nextPreKey', utf8.encode('$next'));
        return [for (final r in records) (keyId: r.id, publicKey: r.getKeyPair().publicKey.serialize().toList())];
      });

  // ---------- Sesiones ----------

  SignalProtocolAddress _addr(String accountId) => SignalProtocolAddress(accountId, 1);

  Future<bool> hasSession(String accountId) => _locked(() async {
        if (!await _store.containsSession(_addr(accountId))) return false;
        final rec = await _store.loadSession(_addr(accountId));
        return rec.sessionState.hasSenderChain();
      });

  /// Empieza una sesión con las claves que dio el servidor (X3DH).
  Future<void> startSession(String accountId, RemoteBundle b) => _locked(() async {
        final bundle = PreKeyBundle(
          b.registrationId,
          b.deviceId,
          b.preKeyId,
          b.preKey == null ? null : Curve.decodePoint(Uint8List.fromList(b.preKey!), 0),
          b.signedPreKeyId,
          Curve.decodePoint(Uint8List.fromList(b.signedPreKey), 0),
          Uint8List.fromList(b.signature),
          IdentityKey(Curve.decodePoint(Uint8List.fromList(b.identityKey), 0)),
        );
        await SessionBuilder(_store, _store, _store, _store, _addr(accountId)).processPreKeyBundle(bundle);
      });

  /// Cifra para [accountId]. Hace falta una sesión ([startSession]).
  Future<({int type, List<int> body})> encrypt(String accountId, List<int> plaintext) => _locked(() async {
        final cipher = SessionCipher(_store, _store, _store, _store, _addr(accountId));
        final msg = await cipher.encrypt(Uint8List.fromList(plaintext));
        return (type: msg.getType(), body: msg.serialize().toList());
      });

  /// Descifra un sobre de [accountId]. Devuelve el texto y la identidad del remitente.
  Future<({List<int> plaintext, List<int> senderIdentity})> decrypt(String accountId, int type, List<int> body) =>
      _locked(() async {
        final addr = _addr(accountId);
        final cipher = SessionCipher(_store, _store, _store, _store, addr);
        final bytes = Uint8List.fromList(body);
        final Uint8List plain;
        if (type == typePreKey) {
          plain = await cipher.decrypt(PreKeySignalMessage(bytes));
        } else if (type == typeWhisper) {
          plain = await cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
        } else {
          throw FormatException('tipo de sobre desconocido: $type');
        }
        final id = await _store.getIdentity(addr);
        return (plaintext: plain.toList(), senderIdentity: id?.serialize().toList() ?? const <int>[]);
      });

  /// Borra la sesión con alguien (p. ej. si reinstaló y hay que empezar de nuevo).
  Future<void> resetSession(String accountId) => _locked(() => _store.deleteSession(_addr(accountId)));

  /// Número de seguridad (60 cifras) para comprobar en persona que nadie
  /// está en medio. Los dos móviles ven el mismo número.
  String safetyNumber(String myId, String theirId, List<int> theirIdentity) {
    final fp = NumericFingerprintGenerator(5200).createFor(
      1,
      Uint8List.fromList(utf8.encode(myId)),
      _identity.getPublicKey(),
      Uint8List.fromList(utf8.encode(theirId)),
      IdentityKey(Curve.decodePoint(Uint8List.fromList(theirIdentity), 0)),
    );
    return fp.displayableFingerprint.getDisplayText();
  }
}

/// Las claves y sesiones de Signal, guardadas en la base de datos cifrada.
class _KlkSignalStore extends SignalProtocolStore {
  _KlkSignalStore(this._e);
  final SignalEngine _e;
  SignalKeyValue get _kv => _e._kv;

  String _s(SignalProtocolAddress a) => 'session:${a.getName()}:${a.getDeviceId()}';

  // ---- Identidad ----
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _e._identity;

  @override
  Future<int> getLocalRegistrationId() async => _e._regId;

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) return false;
    final key = 'identity:${address.getName()}';
    final old = await _kv.get(key);
    final now = identityKey.serialize();
    if (old != null && _same(old, now)) return false;
    await _kv.put(key, now);
    return true;
  }

  /// Como WhatsApp: se confía en la clave nueva y la app avisa en el chat
  /// ("la clave de seguridad de este contacto cambió").
  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async =>
      identityKey != null;

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final b = await _kv.get('identity:${address.getName()}');
    return b == null ? null : IdentityKey.fromBytes(b, 0);
  }

  // ---- Prekeys de un solo uso ----
  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final b = await _kv.get('pk:$preKeyId');
    if (b == null) throw InvalidKeyIdException('No existe la prekey $preKeyId');
    return PreKeyRecord.fromBuffer(b);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) => _kv.put('pk:$preKeyId', record.serialize());

  @override
  Future<bool> containsPreKey(int preKeyId) async => await _kv.get('pk:$preKeyId') != null;

  @override
  Future<void> removePreKey(int preKeyId) => _kv.delete('pk:$preKeyId');

  // ---- Signed prekeys ----
  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final b = await _kv.get('spk:$signedPreKeyId');
    if (b == null) throw InvalidKeyIdException('No existe la signed prekey $signedPreKeyId');
    return SignedPreKeyRecord.fromSerialized(b);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final out = <SignedPreKeyRecord>[];
    for (final k in await _kv.keys('spk:')) {
      final b = await _kv.get(k);
      if (b != null) out.add(SignedPreKeyRecord.fromSerialized(b));
    }
    return out;
  }

  @override
  Future<void> storeSignedPreKey(int signedPreKeyId, SignedPreKeyRecord record) =>
      _kv.put('spk:$signedPreKeyId', record.serialize());

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async => await _kv.get('spk:$signedPreKeyId') != null;

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) => _kv.delete('spk:$signedPreKeyId');

  // ---- Sesiones ----
  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final b = await _kv.get(_s(address));
    return b == null ? SessionRecord() : SessionRecord.fromSerialized(b);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final out = <int>[];
    for (final k in await _kv.keys('session:$name:')) {
      final d = int.tryParse(k.split(':').last);
      if (d != null && d != 1) out.add(d);
    }
    return out;
  }

  @override
  Future<void> storeSession(SignalProtocolAddress address, SessionRecord record) =>
      _kv.put(_s(address), record.serialize());

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async => await _kv.get(_s(address)) != null;

  @override
  Future<void> deleteSession(SignalProtocolAddress address) => _kv.delete(_s(address));

  @override
  Future<void> deleteAllSessions(String name) async {
    for (final k in await _kv.keys('session:$name:')) {
      await _kv.delete(k);
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
