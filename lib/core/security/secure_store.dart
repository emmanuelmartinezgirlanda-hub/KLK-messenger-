import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final secureStoreProvider = Provider<SecureStore>((_) => SecureStore());

/// Sesión del usuario en este dispositivo.
class Session {
  final String phone; // E.164
  final String server; // vacío = modo demo
  final String accountId;
  final String token;

  const Session({required this.phone, required this.server, required this.accountId, required this.token});

  bool get isDemo => server.isEmpty;

  Map<String, dynamic> toJson() =>
      {'phone': phone, 'server': server, 'accountId': accountId, 'token': token};

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        phone: j['phone'] as String,
        server: j['server'] as String? ?? '',
        accountId: j['accountId'] as String,
        token: j['token'] as String? ?? '',
      );
}

/// Envoltorio sobre Keychain (iOS) / Android Keystore.
/// Guarda la clave maestra de la base de datos, la sesión y las claves privadas.
class SecureStore {
  static const _dbKeyName = 'klk.db.master_key';
  static const _sessionKey = 'klk.session';
  static const _identityKey = 'klk.identity.private';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  /// Clave maestra de SQLCipher (256 bits). Se genera la primera vez.
  Future<String> databaseKey() async {
    final existing = await _storage.read(key: _dbKeyName);
    if (existing != null) return existing;
    final key = base64UrlEncode(randomBytes(32));
    await _storage.write(key: _dbKeyName, value: key);
    return key;
  }

  /// Al restaurar una copia: la base de datos restaurada usa su propia clave.
  Future<void> setDatabaseKey(String key) => _storage.write(key: _dbKeyName, value: key);

  Future<Session?> loadSession() async {
    final s = await _storage.read(key: _sessionKey);
    return s == null ? null : Session.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  Future<void> saveSession(Session s) => _storage.write(key: _sessionKey, value: jsonEncode(s.toJson()));

  /// Semilla privada de la clave de identidad (32 bytes, base64).
  Future<String?> identitySeed() => _storage.read(key: _identityKey);
  Future<void> saveIdentitySeed(String b64) => _storage.write(key: _identityKey, value: b64);

  /// Botón de pánico: destruye todas las claves.
  /// Sin la clave maestra, la base de datos cifrada queda irrecuperable.
  Future<void> panicWipe() => _storage.deleteAll();
}

List<int> randomBytes(int n) {
  final rnd = Random.secure();
  return List<int>.generate(n, (_) => rnd.nextInt(256));
}
