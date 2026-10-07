import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart' show Sha256;
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
import '../privacy/presentation/privacy_provider.dart';
import 'demo_data.dart';
import 'models.dart';

final appProvider = ChangeNotifierProvider<AppController>((ref) => AppController(ref));

enum AppPhase { loading, onboarding, ready }

/// Estado global de la app: sesión, chats, mensajes, grupos, estados y
/// conexión con el servidor.
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
  List<StatusPost> statuses = [];
  String? openChatId;
  Profile profile = const Profile();

  /// Lo registra el controlador de llamadas para recibir sus señales.
  void Function(String fromChatId, Map<String, dynamic> signal)? onCallSignal;

  /// La interfaz lo usa para mostrar un aviso cuando llega un mensaje
  /// a un chat que no está abierto.
  void Function(Chat chat, Message message)? onNotify;

  static const _profileKey = 'klk.profile';
  static const _pinKey = 'klk.hidden.pin';

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
  String get myId => session?.accountId ?? 'me';

  List<Message> messagesFor(String chatId) => _messages[chatId] ?? const [];
  bool isTyping(String chatId) => (_typingUntil[chatId]?.isAfter(DateTime.now())) ?? false;
  bool isRecording(String chatId) => (_recordingUntil[chatId]?.isAfter(DateTime.now())) ?? false;

  /// Chats de la lista principal (sin los ocultos).
  List<Chat> get visibleChats => chats.where((c) => !c.hidden).toList();
  List<Chat> get hiddenChats => chats.where((c) => c.hidden).toList();

  /// Mis contactos individuales (para crear grupos y enviar estados).
  List<Chat> get contactChats => chats.where((c) => !c.isGroup).toList();

  Chat? chatById(String id) => chats.where((c) => c.id == id).firstOrNull;

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
    await _onTick();
  }

  Future<CryptoEngine> _loadCrypto() async {
    var seed = await _store.identitySeed();
    if (seed == null) {
      seed = base64Encode(randomBytes(32));
      await _store.saveIdentitySeed(seed);
    }
    return ProvisionalCrypto.fromSeed(base64Decode(seed));
  }

  /// Cada 10 s: programados que vencen, mensajes temporales y estados caducados.
  Future<void> _onTick() async {
    final db = _db;
    if (db == null) return;
    final now = DateTime.now();
    await db.settleScheduled(now);
    for (final path in [...await db.purgeExpired(now), ...await db.purgeStatuses(now)]) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
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
          final ref = f['ref'] as String? ?? '';
          _outbox.remove(ref);
          // En grupos el ref es "<idMensaje>|<miembro>"
          final msgId = ref.split('|').first;
          if (f['scheduled'] != true && !ref.startsWith('x-')) {
            await _db!.advanceStatus([msgId], MessageStatus.sent);
            await _refresh();
          }
        }
      case 'error':
        {
          final ref = f['ref'] as String? ?? '';
          _outbox.remove(ref);
          debugPrint('Servidor: ${f['code']} ${f['message']}');
          if (ref.isNotEmpty && !ref.startsWith('x-') && !ref.contains('|')) {
            await _db!.setStatus(ref, MessageStatus.failed);
            await _refresh();
          }
        }
    }
  }

  // ---------- Recepción ----------

  Future<void> _onEnvelope(Map<String, dynamic> f) async {
    final from = f['from'] as String;
    final ephemeral = f['ephemeral'] == true;
    try {
      final opened = await _crypto!.decrypt(base64Decode(f['content'] as String));
      final p = Payload.decode(opened.plaintext);
      final identity = base64Encode(opened.senderIdentity);
      final db = _db!;
      final g = p.group;

      // Chat individual con el remitente: lo creo solo si me escribe directamente.
      var direct = await db.chat(from);
      if (direct == null && g == null) {
        if (p.kind != 'text') return;
        final phone = p.senderPhone ?? '';
        direct = Chat(
          id: from,
          title: phone.isEmpty ? 'Contacto nuevo' : prettyPhone(phone),
          phone: phone,
          identityKey: identity,
          updatedAt: DateTime.now(),
        );
        await db.upsertChat(direct);
        await _reloadChats();
        unawaited(_broadcastProfile(from));
      } else if (direct != null && direct.identityKey == null) {
        await db.setIdentity(from, identity);
      } else if (direct != null && direct.identityKey != identity) {
        // Primera clave vista = de confianza. Si cambia, se avisa al usuario.
        await db.setIdentity(from, identity);
        await _system(from, 'La clave de seguridad de este contacto cambió. Puede que haya reinstalado KLK.');
      }

      // Chat de destino: el grupo o el chat individual
      final chatId = g == null ? from : await _ensureGroup(g, from, identity);
      final senderName = g == null ? '' : _nameOf(from, g);

      switch (p.kind) {
        case 'text':
          await _receiveText(p, f, from: from, chatId: chatId, senderName: senderName, isGroup: g != null);
        case 'typing' || 'recording':
          {
            final target = p.kind == 'typing' ? _typingUntil : _recordingUntil;
            if (p.on == true) {
              target[chatId] = DateTime.now().add(const Duration(seconds: 6));
              Timer(const Duration(seconds: 6, milliseconds: 100), notifyListeners);
            } else {
              target.remove(chatId);
            }
            notifyListeners();
          }
        case 'reaction':
          {
            final m = await db.message(p.target ?? '');
            if (m != null && m.chatId == chatId) {
              final r = Map<String, String>.from(m.reactions);
              if ((p.emoji ?? '').isEmpty) {
                r.remove(from);
              } else {
                r[from] = p.emoji!;
              }
              await db.updateMessage(m.copyWith(reactions: r));
            }
          }
        case 'delete':
          {
            final m = await db.message(p.target ?? '');
            // Solo el autor puede borrar para todos
            if (m != null && m.kind == MessageKind.incoming && m.chatId == chatId && (g != null || chatId == from)) {
              await _wipe(m);
            }
          }
        case 'timer':
          {
            final sec = (p.exp ?? 0) > 0 ? p.exp : null;
            await db.setDisappear(chatId, sec);
            final who = g == null ? (direct?.title ?? 'Tu contacto') : senderName;
            await _system(chatId,
                sec == null ? '⏱️ $who desactivó los mensajes temporales' : '⏱️ $who activó los mensajes temporales: ${disappearLabel(sec)}');
          }
        case 'group':
          await _system(chatId, '👥 ${senderName.isEmpty ? 'Alguien' : senderName} te añadió al grupo «${g?['n'] ?? ''}»');
        case 'status':
          await _receiveStatus(p, from: from, name: direct?.title ?? prettyPhone(p.senderPhone ?? ''));
        case 'profile':
          await _receiveProfile(p, from: from);
        case 'call':
          if (p.call != null) onCallSignal?.call(from, p.call!);
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

  Future<void> _receiveText(Payload p, Map<String, dynamic> f,
      {required String from, required String chatId, required String senderName, required bool isGroup}) async {
    final db = _db!;
    final id = p.id;
    if (id == null || await db.hasMessage(id)) return;
    final ts = DateTime.tryParse(f['ts'] as String? ?? '')?.toLocal() ?? DateTime.now();
    final media = p.media == null ? null : MessageMedia.fromJson(p.media!);
    final exp = p.exp;
    final msg = Message(
      id: id,
      chatId: chatId,
      kind: MessageKind.incoming,
      sender: senderName,
      body: p.text ?? '',
      status: MessageStatus.delivered,
      createdAt: ts,
      media: media,
      replyToId: p.reply?['id'] as String?,
      replyPreview: p.reply?['p'] as String?,
      expiresAt: exp == null || exp <= 0 ? null : ts.add(Duration(seconds: exp)),
    );
    await db.addMessage(msg, countUnread: openChatId != chatId);
    if (media?.needsDownload ?? false) unawaited(_downloadMedia(msg));
    _typingUntil.remove(chatId);
    _recordingUntil.remove(chatId);

    if (openChatId != chatId) {
      final chat = await db.chat(chatId);
      if (chat != null && !chat.hidden) onNotify?.call(chat, msg);
    }
    // Confirmaciones solo en chats individuales
    if (!isGroup) {
      await _sendEncrypted(from, Payload(kind: 'delivered', ids: [id]), ref: 'x-${_uuid.v4()}');
      if (openChatId == chatId) await _sendReadReceipts(chatId);
    }
  }

  Future<void> _receiveProfile(Payload p, {required String from}) async {
    final db = _db!;
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
      try {
        final path = await _fetchMedia(photo);
        await _db?.setAvatar(from, path);
      } catch (e) {
        debugPrint('Foto de perfil: $e');
      }
    }
  }

  Future<void> _receiveStatus(Payload p, {required String from, required String name}) async {
    final s = p.status;
    if (s == null || p.id == null) return;
    String? path;
    final media = p.media == null ? null : MessageMedia.fromJson(p.media!);
    if (media != null && media.needsDownload) {
      try {
        path = await _fetchMedia(media);
      } catch (e) {
        debugPrint('Estado: $e');
        return;
      }
    }
    await _db!.addStatus(StatusPost(
      id: p.id!,
      ownerId: from,
      ownerName: name,
      text: p.text ?? '',
      color: (s['c'] as num?)?.toInt() ?? 0xFF002D62,
      mediaPath: path,
      createdAt: DateTime.tryParse(s['at'] as String? ?? '') ?? DateTime.now(),
      allowSave: s['save'] == true,
    ));
  }

  /// Crea o actualiza el grupo descrito en un mensaje. Devuelve su id.
  Future<String> _ensureGroup(Map<String, dynamic> g, String from, String fromIdentity) async {
    final db = _db!;
    final id = g['id'] as String;
    final incoming = ((g['m'] as List?) ?? const [])
        .map((e) => GroupMember.fromJson((e as Map).cast<String, dynamic>()))
        .where((m) => m.id != myId)
        .toList();
    final existing = await db.chat(id);
    // Conservo las claves que ya conocía y aprendo la del remitente.
    final known = {for (final m in existing?.members ?? const <GroupMember>[]) m.id: m};
    final members = [
      for (final m in incoming)
        m.id == from
            ? m.withIdentity(fromIdentity)
            : (known[m.id]?.identityKey != null ? m.withIdentity(known[m.id]!.identityKey!) : m),
    ];
    final title = (g['n'] as String?)?.trim();
    if (existing == null) {
      await db.upsertChat(Chat(
        id: id,
        title: (title == null || title.isEmpty) ? 'Grupo' : title,
        isGroup: true,
        members: members,
        updatedAt: DateTime.now(),
      ));
    } else {
      await db.upsertChat(existing.copyWith(title: title, members: members));
    }
    return id;
  }

  String _nameOf(String accountId, Map<String, dynamic> g) {
    final contact = chatById(accountId);
    if (contact != null && !contact.isGroup) return contact.title;
    for (final e in (g['m'] as List?) ?? const []) {
      final m = (e as Map).cast<String, dynamic>();
      if (m['id'] == accountId) {
        final n = (m['n'] as String?) ?? '';
        return n.isNotEmpty ? n : prettyPhone((m['p'] as String?) ?? '');
      }
    }
    return 'Alguien';
  }

  // ---------- Envío ----------

  Future<void> _sendEncrypted(String chatId, Payload p,
      {required String ref, DateTime? deliverAt, bool ephemeral = false}) async {
    final chat = await _db!.chat(chatId);
    final key = chat?.identityKey;
    if (key == null) throw StateError('Sin clave del contacto');
    await _sendTo(chatId, key, p, ref: ref, deliverAt: deliverAt, ephemeral: ephemeral);
  }

  Future<void> _sendTo(String accountId, String identityKey, Payload p,
      {required String ref, DateTime? deliverAt, bool ephemeral = false}) async {
    final sealed = await _crypto!.encrypt(p.encode(), base64Decode(identityKey));
    final frame = jsonEncode({
      't': 'send',
      'ref': ref,
      'to': accountId,
      'messages': [
        {'device': 1, 'type': 1, 'content': base64Encode(sealed)}
      ],
      if (deliverAt != null) 'deliverAt': deliverAt.toUtc().toIso8601String(),
      if (ephemeral) 'ephemeral': true,
    });
    if (!ephemeral) _outbox[ref] = frame;
    _ws?.sink.add(frame);
  }

  /// Envía a un chat individual o a cada miembro de un grupo.
  Future<void> _sendToChat(String chatId, Payload p,
      {required String ref, DateTime? deliverAt, bool ephemeral = false}) async {
    final chat = await _db!.chat(chatId);
    if (chat == null) throw StateError('Chat no encontrado');
    if (!chat.isGroup) {
      return _sendEncrypted(chatId, p, ref: ref, deliverAt: deliverAt, ephemeral: ephemeral);
    }
    final members = await _membersWithKeys(chat);
    final withGroup = Payload(
      kind: p.kind,
      id: p.id,
      text: p.text,
      on: p.on,
      senderPhone: session?.phone,
      media: p.media,
      reply: p.reply,
      exp: p.exp,
      emoji: p.emoji,
      target: p.target,
      group: _groupMeta(chat, members),
    );
    for (final m in members) {
      if (m.identityKey == null) continue;
      await _sendTo(m.id, m.identityKey!, withGroup,
          ref: ephemeral ? 'x-${p.kind}' : '$ref|${m.id}', deliverAt: deliverAt, ephemeral: ephemeral);
    }
  }

  Map<String, dynamic> _groupMeta(Chat chat, List<GroupMember> members) => {
        'id': chat.id,
        'n': chat.title,
        'm': [
          GroupMember(id: myId, phone: session?.phone ?? '', name: profile.name).toJson(withKey: false),
          for (final m in members) m.toJson(withKey: false),
        ],
      };

  /// Pide al servidor las claves que falten de los miembros del grupo.
  Future<List<GroupMember>> _membersWithKeys(Chat chat) async {
    var changed = false;
    final out = <GroupMember>[];
    for (final m in chat.members) {
      if (m.identityKey != null) {
        out.add(m);
        continue;
      }
      final contact = chatById(m.id);
      String? key = contact?.identityKey;
      if (key == null && _api != null) {
        try {
          key = base64Encode(await _api!.identityOf(m.id));
        } catch (_) {}
      }
      out.add(key == null ? m : m.withIdentity(key));
      changed = changed || key != null;
    }
    if (changed) await _db!.upsertChat(chat.copyWith(members: out));
    return out;
  }

  /// Segundos de vida de los mensajes nuevos en este chat (null = no caducan).
  int? _timerOf(String chatId) => chatById(chatId)?.disappearSec;

  // ---------- Acciones: mensajes ----------

  Future<void> sendText(String chatId, String text, {DateTime? at, Message? replyTo}) async {
    final scheduled = at != null && at.isAfter(DateTime.now());
    final timer = _timerOf(chatId);
    final now = DateTime.now();
    final m = Message(
      id: _uuid.v4(),
      chatId: chatId,
      kind: MessageKind.outgoing,
      body: text,
      status: scheduled ? MessageStatus.scheduled : MessageStatus.sending,
      createdAt: scheduled ? at : now,
      scheduledFor: scheduled ? at : null,
      replyToId: replyTo?.id,
      replyPreview: replyTo == null ? null : _replyPreview(replyTo),
      expiresAt: timer == null ? null : (scheduled ? at : now).add(Duration(seconds: timer)),
    );
    await _db!.addMessage(m);
    await _refresh();

    if (isDemo) {
      if (!scheduled) _simulateReply(chatId, m.id);
      return;
    }
    try {
      await _sendToChat(
        chatId,
        Payload(
          kind: 'text',
          id: m.id,
          text: text,
          senderPhone: session!.phone,
          reply: replyTo == null ? null : {'id': replyTo.id, 'p': m.replyPreview},
          exp: timer,
        ),
        ref: m.id,
        deliverAt: scheduled ? at : null,
      );
    } catch (e) {
      await _db!.setStatus(m.id, MessageStatus.failed);
      await _refresh();
    }
  }

  String _replyPreview(Message m) {
    final who = m.isMine ? 'Tú' : (m.sender.isNotEmpty ? m.sender : (chatById(m.chatId)?.title ?? ''));
    final text = m.summary;
    return '$who: ${text.length > 80 ? '${text.substring(0, 80)}…' : text}';
  }

  /// Envía una foto, vídeo, nota de voz, documento, ubicación, sticker o viaje.
  ///
  /// El archivo se cifra en el móvil con una clave propia, se sube cifrado y la
  /// clave viaja dentro del mensaje (cifrado de punta a punta).
  Future<void> sendMedia(String chatId, MessageMedia media, {String caption = '', Message? replyTo}) async {
    final timer = _timerOf(chatId);
    final now = DateTime.now();
    final m = Message(
      id: _uuid.v4(),
      chatId: chatId,
      kind: MessageKind.outgoing,
      body: caption,
      status: MessageStatus.sending,
      createdAt: now,
      media: media,
      replyToId: replyTo?.id,
      replyPreview: replyTo == null ? null : _replyPreview(replyTo),
      expiresAt: timer == null ? null : now.add(Duration(seconds: timer)),
    );
    await _db!.addMessage(m);
    await _refresh();

    if (isDemo) {
      _simulateReply(chatId, m.id);
      return;
    }
    try {
      var wire = media;
      if (media.hasFile && media.localPath != null) wire = await _sealAndUpload(media);
      await _sendToChat(
        chatId,
        Payload(
          kind: 'text',
          id: m.id,
          text: caption,
          senderPhone: session!.phone,
          media: wire.forWire().toJson(),
          reply: replyTo == null ? null : {'id': replyTo.id, 'p': m.replyPreview},
          exp: timer,
        ),
        ref: m.id,
      );
    } catch (e) {
      debugPrint('Adjunto: $e');
      await _db!.setStatus(m.id, MessageStatus.failed);
      await _refresh();
      rethrow;
    }
  }

  /// Pongo o quito mi reacción (tocar el mismo emoji la quita).
  Future<void> react(Message m, String emoji) async {
    final r = Map<String, String>.from(m.reactions);
    final remove = r['me'] == emoji;
    if (remove) {
      r.remove('me');
    } else {
      r['me'] = emoji;
    }
    await _db!.updateMessage(m.copyWith(reactions: r));
    await _refresh();
    if (isDemo) return;
    try {
      await _sendToChat(m.chatId, Payload(kind: 'reaction', target: m.id, emoji: remove ? '' : emoji),
          ref: 'x-${_uuid.v4()}');
    } catch (_) {}
  }

  /// Borra un mensaje mío para todos.
  Future<void> deleteForEveryone(Message m) async {
    if (!m.isMine) return;
    await _wipe(m);
    await _refresh();
    if (isDemo) return;
    try {
      await _sendToChat(m.chatId, Payload(kind: 'delete', target: m.id), ref: 'x-${_uuid.v4()}');
    } catch (_) {}
  }

  /// Deja el mensaje como "Este mensaje se eliminó" y borra su archivo.
  Future<void> _wipe(Message m) async {
    final path = m.media?.localPath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _db!.updateMessage(Message(
      id: m.id,
      chatId: m.chatId,
      kind: m.kind,
      sender: m.sender,
      body: '',
      status: m.status,
      createdAt: m.createdAt,
      deleted: true,
    ));
  }

  /// Reenvía un mensaje a otros chats.
  Future<void> forward(Message m, List<String> chatIds) async {
    for (final id in chatIds) {
      final media = m.media;
      if (media == null) {
        await sendText(id, m.body);
      } else {
        // Se reenvía la copia local; "ver una vez" no se puede reenviar.
        if (media.viewOnce) continue;
        final copy = MessageMedia(
          type: media.type,
          localPath: media.localPath,
          mime: media.mime,
          name: media.name,
          size: media.size,
          durationMs: media.durationMs,
          lat: media.lat,
          lng: media.lng,
          tripDate: media.tripDate,
          tripFrom: media.tripFrom,
          tripTo: media.tripTo,
        );
        await sendMedia(id, copy, caption: m.body);
      }
    }
  }

  /// Al cerrar una foto de "ver una vez": se borra del móvil para siempre.
  Future<void> markViewOnceOpened(Message m) async {
    final media = m.media;
    if (media == null || !media.viewOnce) return;
    final path = media.localPath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _db!.updateMessage(m.copyWith(media: media.copyWith(opened: true, clearPath: true)));
    await _refresh();
  }

  /// Activa o desactiva los mensajes temporales del chat (para todos).
  Future<void> setDisappearing(String chatId, int? seconds) async {
    await _db!.setDisappear(chatId, seconds);
    await _system(chatId,
        seconds == null ? '⏱️ Desactivaste los mensajes temporales' : '⏱️ Activaste los mensajes temporales: ${disappearLabel(seconds)}');
    await _refresh();
    if (isDemo) return;
    try {
      await _sendToChat(chatId, Payload(kind: 'timer', exp: seconds ?? 0), ref: 'x-${_uuid.v4()}');
    } catch (_) {}
  }

  /// Borra un mensaje solo en este móvil.
  Future<void> deleteMessage(String id) async {
    await _db!.deleteMessage(id);
    await _refresh();
  }

  Future<void> _system(String chatId, String text) async {
    final db = _db;
    if (db == null || await db.chat(chatId) == null) return;
    await db.addMessage(Message(
      id: _uuid.v4(),
      chatId: chatId,
      kind: MessageKind.system,
      body: text,
      status: MessageStatus.read,
      createdAt: DateTime.now(),
    ));
  }

  // ---------- Grupos ----------

  /// Crea un grupo con mis contactos y avisa a los miembros.
  Future<String> createGroup(String name, List<Chat> contacts) async {
    final id = 'g-${_uuid.v4()}';
    final members = [
      for (final c in contacts)
        GroupMember(id: c.id, phone: c.phone, name: c.title, identityKey: c.identityKey),
    ];
    await _db!.upsertChat(Chat(id: id, title: name.trim(), isGroup: true, members: members, updatedAt: DateTime.now()));
    await _system(id, '👥 Creaste el grupo «${name.trim()}» con ${members.length} ${members.length == 1 ? 'persona' : 'personas'}');
    await _reloadChats();
    if (!isDemo) {
      try {
        await _sendToChat(id, const Payload(kind: 'group'), ref: 'x-${_uuid.v4()}');
      } catch (e) {
        debugPrint('Crear grupo: $e');
      }
    }
    return id;
  }

  // ---------- Chats ocultos ----------

  Future<bool> get hasPin async => (await _store.read(_pinKey)) != null;

  Future<String> _hashPin(String pin) async {
    final h = await Sha256().hash(utf8.encode('klk-pin:$pin'));
    return base64Encode(h.bytes);
  }

  Future<void> setPin(String pin) async => _store.write(_pinKey, await _hashPin(pin));

  Future<bool> checkPin(String pin) async => (await _store.read(_pinKey)) == await _hashPin(pin);

  Future<void> setHidden(String chatId, bool hidden) async {
    await _db!.setHidden(chatId, hidden);
    await _refresh();
  }

  // ---------- Estados ----------

  /// Publica un estado de 24 h para todos mis contactos.
  /// Publica un estado de texto, foto o vídeo (el tipo se deduce del archivo).
  Future<void> postStatus({String text = '', int color = 0xFF002D62, String? mediaSourcePath}) async {
    final allowSave = _ref.read(privacyProvider).allowStorySaving;
    String? path;
    if (mediaSourcePath != null) path = await MediaStore.importFile(mediaSourcePath);
    final post = StatusPost(
      id: _uuid.v4(),
      ownerId: 'me',
      ownerName: profile.name.isEmpty ? 'Mi estado' : profile.name,
      text: text,
      color: color,
      mediaPath: path,
      createdAt: DateTime.now(),
      allowSave: allowSave,
      viewed: true,
    );
    await _db!.addStatus(post);
    await _reloadChats();
    if (isDemo) return;

    try {
      Map<String, dynamic>? media;
      if (path != null) {
        final mime = MediaStore.mimeFor(path);
        final type = mime.startsWith('video/') ? MediaType.video : MediaType.image;
        media = (await _sealAndUpload(MessageMedia(type: type, localPath: path, mime: mime)))
            .forWire()
            .toJson();
      }
      final payload = Payload(
        kind: 'status',
        id: post.id,
        text: text,
        media: media,
        senderPhone: session!.phone,
        status: {'c': color, 'at': post.createdAt.toUtc().toIso8601String(), 'save': allowSave},
      );
      for (final c in chats.where((c) => !c.isGroup && c.identityKey != null)) {
        await _sendTo(c.id, c.identityKey!, payload, ref: 'x-${_uuid.v4()}');
        // Pequeña pausa para no superar el límite de envíos por segundo
        await Future.delayed(const Duration(milliseconds: 60));
      }
    } catch (e) {
      debugPrint('Publicar estado: $e');
    }
  }

  Future<void> markStatusViewed(String id) async {
    await _db!.markStatusViewed(id);
    await _reloadChats();
  }

  // ---------- Descargas ----------

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

  Future<void> _resumeDownloads() async {
    final db = _db;
    if (db == null) return;
    for (final m in await db.pendingDownloads()) {
      await _downloadMedia(m);
    }
  }

  /// Reintenta descargar un adjunto (al tocarlo si falló).
  Future<void> retryDownload(Message m) => _downloadMedia(m);

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
      final targets =
          chats.where((c) => !c.isGroup && c.identityKey != null && (onlyChatId == null || c.id == onlyChatId));
      for (final c in targets) {
        await _sendEncrypted(c.id, Payload(kind: 'profile', text: profile.name, media: photo),
            ref: 'x-${_uuid.v4()}');
      }
    } catch (e) {
      debugPrint('Enviar perfil: $e');
    }
  }

  // ---------- Llamadas ----------

  /// Envía una señal de llamada cifrada. Es efímera: si el otro no está
  /// conectado no se guarda (una llamada no debe sonar horas después).
  Future<void> sendCallSignal(String chatId, Map<String, dynamic> signal) =>
      _sendEncrypted(chatId, Payload(kind: 'call', call: signal), ref: 'x-call', ephemeral: true);

  /// Anota la llamada en el chat ("Llamada de voz · 2:31", "Llamada perdida"…).
  Future<void> logCall(String chatId, String text, {bool incoming = false}) async {
    await _system(chatId, text);
    await _refresh();
  }

  // ---------- Presencia ----------

  /// Avisa de que estoy grabando una nota de voz, si la privacidad lo permite.
  Future<void> setRecording(String chatId, bool on) async {
    if (isDemo || !_gate.canSendRecording()) return;
    try {
      await _sendToChat(chatId, Payload(kind: 'recording', on: on), ref: 'x-recording', ephemeral: true);
    } catch (_) {}
  }

  /// Avisa de que estoy escribiendo, si la privacidad lo permite.
  Future<void> setTyping(String chatId, bool on) async {
    if (isDemo || !_gate.canSendTyping()) return;
    final now = DateTime.now();
    if (on && now.difference(_lastTypingSent).inSeconds < 4) return;
    _lastTypingSent = on ? now : DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _sendToChat(chatId, Payload(kind: 'typing', on: on), ref: 'x-typing', ephemeral: true);
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
    final chat = await _db!.chat(chatId);
    if (!isDemo && !(chat?.isGroup ?? true) && _gate.canSendReadReceipt()) {
      try {
        await _sendEncrypted(chatId, Payload(kind: 'read', ids: ids), ref: 'x-${_uuid.v4()}');
      } catch (_) {}
    }
  }

  // ---------- Contactos ----------

  /// Prefijo de mi país, para entender los números de mi agenda.
  String get myDialCode => dialCodeOf(session?.phone ?? '+1');

  /// Qué números usan KLK (número -> id de cuenta).
  /// En modo demo, se inventa que la mitad de tus contactos ya están en KLK.
  Future<Map<String, String>> discover(List<String> phones) async {
    if (phones.isEmpty) return {};
    if (isDemo) {
      return {
        for (final p in phones)
          if (int.parse(p[p.length - 1]) % 2 == 0) p: 'demo-$p',
      };
    }
    final found = <String, String>{};
    for (var i = 0; i < phones.length; i += 1000) {
      final end = i + 1000 > phones.length ? phones.length : i + 1000;
      found.addAll(await _api!.lookupBatch(phones.sublist(i, end)));
    }
    return found;
  }

  /// Abre (o crea) un chat con un número. Devuelve el id del chat.
  /// Si ya sé su id de cuenta ([knownAccountId]), me ahorro la búsqueda.
  Future<String> startChatWithPhone(String phone, String name, {String? knownAccountId}) async {
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
    final id = knownAccountId ?? await _api!.lookup(phone);
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
    statuses = [];
    _messages.clear();
    _outbox.clear();
    openChatId = null;
    phase = AppPhase.onboarding;
    notifyListeners();
  }

  // ---------- Modo demo ----------

  void _simulateReply(String chatId, String messageId) {
    final chat = chatById(chatId);
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
      final group = chat?.isGroup ?? false;
      final members = chat?.members ?? const <GroupMember>[];
      final sender = group ? (members.isNotEmpty ? members[Random().nextInt(members.length)].name : 'Pedro') : '';
      final timer = chat?.disappearSec;
      final now = DateTime.now();
      final reply = Message(
        id: _uuid.v4(),
        chatId: chatId,
        kind: MessageKind.incoming,
        sender: sender,
        body: demoReply(),
        status: MessageStatus.delivered,
        createdAt: now,
        expiresAt: timer == null ? null : now.add(Duration(seconds: timer)),
      );
      await _db!.addMessage(reply, countUnread: openChatId != chatId);
      if (openChatId == chatId) {
        await _sendReadReceipts(chatId);
      } else if (chat != null && !chat.hidden) {
        onNotify?.call(chat, reply);
      }
      await _refresh();
    });
  }

  // ---------- Recarga ----------

  Future<void> _reloadChats() async {
    final db = _db;
    if (db == null) return;
    chats = await db.chats();
    statuses = await db.statuses(DateTime.now());
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
