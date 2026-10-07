import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import '../../core/config.dart';
import '../../core/crypto/crypto_engine.dart';
import '../../core/database/local_db.dart';
import '../../core/media/media_store.dart';
import '../../core/network/api_client.dart';
import '../../core/network/presence_gate.dart';
import '../../core/security/secure_store.dart';
import '../../core/util/phone.dart';
import 'demo_data.dart';
import 'models.dart';

final appProvider = ChangeNotifierProvider<AppController>((ref) => AppController(ref));

enum AppPhase { loading, onboarding, ready }

/// Estado global de la app: sesión, chats, mensajes y conexión con el servidor.
///
/// En modo demo (sin servidor) todo funciona en local con respuestas de ejemplo.
class AppController extends ChangeNotifier {
  AppController(this._ref) {
    _init();
  }

  final Ref _ref;
  static const _uuid = Uuid();

  AppPhase phase = AppPhase.loading;
  Session? session;
  bool online = false;
  List<Chat> chats = [];
  String? openChatId;
  Profile profile = const Profile();
  static const _profileKey = 'klk.profile';

  LocalDb? _db;
  CryptoEngine? _crypto;
  ApiClient? _api;
  IOWebSocketChannel? _ws;
  Timer? _retry;
  Timer? _tick;
  int _backoff = 1;
  Future<void> _queue = Future.value();
  final Map<String, String> _outbox = {}; // ref -> frame, hasta recibir "sent"
  final Map<String, List<Message>> _messages = {};
  final Map<String, DateTime> _typingUntil = {};
  final Map<String, DateTime> _recordingUntil = {};
  final Set<String> _downloading = {};
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  // Datos del registro en curso
  String? pendingPhone;
  String pendingServer = '';

  SecureStore get _store => _ref.read(secureStoreProvider);
  PresenceGate get _gate => _ref.read(presenceGateProvider);
  bool get isDemo => session?.isDemo ?? true;

  List<Message> messagesFor(String chatId) => _messages[chatId] ?? const [];
  bool isTyping(String chatId) => (_typingUntil[chatId]?.isAfter(DateTime.now())) ?? false;
  bool isRecording(String chatId) => (_recordingUntil[chatId]?.isAfter(DateTime.now())) ?? false;

  // ---------- Arranque ----------

  Future<void> _init() async {
    try {
      session = await _store.loadSession();
      if (session == null) {
        phase = AppPhase.onboarding;
      } else {
        await _openSession();
        phase = AppPhase.ready;
      }
    } catch (e) {
      debugPrint('Error al arrancar: $e');
      phase = AppPhase.onboarding;
    }
    notifyListeners();
  }

  Future<void> _openSession() async {
    _db = await LocalDb.open(await _store.databaseKey());
    final savedProfile = await _store.read(_profileKey);
    if (savedProfile != null) profile = Profile.fromJson(jsonDecode(savedProfile) as Map<String, dynamic>);
    _crypto = await _loadCrypto();
    if (session!.isDemo) {
      if ((await _db!.chats()).isEmpty) await seedDemo(_db!);
    } else {
      _api = ApiClient(session!.server, token: session!.token);
      unawaited(_connect());
    }
    await _db!.settleScheduled(DateTime.now());
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 10), (_) => _onTick());
    await _reloadChats();
  }

  Future<CryptoEngine> _loadCrypto() async {
    var seed = await _store.identitySeed();
    if (seed == null) {
      seed = base64Encode(randomBytes(32));
      await _store.saveIdentitySeed(seed);
    }
    return ProvisionalCrypto.fromSeed(base64Decode(seed));
  }

  Future<void> _onTick() async {
    final db = _db;
    if (db == null) return;
    await db.settleScheduled(DateTime.now());
    await _reloadChats();
  }

  /// La app vuelve a primer plano: iOS cierra los sockets en segundo plano.
  void onResume() {
    if (phase == AppPhase.ready && !isDemo && !online) {
      _backoff = 1;
      unawaited(_connect());
    }
  }

  // ---------- Registro ----------

  Future<void> requestCode(String phone, String server) async {
    pendingPhone = phone;
    pendingServer = server.trim();
    if (pendingServer.isNotEmpty) {
      await ApiClient(pendingServer).requestCode(phone);
    }
  }

  Future<void> verify(String code) async {
    final phone = pendingPhone!;
    if (pendingServer.isEmpty) {
      if (code != KlkConfig.demoCode) {
        throw const ApiException(403, 'bad_code', 'Código incorrecto. En modo demo el código es 123456.');
      }
      session = Session(phone: phone, server: '', accountId: 'demo-me', token: '');
    } else {
      final crypto = await _loadCrypto();
      final api = ApiClient(pendingServer);
      final res = await api.verify(
        phone: phone,
        code: code,
        deviceName: Platform.isIOS ? 'iPhone' : 'Android',
        registrationId: Random.secure().nextInt(16380) + 1,
        identityKey: crypto.identityPublic,
      );
      final spk = await crypto.signedPreKey();
      await ApiClient(pendingServer, token: res.token).putSignedPreKey(spk.keyId, spk.publicKey, spk.signature);
      session = Session(phone: phone, server: pendingServer, accountId: res.accountId, token: res.token);
    }
    await _store.saveSession(session!);
    await _openSession();
    phase = AppPhase.ready;
    notifyListeners();
  }

  // ---------- Conexión ----------

  Future<void> _connect() async {
    if (session == null || session!.isDemo || _ws != null) return;
    _retry?.cancel();
    try {
      final ch = IOWebSocketChannel.connect(
        _api!.wsUri,
        headers: {'Authorization': 'Bearer ${session!.token}'},
        pingInterval: const Duration(seconds: 25),
      );
      await ch.ready;
      _ws = ch;
      online = true;
      _backoff = 1;
      notifyListeners();
      ch.stream.listen(
        (data) => _queue = _queue.then((_) => _onFrame(data as String)).catchError((Object e) {
          debugPrint('frame: $e');
        }),
        onDone: _onDisconnect,
        onError: (Object _) => _onDisconnect(),
        cancelOnError: true,
      );
      for (final frame in _outbox.values) {
        ch.sink.add(frame);
      }
      unawaited(_resumeDownloads());
    } catch (e) {
      debugPrint('WebSocket: $e');
      _onDisconnect();
    }
  }

  void _onDisconnect() {
    _ws = null;
    if (online) {
      online = false;
      notifyListeners();
    }
    if (session == null || session!.isDemo || (_retry?.isActive ?? false)) return;
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = min(_backoff * 2, 30);
  }

  Future<void> _onFrame(String data) async {
    final f = jsonDecode(data) as Map<String, dynamic>;
    switch (f['t']) {
      case 'msg':
        await _onEnvelope(f);
      case 'sent':
        {
          final sentRef = f['ref'] as String? ?? '';
          _outbox.remove(sentRef);
          if (f['scheduled'] != true && !sentRef.startsWith('x-')) {
            await _db!.advanceStatus([sentRef], MessageStatus.sent);
            await _refresh();
          }
        }
      case 'error':
        {
          final errRef = f['ref'] as String? ?? '';
          _outbox.remove(errRef);
          debugPrint('Servidor: ${f['code']} ${f['message']}');
          if (errRef.isNotEmpty && !errRef.startsWith('x-')) {
            await _db!.setStatus(errRef, MessageStatus.failed);
            await _refresh();
          }
        }
    }
  }

  Future<void> _onEnvelope(Map<String, dynamic> f) async {
    final from = f['from'] as String;
    final ephemeral = f['ephemeral'] == true;
    try {
      final opened = await _crypto!.decrypt(base64Decode(f['content'] as String));
      final p = Payload.decode(opened.plaintext);
      final identity = base64Encode(opened.senderIdentity);
      final db = _db!;

      var chat = await db.chat(from);
      if (chat == null) {
        if (p.kind != 'text') return;
        final phone = p.senderPhone ?? '';
        chat = Chat(
          id: from,
          title: phone.isEmpty ? 'Contacto nuevo' : prettyPhone(phone),
          phone: phone,
          identityKey: identity,
          updatedAt: DateTime.now(),
        );
        await db.upsertChat(chat);
        await _reloadChats();
        unawaited(_broadcastProfile(from));
      } else if (chat.identityKey == null) {
        await db.setIdentity(from, identity);
      } else if (chat.identityKey != identity) {
        // Primera clave vista = de confianza. Si cambia, se avisa al usuario.
        await db.setIdentity(from, identity);
        await db.addMessage(Message(
          id: _uuid.v4(),
          chatId: from,
          kind: MessageKind.system,
          body: 'La clave de seguridad de este contacto cambió. Puede que haya reinstalado KLK.',
          status: MessageStatus.read,
          createdAt: DateTime.now(),
        ));
      }

      switch (p.kind) {
        case 'text':
          {
          final id = p.id;
          if (id != null && !await db.hasMessage(id)) {
            final ts = DateTime.tryParse(f['ts'] as String? ?? '')?.toLocal() ?? DateTime.now();
            final media = p.media == null ? null : MessageMedia.fromJson(p.media!);
            final msg = Message(id: id, chatId: from, kind: MessageKind.incoming, body: p.text ?? '',
                status: MessageStatus.delivered, createdAt: ts, media: media);
            await db.addMessage(msg, countUnread: openChatId != from);
            if (media?.needsDownload ?? false) unawaited(_downloadMedia(msg));
            _typingUntil.remove(from);
            _recordingUntil.remove(from);
            await _sendEncrypted(from, Payload(kind: 'delivered', ids: [id]), ref: 'x-${_uuid.v4()}');
            if (openChatId == from) await _sendReadReceipts(from);
          }
          }
        case 'typing' || 'recording':
          {
            final target = p.kind == 'typing' ? _typingUntil : _recordingUntil;
            if (p.on == true) {
              target[from] = DateTime.now().add(const Duration(seconds: 6));
              Timer(const Duration(seconds: 6, milliseconds: 100), notifyListeners);
            } else {
              target.remove(from);
            }
            notifyListeners();
          }
        case 'profile':
          {
            final name = (p.text ?? '').trim();
            final current = await db.chat(from);
            // Si el chat aún muestra solo el número, usa el nombre que el contacto eligió.
            if (name.isNotEmpty && current != null &&
                (current.title == prettyPhone(current.phone) || current.title == 'Contacto nuevo')) {
              await db.setTitle(from, name);
            }
            final photo = p.media == null ? null : MessageMedia.fromJson(p.media!);
            if (photo == null) {
              await db.setAvatar(from, null);
            } else if (photo.needsDownload) {
              unawaited(() async {
                try {
                  final path = await _fetchMedia(photo);
                  await _db?.setAvatar(from, path);
                  await _refresh();
                } catch (e) {
                  debugPrint('Foto de perfil: $e');
                }
              }());
            }
          }
        case 'delivered':
          await db.advanceStatus(p.ids ?? const [], MessageStatus.delivered);
        case 'read':
          await db.advanceStatus(p.ids ?? const [], MessageStatus.read);
      }
    } catch (e) {
      debugPrint('No se pudo procesar un mensaje: $e');
    } finally {
      // Confirmar siempre: un sobre que no se puede descifrar no debe repetirse sin fin.
      if (!ephemeral) _ws?.sink.add(jsonEncode({'t': 'ack', 'id': f['id']}));
    }
    await _refresh();
  }

  Future<void> _sendEncrypted(String chatId, Payload p,
      {required String ref, DateTime? deliverAt, bool ephemeral = false}) async {
    final chat = await _db!.chat(chatId);
    final key = chat?.identityKey;
    if (key == null) throw StateError('Sin clave del contacto');
    final sealed = await _crypto!.encrypt(p.encode(), base64Decode(key));
    final frame = jsonEncode({
      't': 'send',
      'ref': ref,
      'to': chatId,
      'messages': [
        {'device': 1, 'type': 1, 'content': base64Encode(sealed)}
      ],
      if (deliverAt != null) 'deliverAt': deliverAt.toUtc().toIso8601String(),
      if (ephemeral) 'ephemeral': true,
    });
    if (!ephemeral) _outbox[ref] = frame;
    _ws?.sink.add(frame);
  }

  // ---------- Acciones del usuario ----------

  Future<void> sendText(String chatId, String text, {DateTime? at}) async {
    final scheduled = at != null && at.isAfter(DateTime.now());
    final m = Message(
      id: _uuid.v4(),
      chatId: chatId,
      kind: MessageKind.outgoing,
      body: text,
      status: scheduled ? MessageStatus.scheduled : MessageStatus.sending,
      createdAt: scheduled ? at : DateTime.now(),
      scheduledFor: scheduled ? at : null,
    );
    await _db!.addMessage(m);
    await _refresh();

    if (isDemo) {
      if (!scheduled) _simulateReply(chatId, m.id);
      return;
    }
    try {
      await _sendEncrypted(chatId,
          Payload(kind: 'text', id: m.id, text: text, senderPhone: session!.phone),
          ref: m.id, deliverAt: scheduled ? at : null);
    } catch (e) {
      await _db!.setStatus(m.id, MessageStatus.failed);
      await _refresh();
    }
  }

  /// Envía una foto, vídeo, nota de voz, documento o ubicación.
  ///
  /// El archivo se cifra en el móvil con una clave propia, se sube cifrado y la
  /// clave viaja dentro del mensaje (cifrado de punta a punta).
  Future<void> sendMedia(String chatId, MessageMedia media, {String caption = ''}) async {
    final m = Message(
      id: _uuid.v4(),
      chatId: chatId,
      kind: MessageKind.outgoing,
      body: caption,
      status: MessageStatus.sending,
      createdAt: DateTime.now(),
      media: media,
    );
    await _db!.addMessage(m);
    await _refresh();

    if (isDemo) {
      _simulateReply(chatId, m.id);
      return;
    }
    try {
      var wire = media;
      final path = media.localPath;
      if (media.type != MediaType.location && path != null) {
        wire = await _sealAndUpload(media);
      }
      await _sendEncrypted(
        chatId,
        Payload(kind: 'text', id: m.id, text: caption, senderPhone: session!.phone, media: wire.forWire().toJson()),
        ref: m.id,
      );
    } catch (e) {
      debugPrint('Adjunto: $e');
      await _db!.setStatus(m.id, MessageStatus.failed);
      await _refresh();
      rethrow;
    }
  }

  Future<void> _downloadMedia(Message msg) async {
    final media = msg.media;
    if (media == null || !media.needsDownload || _downloading.contains(msg.id) || _api == null) return;
    _downloading.add(msg.id);
    try {
      final path = await _fetchMedia(media);
      await _db?.setMedia(msg.id, media.copyWith(localPath: path));
      await _refresh();
    } catch (e) {
      debugPrint('Descarga de adjunto: $e');
    } finally {
      _downloading.remove(msg.id);
    }
  }

  /// Descarga y descifra un adjunto; devuelve la ruta local.
  Future<String> _fetchMedia(MessageMedia media) async {
    final cipher = await _api!.downloadAttachment(media.attachmentId!);
    return MediaStore.open(
      cipher,
      key: base64Decode(media.key!),
      nonce: base64Decode(media.nonce!),
      mac: base64Decode(media.mac!),
      extension: MediaStore.extensionFor(media.mime, media.name),
    );
  }

  /// Sube cifrado un archivo local y devuelve el adjunto listo para enviar.
  Future<MessageMedia> _sealAndUpload(MessageMedia media) async {
    final sealed = await MediaStore.seal(media.localPath!);
    final attId = await _api!.uploadAttachment(sealed.bytes);
    return media.copyWith(
      attachmentId: attId,
      key: base64Encode(sealed.key),
      nonce: base64Encode(sealed.nonce),
      mac: base64Encode(sealed.mac),
    );
  }

  // ---------- Perfil ----------

  /// Cambia mi nombre y/o foto y lo envía (cifrado) a mis contactos.
  Future<void> updateProfile({String? name, String? photoSourcePath, bool removePhoto = false}) async {
    String? newPhoto;
    if (photoSourcePath != null) newPhoto = await MediaStore.importFile(photoSourcePath);
    profile = profile.copyWith(name: name?.trim(), photoPath: newPhoto, clearPhoto: removePhoto);
    await _store.write(_profileKey, jsonEncode(profile.toJson()));
    notifyListeners();
    if (!isDemo) unawaited(_broadcastProfile());
  }

  /// Envía mi perfil a un chat concreto o a todos mis chats individuales.
  Future<void> _broadcastProfile([String? onlyChatId]) async {
    try {
      Map<String, dynamic>? photo;
      final path = profile.photoPath;
      if (path != null && await File(path).exists()) {
        final up = await _sealAndUpload(
            MessageMedia(type: MediaType.image, localPath: path, mime: MediaStore.mimeFor(path)));
        photo = up.forWire().toJson();
      }
      final targets = chats.where((c) => !c.isGroup && c.identityKey != null && (onlyChatId == null || c.id == onlyChatId));
      for (final c in targets) {
        await _sendEncrypted(c.id, Payload(kind: 'profile', text: profile.name, media: photo),
            ref: 'x-${_uuid.v4()}');
      }
    } catch (e) {
      debugPrint('Enviar perfil: $e');
    }
  }

  Future<void> _resumeDownloads() async {
    final db = _db;
    if (db == null) return;
    for (final m in await db.pendingDownloads()) {
      await _downloadMedia(m);
    }
  }

  /// Reintenta descargar un adjunto (al tocarlo si falló).
  Future<void> retryDownload(Message m) => _downloadMedia(m);

  /// Borra un mensaje solo en este móvil.
  Future<void> deleteMessage(String id) async {
    await _db!.deleteMessage(id);
    await _refresh();
  }

  /// Avisa de que estoy grabando una nota de voz, si la privacidad lo permite.
  Future<void> setRecording(String chatId, bool on) async {
    if (isDemo || !_gate.canSendRecording()) return;
    try {
      await _sendEncrypted(chatId, Payload(kind: 'recording', on: on), ref: 'x-recording', ephemeral: true);
    } catch (_) {}
  }

  /// Avisa de que estoy escribiendo, si la privacidad lo permite.
  Future<void> setTyping(String chatId, bool on) async {
    if (isDemo || !_gate.canSendTyping()) return;
    final now = DateTime.now();
    if (on && now.difference(_lastTypingSent).inSeconds < 4) return;
    _lastTypingSent = on ? now : DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _sendEncrypted(chatId, Payload(kind: 'typing', on: on), ref: 'x-typing', ephemeral: true);
    } catch (_) {}
  }

  Future<void> openChat(String chatId) async {
    openChatId = chatId;
    await _db!.clearUnread(chatId);
    await _sendReadReceipts(chatId);
    await _refresh();
  }

  /// Se llama desde dispose() de la pantalla de chat: no notifica a la UI
  /// para no reconstruir widgets mientras el árbol se desmonta.
  void closeChat() {
    openChatId = null;
  }

  Future<void> _sendReadReceipts(String chatId) async {
    final ids = await _db!.unreadIncoming(chatId);
    if (ids.isEmpty) return;
    await _db!.advanceStatus(ids, MessageStatus.read);
    if (!isDemo && _gate.canSendReadReceipt()) {
      try {
        await _sendEncrypted(chatId, Payload(kind: 'read', ids: ids), ref: 'x-${_uuid.v4()}');
      } catch (_) {}
    }
  }

  /// Abre (o crea) un chat con un número. Devuelve el id del chat.
  Future<String> startChatWithPhone(String phone, String name) async {
    final title = name.trim().isEmpty ? prettyPhone(phone) : name.trim();
    if (isDemo) {
      final id = 'demo-$phone';
      if (await _db!.chat(id) == null) {
        await _db!.upsertChat(Chat(id: id, title: title, phone: phone, updatedAt: DateTime.now()));
      }
      await _reloadChats();
      return id;
    }
    if (phone == session!.phone) {
      throw const ApiException(400, 'self', 'Ese es tu propio número.');
    }
    final id = await _api!.lookup(phone);
    final identity = base64Encode(await _api!.identityOf(id));
    final existing = await _db!.chat(id);
    await _db!.upsertChat(existing?.copyWith(title: title, identityKey: identity) ??
        Chat(id: id, title: title, phone: phone, identityKey: identity, updatedAt: DateTime.now()));
    await _reloadChats();
    if (existing == null) unawaited(_broadcastProfile(id));
    return id;
  }

  /// Botón de pánico: borra la base de datos y todas las claves de este móvil.
  Future<void> panic() async {
    _retry?.cancel();
    _tick?.cancel();
    await _ws?.sink.close();
    _ws = null;
    online = false;
    await _db?.close();
    _db = null;
    await LocalDb.destroy();
    await MediaStore.wipe();
    await _store.panicWipe();
    session = null;
    profile = const Profile();
    chats = [];
    _messages.clear();
    _outbox.clear();
    openChatId = null;
    phase = AppPhase.onboarding;
    notifyListeners();
  }

  // ---------- Modo demo ----------

  void _simulateReply(String chatId, String messageId) {
    final chat = chats.where((c) => c.id == chatId).firstOrNull;
    Future<void> later(int ms, Future<void> Function() f) =>
        Future.delayed(Duration(milliseconds: ms), () async {
          if (_db != null) await f();
        });
    later(600, () async {
      await _db!.advanceStatus([messageId], MessageStatus.delivered);
      await _refresh();
    });
    later(1400, () async {
      await _db!.advanceStatus([messageId], MessageStatus.read);
      _typingUntil[chatId] = DateTime.now().add(const Duration(seconds: 3));
      await _refresh();
    });
    later(3400, () async {
      _typingUntil.remove(chatId);
      final sender = (chat?.isGroup ?? false) ? 'Pedro' : '';
      await _db!.addMessage(
        Message(id: _uuid.v4(), chatId: chatId, kind: MessageKind.incoming, sender: sender,
            body: demoReply(), status: MessageStatus.delivered, createdAt: DateTime.now()),
        countUnread: openChatId != chatId,
      );
      if (openChatId == chatId) await _sendReadReceipts(chatId);
      await _refresh();
    });
  }

  // ---------- Recarga ----------

  Future<void> _reloadChats() async {
    final db = _db;
    if (db == null) return;
    chats = await db.chats();
    final open = openChatId;
    if (open != null) _messages[open] = await db.messages(open);
    notifyListeners();
  }

  Future<void> _refresh() => _reloadChats();

  @override
  void dispose() {
    _retry?.cancel();
    _tick?.cancel();
    _ws?.sink.close();
    _db?.close();
    super.dispose();
  }
}
