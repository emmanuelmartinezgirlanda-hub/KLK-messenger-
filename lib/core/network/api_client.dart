import 'dart:convert';

import 'package:http/http.dart' as http;

import '../crypto/signal_engine.dart';

/// Error devuelto por el servidor de KLK, con un mensaje listo para mostrar.
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;

  /// Datos extra del error (p. ej. regToken y attemptsLeft al pedir el PIN).
  final Map<String, dynamic> data;
  const ApiException(this.status, this.code, this.message, [this.data = const {}]);
  @override
  String toString() => message;
}

/// Cliente de la API HTTP de klk-server.
class ApiClient {
  ApiClient(String server, {this.token})
      : base = Uri.parse(server.endsWith('/') ? server.substring(0, server.length - 1) : server);

  final Uri base;
  final String? token;
  static const _timeout = Duration(seconds: 75); // el servidor gratuito tarda en "despertar"

  Uri _u(String path) {
    // "?…" va como consulta, no dentro de la ruta (si no, se convierte en %3F).
    final i = path.indexOf('?');
    if (i < 0) return base.replace(path: '${base.path}$path');
    return base.replace(path: '${base.path}${path.substring(0, i)}', query: path.substring(i + 1));
  }

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
      throw ApiException(res.statusCode, j['code'] as String? ?? 'error', j['message'] as String? ?? 'Error del servidor', j);
    } on FormatException {
      throw ApiException(res.statusCode, 'error', 'Error del servidor (${res.statusCode})');
    }
  }

  /// WebSocket: wss://servidor/v1/ws
  Uri get wsUri => _u('/v1/ws').replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');

  Future<void> requestCode(String phone) => _send('POST', '/v1/verification/request', {'phone': phone});

  /// Registra este móvil. Si la cuenta tiene PIN, el servidor responde
  /// `pin_required` con un `regToken`: se repite con [regToken] y [pin].
  Future<({String accountId, String token})> verify({
    required String phone,
    String code = '',
    String regToken = '',
    String pin = '',
    required String deviceName,
    required int registrationId,
    required List<int> identityKey,
  }) async {
    final j = await _send('POST', '/v1/verification/verify', {
      'phone': phone,
      if (code.isNotEmpty) 'code': code,
      if (regToken.isNotEmpty) 'regToken': regToken,
      if (pin.isNotEmpty) 'pin': pin,
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

  /// Sube un adjunto YA CIFRADO. Devuelve su id.
  Future<String> uploadAttachment(List<int> bytes) async {
    http.Response res;
    try {
      res = await http
          .post(_u('/v1/attachments'),
              headers: {'Content-Type': 'application/octet-stream', if (token != null) 'Authorization': 'Bearer $token'},
              body: bytes)
          .timeout(const Duration(minutes: 5));
    } on Exception {
      throw const ApiException(0, 'network', 'No se pudo subir el archivo. Revisa tu conexión.');
    }
    if (res.statusCode == 413) {
      throw const ApiException(413, 'too_large', 'El archivo es demasiado grande (máximo 64 MB).');
    }
    if (res.statusCode != 201) {
      throw ApiException(res.statusCode, 'upload', 'No se pudo subir el archivo (${res.statusCode}).');
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String;
  }

  /// Descarga un adjunto cifrado.
  Future<List<int>> downloadAttachment(String id) async {
    http.Response res;
    try {
      res = await http
          .get(_u('/v1/attachments/$id'), headers: {if (token != null) 'Authorization': 'Bearer $token'})
          .timeout(const Duration(minutes: 5));
    } on Exception {
      throw const ApiException(0, 'network', 'No se pudo descargar el archivo.');
    }
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'download', 'El archivo ya no está disponible.');
    }
    return res.bodyBytes;
  }

  /// Qué números de la lista usan KLK (devuelve número -> accountId).
  Future<Map<String, String>> lookupBatch(List<String> phones) async {
    final j = await _send('POST', '/v1/accounts/lookup-batch', {'phones': phones}) as Map<String, dynamic>;
    return (j['found'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v as String));
  }

  /// Denuncia a una cuenta. [messages] son los que el usuario decide adjuntar
  /// (el servidor no puede leer los mensajes por sí mismo).
  Future<void> report(String accountId, String reason, {List<String> messages = const []}) =>
      _send('POST', '/v1/reports', {'accountId': accountId, 'reason': reason, 'messages': messages});

  /// Comunidades por país, con el número real de miembros y si ya estoy dentro.
  Future<List<Map<String, dynamic>>> communities() async {
    final j = await _send('GET', '/v1/communities') as Map<String, dynamic>;
    return (j['communities'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  Future<void> joinCommunity(String id) => _send('POST', '/v1/communities/$id');
  Future<void> leaveCommunity(String id) => _send('DELETE', '/v1/communities/$id');

  /// Ids de las cuentas de una comunidad (sin números de teléfono).
  Future<List<String>> communityMembers(String id) async {
    final j = await _send('GET', '/v1/communities/$id/members') as Map<String, dynamic>;
    return (j['members'] as List? ?? const []).cast<String>();
  }

  // ---------- KLK Business ----------

  /// Mi perfil de negocio (null si no tengo).
  Future<Map<String, dynamic>?> myBusiness() async {
    try {
      return await _send('GET', '/v1/business/me') as Map<String, dynamic>;
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> saveBusiness(Map<String, dynamic> body) async =>
      await _send('PUT', '/v1/business/me', body) as Map<String, dynamic>;

  Future<void> deleteBusiness() => _send('DELETE', '/v1/business/me');

  /// Sube el logo o la foto de un producto (es pública). Devuelve su id.
  Future<String> uploadBusinessImage(List<int> bytes) async {
    http.Response res;
    try {
      res = await http
          .post(_u('/v1/business/me/images'),
              headers: {'Content-Type': 'application/octet-stream', if (token != null) 'Authorization': 'Bearer $token'},
              body: bytes)
          .timeout(const Duration(minutes: 2));
    } on Exception {
      throw const ApiException(0, 'network', 'No se pudo subir la foto. Revisa tu conexión.');
    }
    if (res.statusCode != 201) {
      var msg = 'No se pudo subir la foto (${res.statusCode}).';
      try {
        final j = jsonDecode(res.body);
        if (j is Map && j['message'] is String) msg = j['message'] as String;
        if (j is Map && j['error'] is Map && (j['error'] as Map)['message'] is String) {
          msg = (j['error'] as Map)['message'] as String;
        }
      } catch (_) {}
      throw ApiException(res.statusCode, 'upload', msg);
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String;
  }

  // ---------- KLK Mi Gente ----------

  Future<Map<String, dynamic>> genteSetProfile(String name, String photo, {bool rules = false}) async =>
      await _send('PUT', '/v1/gente/me', {'name': name, 'photo': photo, if (rules) 'rules': true})
          as Map<String, dynamic>;

  /// Bloquear (o desbloquear) a alguien en Mi Gente.
  Future<void> genteBlock(String accountId, bool on) =>
      _send(on ? 'PUT' : 'DELETE', '/v1/gente/blocks/${Uri.encodeComponent(accountId)}');

  /// A quién he bloqueado en Mi Gente.
  Future<List<Map<String, dynamic>>> genteBlocks() async {
    final j = await _send('GET', '/v1/gente/blocks') as Map<String, dynamic>;
    return (j['blocked'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  /// Dirección de una página del servidor (normas, privacidad…).
  String pageUrl(String path) => _u(path).toString();

  Future<List<Map<String, dynamic>>> genteFeed(
      {String country = '', String author = '', DateTime? before, bool sale = false}) async {
    final qs = Uri(queryParameters: {
      if (country.isNotEmpty) 'country': country,
      if (sale) 'sale': '1',
      if (author.isNotEmpty) 'author': author,
      if (before != null) 'before': before.toUtc().toIso8601String(),
    }).query;
    final j = await _send('GET', '/v1/gente/feed${qs.isEmpty ? '' : '?$qs'}') as Map<String, dynamic>;
    return (j['posts'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> genteCreatePost(String text, List<String> photos, String country,
          {double? price, String currency = ''}) async =>
      await _send('POST', '/v1/gente/posts', {
        'text': text,
        'photos': photos,
        'country': country,
        if (price != null) 'sale': {'price': price, 'currency': currency},
      }) as Map<String, dynamic>;

  /// Quien vende marca (o quita) «Vendido».
  Future<void> genteSold(String id, bool sold) =>
      _send(sold ? 'PUT' : 'DELETE', '/v1/gente/posts/${Uri.encodeComponent(id)}/sold');

  Future<Map<String, dynamic>> gentePost(String id) async =>
      await _send('GET', '/v1/gente/posts/${Uri.encodeComponent(id)}') as Map<String, dynamic>;

  Future<void> genteDeletePost(String id) => _send('DELETE', '/v1/gente/posts/${Uri.encodeComponent(id)}');

  Future<int> genteLike(String id, bool on) async {
    final j = await _send(on ? 'PUT' : 'DELETE', '/v1/gente/posts/${Uri.encodeComponent(id)}/like') as Map<String, dynamic>;
    return (j['likes'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> genteComments(String postId) async {
    final j = await _send('GET', '/v1/gente/posts/${Uri.encodeComponent(postId)}/comments') as Map<String, dynamic>;
    return (j['comments'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> genteAddComment(String postId, String text) async =>
      await _send('POST', '/v1/gente/posts/${Uri.encodeComponent(postId)}/comments', {'text': text})
          as Map<String, dynamic>;

  Future<void> genteDeleteComment(String id) => _send('DELETE', '/v1/gente/comments/${Uri.encodeComponent(id)}');

  Future<void> genteReport({String? postId, String? commentId, required String reason}) => _send(
      'POST',
      postId != null
          ? '/v1/gente/posts/${Uri.encodeComponent(postId)}/report'
          : '/v1/gente/comments/${Uri.encodeComponent(commentId!)}/report',
      {'reason': reason});

  /// Sube una foto de Mi Gente (es pública para la gente de KLK). Devuelve su id.
  Future<String> uploadGenteImage(List<int> bytes) async {
    http.Response res;
    try {
      res = await http
          .post(_u('/v1/gente/images'),
              headers: {'Content-Type': 'application/octet-stream', if (token != null) 'Authorization': 'Bearer $token'},
              body: bytes)
          .timeout(const Duration(minutes: 2));
    } on Exception {
      throw const ApiException(0, 'network', 'No se pudo subir la foto. Revisa tu conexión.');
    }
    if (res.statusCode != 201) {
      var msg = 'No se pudo subir la foto (${res.statusCode}).';
      try {
        final j = jsonDecode(res.body);
        if (j is Map && j['message'] is String) msg = j['message'] as String;
      } catch (_) {}
      throw ApiException(res.statusCode, 'upload', msg);
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String;
  }

  String genteImageUrl(String id) => _u('/v1/gente/img/$id').toString();

  /// Dirección pública de una foto del negocio.
  String businessImageUrl(String id) => _u('/v1/business/img/$id').toString();

  /// Página pública del negocio (para compartir por WhatsApp, Instagram…).
  String businessPageUrl(String accountId) => _u('/n/${Uri.encodeComponent(accountId)}').toString();

  Future<Map<String, dynamic>> business(String accountId) async =>
      await _send('GET', '/v1/business/${Uri.encodeComponent(accountId)}') as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> searchBusinesses({String q = '', String kind = '', String country = ''}) async {
    final qs = Uri(queryParameters: {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (kind.isNotEmpty) 'kind': kind,
      if (country.isNotEmpty) 'country': country,
    }).query;
    final j = await _send('GET', '/v1/business${qs.isEmpty ? '' : '?$qs'}') as Map<String, dynamic>;
    return (j['businesses'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  /// Avisos de KLK para todos (los más nuevos primero).
  Future<List<Map<String, dynamic>>> announcements() async {
    final j = await _send('GET', '/v1/announcements') as Map<String, dynamic>;
    return (j['announcements'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  // ---------- Cifrado Signal ----------

  /// Sube mi signed prekey y/o claves de un solo uso.
  Future<void> putKeys({
    ({int keyId, List<int> publicKey, List<int> signature})? signedPreKey,
    List<({int keyId, List<int> publicKey})> preKeys = const [],
  }) =>
      _send('PUT', '/v1/keys', {
        if (signedPreKey != null)
          'signedPreKey': {
            'keyId': signedPreKey.keyId,
            'publicKey': base64Encode(signedPreKey.publicKey),
            'signature': base64Encode(signedPreKey.signature),
          },
        'preKeys': [
          for (final k in preKeys) {'keyId': k.keyId, 'publicKey': base64Encode(k.publicKey)}
        ],
      });

  /// Cuántas claves de un solo uso me quedan en el servidor.
  Future<int> preKeyCount() async {
    final j = await _send('GET', '/v1/keys/count') as Map<String, dynamic>;
    return (j['count'] as num?)?.toInt() ?? 0;
  }

  /// Claves de una cuenta para empezar una sesión cifrada (gasta una prekey).
  Future<RemoteBundle> bundle(String accountId) async {
    final j = await _send('GET', '/v1/keys/$accountId') as Map<String, dynamic>;
    final devices = (j['devices'] as List).cast<Map<String, dynamic>>();
    final d = devices.firstWhere((d) => d['deviceId'] == 1, orElse: () => devices.first);
    final spk = (d['signedPreKey'] as Map).cast<String, dynamic>();
    final pk = (d['preKey'] as Map?)?.cast<String, dynamic>();
    return RemoteBundle(
      registrationId: (d['registrationId'] as num).toInt(),
      deviceId: (d['deviceId'] as num).toInt(),
      identityKey: base64Decode(d['identityKey'] as String),
      signedPreKeyId: (spk['keyId'] as num).toInt(),
      signedPreKey: base64Decode(spk['publicKey'] as String),
      signature: base64Decode(spk['signature'] as String),
      preKeyId: (pk?['keyId'] as num?)?.toInt(),
      preKey: pk == null ? null : base64Decode(pk['publicKey'] as String),
    );
  }

  // ---------- PIN de registro ----------

  Future<bool> pinEnabled() async {
    final j = await _send('GET', '/v1/account/pin') as Map<String, dynamic>;
    return j['enabled'] == true;
  }

  Future<void> setPin(String pin) => _send('PUT', '/v1/account/pin', {'pin': pin});

  Future<void> clearPin() => _send('DELETE', '/v1/account/pin');

  /// KLK Plus: ¿está activo y hasta cuándo?
  Future<Map<String, dynamic>> plusStatus() async => await _send('GET', '/v1/plus') as Map<String, dynamic>;

  /// Activa KLK Plus con un código (solo versiones de prueba).
  Future<Map<String, dynamic>> redeemPlus(String code) async =>
      await _send('POST', '/v1/plus/redeem', {'code': code}) as Map<String, dynamic>;

  /// Compras de KLK Plus hechas con Apple (el servidor comprueba la firma).
  Future<Map<String, dynamic>> plusApple(List<String> jws) async =>
      await _send('POST', '/v1/plus/apple', {'jws': jws}) as Map<String, dynamic>;

  /// Servidores para conectar llamadas (STUN y el «puente» TURN con clave temporal).
  Future<List<Map<String, dynamic>>> turnServers() async {
    final j = await _send('GET', '/v1/turn') as Map<String, dynamic>;
    return [
      for (final s in (j['iceServers'] as List? ?? const []))
        if (s is Map) Map<String, dynamic>.from(s),
    ];
  }

  /// Dónde avisar a este móvil cuando llegue un mensaje (el aviso no lleva el mensaje).
  Future<void> setPushToken(String platform, String token, String lang) =>
      _send('PUT', '/v1/push-token', {'platform': platform, 'token': token, 'lang': lang});

  Future<void> deletePushToken() => _send('DELETE', '/v1/push-token');

  /// Borra la cuenta y todo lo suyo del servidor.
  Future<void> deleteAccount() => _send('DELETE', '/v1/account');

  // ---------- Recargas a RD ----------

  /// Compañía del número y montos disponibles con su precio.
  Future<Map<String, dynamic>> topupQuote(String phone) async =>
      await _send('GET', '/v1/topups/quote?phone=${Uri.encodeQueryComponent(phone)}') as Map<String, dynamic>;

  /// Crea la recarga y devuelve {topup, payUrl}.
  Future<Map<String, dynamic>> createTopup(String phone, num amount) async =>
      await _send('POST', '/v1/topups', {'phone': phone, 'amount': amount}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> topup(String id) async {
    final j = await _send('GET', '/v1/topups/$id') as Map<String, dynamic>;
    return j['topup'] as Map<String, dynamic>;
  }
}
