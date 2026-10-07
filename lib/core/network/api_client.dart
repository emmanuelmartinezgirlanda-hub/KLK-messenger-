import 'dart:convert';

import 'package:http/http.dart' as http;

/// Error devuelto por el servidor de KLK, con un mensaje listo para mostrar.
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  const ApiException(this.status, this.code, this.message);
  @override
  String toString() => message;
}

/// Cliente de la API HTTP de klk-server.
class ApiClient {
  ApiClient(String server, {this.token})
      : base = Uri.parse(server.endsWith('/') ? server.substring(0, server.length - 1) : server);

  final Uri base;
  final String? token;
  static const _timeout = Duration(seconds: 15);

  Uri _u(String path) => base.replace(path: '${base.path}$path');

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, _u(path))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    late http.Response res;
    try {
      res = await http.Response.fromStream(await req.send().timeout(_timeout));
    } on Exception {
      throw const ApiException(0, 'network', 'No hay conexión con el servidor. Revisa tu internet.');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    }
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      throw ApiException(res.statusCode, j['code'] as String? ?? 'error', j['message'] as String? ?? 'Error del servidor');
    } on FormatException {
      throw ApiException(res.statusCode, 'error', 'Error del servidor (${res.statusCode})');
    }
  }

  /// WebSocket: wss://servidor/v1/ws
  Uri get wsUri => _u('/v1/ws').replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');

  Future<void> requestCode(String phone) => _send('POST', '/v1/verification/request', {'phone': phone});

  Future<({String accountId, String token})> verify({
    required String phone,
    required String code,
    required String deviceName,
    required int registrationId,
    required List<int> identityKey,
  }) async {
    final j = await _send('POST', '/v1/verification/verify', {
      'phone': phone,
      'code': code,
      'deviceName': deviceName,
      'registrationId': registrationId,
      'identityKey': base64Encode(identityKey),
    }) as Map<String, dynamic>;
    return (accountId: j['accountId'] as String, token: j['token'] as String);
  }

  Future<void> putSignedPreKey(int keyId, List<int> publicKey, List<int> signature) =>
      _send('PUT', '/v1/keys', {
        'signedPreKey': {
          'keyId': keyId,
          'publicKey': base64Encode(publicKey),
          'signature': base64Encode(signature),
        },
      });

  Future<String> lookup(String phone) async {
    final j = await _send('POST', '/v1/accounts/lookup', {'phone': phone}) as Map<String, dynamic>;
    return j['accountId'] as String;
  }

  /// Identidad pública del dispositivo principal de una cuenta.
  Future<List<int>> identityOf(String accountId) async {
    final j = await _send('GET', '/v1/keys/$accountId') as Map<String, dynamic>;
    final devices = (j['devices'] as List).cast<Map<String, dynamic>>();
    final primary = devices.firstWhere((d) => d['deviceId'] == 1, orElse: () => devices.first);
    return base64Decode(primary['identityKey'] as String);
  }
}
