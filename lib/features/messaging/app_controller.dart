import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:klk_native/klk_native.dart';
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import '../../core/backup/backup_codec.dart';
import '../../core/config.dart';
import '../../core/crypto/crypto_engine.dart';
import '../../core/database/local_db.dart';
import '../../core/media/media_store.dart';
import '../../core/network/api_client.dart';
import '../../core/network/presence_gate.dart';
import '../../core/notify/alerts.dart';
import '../../core/security/secure_store.dart';
import '../../core/util/phone.dart';
import '../privacy/domain/privacy_settings.dart';
import '../privacy/presentation/privacy_provider.dart';
import '../communities/community.dart';
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

  /// Avisos de KLK (del panel del dueño) y los que ya cerré.
  List<KlkAnnouncement> announcements = [];
  Set<String> _dismissedNews = {};
  static const _newsKey = 'klk.news.dismissed';

  /// El dueño de KLK bloqueó esta cuenta.
  bool banned = false;
  DateTime _bannedCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// El aviso que se enseña arriba de los chats (el más nuevo sin cerrar).
  KlkAnnouncement? get currentAnnouncement =>
      announcements.where((a) => !_dismissedNews.contains(a.id)).firstOrNull;

  Future<void> dismissAnnouncement(String id) async {
    _dismissedNews = {..._dismissedNews, id};
    notifyListeners();
    // Solo se guardan los últimos 50 para que no crezca sin fin.
    final keep = _dismissedNews.toList();
    await _store.write(_newsKey, jsonEncode(keep.length > 50 ? keep.sublist(keep.length - 50) : keep));
  }

  Future<void> _loadAnnouncements() async {
    if (isDemo) {
      announcements = [
        KlkAnnouncement(
          id: 'demo-bienvenida',
          title: '¡Bienvenido a KLK messenger! 🇩🇴',
          body: 'Aquí te saldrán los avisos de KLK: novedades, versiones nuevas y consejos.',
          createdAt: DateTime.now(),
        ),
      ];
      notifyListeners();
      return;
    }
    final api = _api;
    if (api == null) return;
    try {
      final list = await api.announcements();
      announcements = list.map(KlkAnnouncement.fromJson).toList();
      if (banned) banned = false;
      notifyListeners();
    } on ApiException catch (e) {
      _checkBanned(e);
    } catch (_) {}
  }

  void _checkBanned(ApiException e) {
    if (e.code == 'banned' && !banned) {
      banned = true;
      notifyListeners();
    }
  }

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

  // Ubicación en tiempo real que estoy compartiendo (id del mensaje -> GPS)
  final Map<String, StreamSubscription<Position>> _live = {};
  final Map<String, Timer> _liveEnd = {};
  final Map<String, DateTime> _livePushed = {};
  StreamSubscription<void>? _shots;

  /// La copia de seguridad incluye como mucho estos bytes de fotos y vídeos.
  static const maxBackupMediaBytes = 50 * 1024 * 1024;

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
  /// Chats visibles; los fijados van arriba (en el orden en que se fijaron).
  List<Chat> get visibleChats {
    final list = chats.where((c) => !c.hidden).toList();
    if (pinnedChats.isEmpty) return list;
    final pinned = [for (final id in pinnedChats) ...list.where((c) => c.id == id)];
    return [...pinned, ...list.where((c) => !pinnedChats.contains(c.id))];
  }

  // ---------- Chats fijados y marcar como leído ----------

  /// Ids de los chats fijados arriba (sin límite).
  List<String> pinnedChats = [];
  static const _pinnedChatsKey = 'klk.pinnedChats';

  bool isPinnedChat(String chatId) => pinnedChats.contains(chatId);

  Future<void> _loadPinnedChats() async {
    try {
      final raw = await _store.read(_pinnedChatsKey);
      if (raw != null) pinnedChats = (jsonDecode(raw) as List).cast<String>();
    } catch (_) {}
  }

  Future<void> togglePinChat(String chatId) async {
    pinnedChats = isPinnedChat(chatId)
        ? pinnedChats.where((id) => id != chatId).toList()
        : [chatId, ...pinnedChats];
    notifyListeners();
    try {
      await _store.write(_pinnedChatsKey, jsonEncode(pinnedChats));
    } catch (_) {}
  }

  /// Marca un chat como leído sin abrirlo (manda el doble check azul si lo tienes activado).
  Future<void> markChatRead(String chatId) async {
    await _db!.clearUnread(chatId);
    await _sendReadReceipts(chatId);
    await _refresh();
  }
  List<Chat> get hiddenChats => chats.where((c) => c.hidden).toList();

  /// Mis contactos individuales (para crear grupos y enviar estados).
  List<Chat> get contactChats => chats.where((c) => !c.isGroup && !c.blocked).toList();

  List<Chat> get blockedChats => chats.where((c) => c.blocked).toList();

  /// Contactos que cumplen años hoy.
  List<Chat> get birthdaysToday {
    final today = DateTime.now();
    return chats.where((c) => !c.isGroup && !c.blocked && !c.hidden && c.birthdayOn(today)).toList();
  }

  /// Mensaje fijado del chat (si sigue existiendo).
  Message? pinnedMessage(String chatId) {
    final id = chatById(chatId)?.pinnedId;
    if (id == null) return null;
    return messagesFor(chatId).where((m) => m.id == id && !m.deleted).firstOrNull;
  }

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
    unawaited(_loadLastSeen());
    await _loadPinnedChats();
    _db = await LocalDb.open(await _store.databaseKey());
    final savedProfile = await _store.read(_profileKey);
    if (savedProfile != null) profile = Profile.fromJson(jsonDecode(savedProfile) as Map<String, dynamic>);
    try {
      final news = await _store.read(_newsKey);
      if (news != null) _dismissedNews = (jsonDecode(news) as List).cast<String>().toSet();
    } catch (_) {}
    _crypto = await _loadCrypto();
    if (session!.isDemo) {
      if ((await _db!.chats()).isEmpty) await seedDemo(_db!);
      unawaited(_loadAnnouncements());
    } else {
      _api = ApiClient(session!.server, token: session!.token);
      unawaited(_connect());
    }
    await _db!.settleScheduled(DateTime.now());
    await _endStaleLiveLocations();
    _shots ??= KlkNative.screenshots.listen((_) => unawaited(_onScreenshot()), onError: (Object _) {});
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
    if (db == null || _exclusiveRunning) return;
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
    _foreground = true;
    if (phase == AppPhase.ready && !isDemo && !online) {
      _backoff = 1;
      unawaited(_connect());
    }
    unawaited(_announcePresence());
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
      unawaited(_loadAnnouncements());
    } catch (e) {
      debugPrint('WebSocket: $e');
      // ¿No conecta porque el dueño bloqueó la cuenta? (como mucho 1 vez por minuto)
      if (DateTime.now().difference(_bannedCheckedAt) > const Duration(minutes: 1)) {
        _bannedCheckedAt = DateTime.now();
        unawaited(_loadAnnouncements());
      }
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
      case 'announce':
        {
          final a = f['announcement'];
          if (a is Map) {
            final n = KlkAnnouncement.fromJson(a.cast<String, dynamic>());
            announcements = [n, ...announcements.where((x) => x.id != n.id)];
            notifyListeners();
          }
        }
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

      // De un contacto bloqueado no se acepta nada (ni mensajes, ni llamadas, ni estados).
      if (g == null && (direct?.blocked ?? false)) return;

      // Comunidad a la que no pertenezco (me salí hace poco): no se acepta nada
      if (g != null && isCommunityChat(g['id'] as String? ?? '') && await db.chat(g['id'] as String) == null) return;

      // Chat de destino: el grupo o el chat individual
      final chatId = g == null ? from : await _ensureGroup(g, from, identity);
      final senderName = g == null ? '' : _nameOf(from, g);

      switch (p.kind) {
        case 'text':
          await _receiveText(p, f, from: from, chatId: chatId, senderName: senderName, isGroup: g != null);
        case 'presence?':
          if (g == null) {
            _presenceWatchers[from] = DateTime.now();
            await _sendPresence(from);
          }
        case 'presence':
          if (g == null) {
            final e = p.exp;
            presence[from] = Presence(
              online: p.on == true,
              lastSeen: e == null ? null : DateTime.fromMillisecondsSinceEpoch(e * 1000),
              at: DateTime.now(),
            );
            notifyListeners();
          }
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
        case 'vote':
          {
            final m = await db.message(p.target ?? '');
            final media = m?.media;
            if (m != null && media != null && media.type == MediaType.poll && m.chatId == chatId) {
              final valid = (p.options ?? const <int>[])
                  .where((i) => i >= 0 && i < media.pollOptions.length)
                  .toSet()
                  .toList();
              final votes = Map<String, List<int>>.from(media.votes);
              if (valid.isEmpty) {
                votes.remove(from);
              } else {
                votes[from] = media.pollMulti ? valid : [valid.first];
              }
              await db.updateMessage(m.copyWith(media: media.copyWith(votes: votes)));
            }
          }
        case 'pin':
          {
            final target = p.target ?? '';
            final m = target.isEmpty ? null : await db.message(target);
            if (target.isEmpty || (m != null && m.chatId == chatId)) {
              await db.setPinned(chatId, target.isEmpty ? null : target);
              final who = g == null ? (direct?.title ?? 'Tu contacto') : senderName;
              await _system(chatId, target.isEmpty ? '📌 $who quitó el mensaje fijado' : '📌 $who fijó un mensaje');
            }
          }
        case 'loc':
          {
            final m = await db.message(p.target ?? '');
            final media = m?.media;
            final l = p.loc;
            // Solo quien comparte la ubicación puede moverla o pararla.
            final author = m != null && m.kind == MessageKind.incoming && m.chatId == chatId && (g == null || m.sender == senderName);
            if (author && media != null && media.type == MediaType.live && l != null) {
              if (l['end'] == true) {
                await db.updateMessage(m.copyWith(media: media.copyWith(liveEnded: true)));
              } else {
                final lat = (l['lat'] as num?)?.toDouble();
                final lng = (l['lng'] as num?)?.toDouble();
                if (lat != null && lng != null && lat.abs() <= 90 && lng.abs() <= 180) {
                  await db.updateMessage(
                      m.copyWith(media: media.copyWith(lat: lat, lng: lng, liveUpdatedAt: DateTime.now())));
                }
              }
            }
          }
        case 'shot':
          {
            final who = g == null ? (direct?.title ?? 'Tu contacto') : senderName;
            await _system(chatId, '📸 $who hizo una captura de pantalla del chat');
          }
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
    await _alert(chatId, msg);
    // Confirmaciones solo en chats individuales
    if (!isGroup) {
      if (_gate.canSendDelivered()) {
        await _sendEncrypted(from, Payload(kind: 'delivered', ids: [id]), ref: 'x-${_uuid.v4()}');
      }
      if (openChatId == chatId) await _sendReadReceipts(chatId);
    }
  }

  /// Sonido, notificación y número en el icono (ver core/notify/alerts.dart).
  Future<void> _alert(String chatId, Message msg) async {
    try {
      await _reloadChats();
      final chat = chats.where((c) => c.id == chatId).firstOrNull;
      if (chat == null || chat.hidden || chat.blocked) return;
      final who = chat.isGroup && msg.sender.isNotEmpty ? '${msg.sender} @ ${chat.title}' : chat.title;
      await Alerts.instance.incoming(
        chatId: chatId,
        title: who,
        text: msg.summary,
        chatOpen: openChatId == chatId,
      );
    } catch (_) {}
  }

  /// Total de mensajes sin leer en chats visibles (para el número del icono).
  int get unreadTotal => visibleChats.fold(0, (n, c) => n + (c.blocked ? 0 : c.unread));

  Future<void> _receiveProfile(Payload p, {required String from}) async {
    final db = _db!;
    await db.setBirthday(from, isValidBirthday(p.birthday) ? p.birthday : null);
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
      // En las comunidades el nombre es fijo (el mío), solo se actualizan los miembros
      await db.upsertChat(isCommunityChat(id) ? existing.copyWith(members: members) : existing.copyWith(title: title, members: members));
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
        final p = (m['p'] as String?) ?? '';
        return n.isNotEmpty ? n : (p.isEmpty ? 'Miembro' : prettyPhone(p));
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
    var chat = await _db!.chat(chatId);
    if (chat == null) throw StateError('Chat no encontrado');
    if (!chat.isGroup) {
      return _sendEncrypted(chatId, p, ref: ref, deliverAt: deliverAt, ephemeral: ephemeral);
    }
    final community = isCommunityChat(chat.id);
    if (community && !ephemeral) {
      await _syncCommunityMembers(chat.id);
      chat = await _db!.chat(chatId) ?? chat;
    }
    final members = await _membersWithKeys(chat);
    final withGroup = Payload(
      kind: p.kind,
      id: p.id,
      text: p.text,
      on: p.on,
      // En las comunidades no se envía el número de teléfono
      senderPhone: community ? null : session?.phone,
      media: p.media,
      reply: p.reply,
      exp: p.exp,
      emoji: p.emoji,
      target: p.target,
      options: p.options,
      loc: p.loc,
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
          GroupMember(id: myId, phone: isCommunityChat(chat.id) ? '' : (session?.phone ?? ''), name: profile.name)
              .toJson(withKey: false),
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
  Future<String> sendMedia(String chatId, MessageMedia media, {String caption = '', Message? replyTo}) async {
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
      if (media.type == MediaType.poll) _simulateVotes(m.id);
      if (media.type != MediaType.live) _simulateReply(chatId, m.id);
      return m.id;
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
      return m.id;
    } catch (e) {
      debugPrint('Adjunto: $e');
      await _db!.setStatus(m.id, MessageStatus.failed);
      await _refresh();
      rethrow;
    }
  }

  // ---------- Encuestas ----------

  Future<void> sendPoll(String chatId, String question, List<String> options, {bool multi = false}) async {
    final opts = options.map((o) => o.trim()).where((o) => o.isNotEmpty).toList();
    if (question.trim().isEmpty || opts.length < 2) return;
    await sendMedia(chatId,
        MessageMedia(type: MediaType.poll, pollQuestion: question.trim(), pollOptions: opts, pollMulti: multi));
  }

  /// Voto (o quito mi voto) en una encuesta.
  Future<void> vote(Message msg, int option) async {
    final m = await _db!.message(msg.id) ?? msg; // la versión más nueva, con los votos de los demás
    final media = m.media;
    if (media == null || media.type != MediaType.poll || option < 0 || option >= media.pollOptions.length) return;
    final mine = List<int>.from(media.votes['me'] ?? const <int>[]);
    if (media.pollMulti) {
      if (mine.contains(option)) {
        mine.remove(option);
      } else {
        mine.add(option);
      }
    } else if (mine.length == 1 && mine.first == option) {
      mine.clear();
    } else {
      mine
        ..clear()
        ..add(option);
    }
    final votes = Map<String, List<int>>.from(media.votes);
    if (mine.isEmpty) {
      votes.remove('me');
    } else {
      votes['me'] = mine;
    }
    await _db!.updateMessage(m.copyWith(media: media.copyWith(votes: votes)));
    await _refresh();
    if (isDemo) return;
    try {
      await _sendToChat(m.chatId, Payload(kind: 'vote', target: m.id, options: mine), ref: 'x-${_uuid.v4()}');
    } catch (_) {}
  }

  // ---------- Mensajes fijados ----------

  /// Fija un mensaje arriba del chat para todos ([m] null = quitarlo).
  Future<void> pinMessage(String chatId, Message? m) async {
    await _db!.setPinned(chatId, m?.id);
    await _system(chatId, m == null ? '📌 Quitaste el mensaje fijado' : '📌 Fijaste un mensaje');
    await _refresh();
    if (isDemo) return;
    try {
      await _sendToChat(chatId, Payload(kind: 'pin', target: m?.id ?? ''), ref: 'x-${_uuid.v4()}');
    } catch (_) {}
  }

  // ---------- Ubicación en tiempo real ----------

  /// Empieza a compartir mi ubicación durante [duration]. Se actualiza mientras
  /// KLK esté abierta (o recién cerrada); al acabar el tiempo se para sola.
  Future<void> startLiveLocation(String chatId, Duration duration, Position first) async {
    final id = await sendMedia(
      chatId,
      MessageMedia(
        type: MediaType.live,
        lat: first.latitude,
        lng: first.longitude,
        liveUntil: DateTime.now().add(duration),
        liveUpdatedAt: DateTime.now(),
      ),
    );
    _live[id]?.cancel();
    _live[id] = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20),
    ).listen((pos) => unawaited(_pushLive(chatId, id, pos)), onError: (Object _) {});
    _liveEnd[id]?.cancel();
    _liveEnd[id] = Timer(duration, () => unawaited(stopLiveLocation(id, expired: true)));
  }

  bool isSharingLive(String messageId) => _live.containsKey(messageId);

  Future<void> _pushLive(String chatId, String msgId, Position pos) async {
    final last = _livePushed[msgId];
    if (last != null && DateTime.now().difference(last).inSeconds < 10) return;
    _livePushed[msgId] = DateTime.now();
    final m = await _db?.message(msgId);
    final media = m?.media;
    if (m == null || media == null || !media.liveActive(DateTime.now())) {
      await stopLiveLocation(msgId, expired: true);
      return;
    }
    await _db!.updateMessage(
        m.copyWith(media: media.copyWith(lat: pos.latitude, lng: pos.longitude, liveUpdatedAt: DateTime.now())));
    await _refresh();
    if (isDemo) return;
    try {
      await _sendToChat(chatId, Payload(kind: 'loc', target: msgId, loc: {'lat': pos.latitude, 'lng': pos.longitude}),
          ref: 'x-loc', ephemeral: true);
    } catch (_) {}
  }

  /// Deja de compartir. [expired]: se acabó el tiempo (no hace falta avisar).
  Future<void> stopLiveLocation(String msgId, {bool expired = false}) async {
    await _live.remove(msgId)?.cancel();
    _liveEnd.remove(msgId)?.cancel();
    _livePushed.remove(msgId);
    final m = await _db?.message(msgId);
    final media = m?.media;
    if (m == null || media == null || media.type != MediaType.live) return;
    if (!expired) {
      await _db!.updateMessage(m.copyWith(media: media.copyWith(liveEnded: true)));
      if (!isDemo) {
        try {
          await _sendToChat(m.chatId, Payload(kind: 'loc', target: msgId, loc: const {'end': true}),
              ref: 'x-${_uuid.v4()}');
        } catch (_) {}
      }
    }
    await _refresh();
  }

  /// Al abrir la app, las ubicaciones en vivo que quedaron a medias se dan por terminadas.
  Future<void> _endStaleLiveLocations() async {
    final now = DateTime.now();
    for (final m in await _db!.myLiveLocations()) {
      if ((m.media?.liveActive(now) ?? false) && !_live.containsKey(m.id)) {
        await stopLiveLocation(m.id);
      }
    }
  }

  // ---------- Notas de voz a texto ----------

  /// Pasa una nota de voz a texto en el propio móvil y lo guarda en el mensaje.
  Future<String> transcribe(Message msg) async {
    final m = await _db!.message(msg.id) ?? msg;
    final media = m.media;
    final path = media?.localPath;
    if (media == null || media.type != MediaType.audio) return '';
    String text;
    if (isDemo && (path == null || !File(path).existsSync())) {
      await Future.delayed(const Duration(milliseconds: 900));
      text = demoTranscript;
    } else {
      if (path == null) throw const KlkNativeException('missing', 'Esta nota de voz aún no se ha descargado');
      text = await KlkNative.transcribe(path);
    }
    await _db!.updateMessage(m.copyWith(media: media.copyWith(transcript: text.isEmpty ? '(no se entendieron palabras)' : text)));
    await _refresh();
    return text;
  }

  // ---------- Capturas de pantalla ----------

  /// Si hago una captura dentro de un chat, se avisa a la otra parte.
  Future<void> _onScreenshot() async {
    final chatId = openChatId;
    if (chatId == null || _db == null) return;
    await _system(chatId, '📸 Hiciste una captura de pantalla. Se lo hemos dicho al chat.');
    await _refresh();
    if (isDemo) return;
    try {
      await _sendToChat(chatId, const Payload(kind: 'shot'), ref: 'x-${_uuid.v4()}');
    } catch (_) {}
  }

  // ---------- Bloquear y denunciar ----------

  Future<void> setBlocked(String chatId, bool blocked) async {
    await _db!.setBlocked(chatId, blocked);
    await _system(chatId, blocked ? '🚫 Bloqueaste a este contacto' : '✅ Desbloqueaste a este contacto');
    await _refresh();
  }

  /// Denuncia al contacto. Con [includeMessages] se envían los últimos 5
  /// mensajes que me mandó (solo esos: el resto sigue cifrado).
  Future<void> report(String chatId, String reason, {bool includeMessages = false, bool block = false}) async {
    var last = <String>[];
    if (includeMessages) {
      final received = (await _db!.messages(chatId))
          .where((m) => m.kind == MessageKind.incoming && !m.deleted && m.body.isNotEmpty)
          .map((m) => m.body)
          .toList();
      last = received.length > 5 ? received.sublist(received.length - 5) : received;
    }
    if (!isDemo) await _api!.report(chatId, reason, messages: last);
    if (block) await setBlocked(chatId, true);
  }

  // ---------- Copia de seguridad cifrada ----------

  /// Ejecuta [f] sin que lleguen mensajes a la vez (usa la misma cola que la red).
  bool _exclusiveRunning = false;

  Future<T> _exclusive<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _queue = _queue.then((_) async {
      _exclusiveRunning = true;
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      } finally {
        _exclusiveRunning = false;
      }
    });
    return c.future;
  }

  /// Crea una copia cifrada con [password]: chats, mensajes y (hasta 50 MB de)
  /// fotos, vídeos y audios. Devuelve el archivo y cuántos adjuntos no cupieron.
  Future<({File file, int media, int skipped})> exportBackup(String password) async {
    if (_db == null) throw const BackupException('KLK todavía se está abriendo');
    final dbKey = await _store.databaseKey();
    final dbBytes = await _exclusive(() async {
      await _db!.close();
      _db = null;
      try {
        return await File(await LocalDb.filePath()).readAsBytes();
      } finally {
        _db = await LocalDb.open(dbKey);
      }
    });
    final entries = <String, List<int>>{
      'meta.json': utf8.encode(jsonEncode({
        'v': 1,
        'created': DateTime.now().toUtc().toIso8601String(),
        'phone': session?.phone,
        'dbKey': dbKey,
        'profile': profile.toJson(),
        'pin': await _store.read(_pinKey),
      })),
      'klk.db': dbBytes,
    };
    var total = 0, included = 0, skipped = 0;
    final dir = await MediaStore.directory();
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync())); // primero lo más reciente
    for (final f in files) {
      final len = f.lengthSync();
      if (total + len > maxBackupMediaBytes) {
        skipped++;
        continue;
      }
      entries['media/${pth.basename(f.path)}'] = await f.readAsBytes();
      total += len;
      included++;
    }
    final sealed = await BackupCodec.seal(entries, password);
    final name = 'KLK-copia-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.klk';
    final out = File(pth.join((await getTemporaryDirectory()).path, name));
    await out.writeAsBytes(sealed, flush: true);
    return (file: out, media: included, skipped: skipped);
  }

  /// Restaura una copia: sustituye los chats de este móvil por los de la copia.
  Future<void> importBackup(String path, String password) async {
    final entries = await BackupCodec.open(await File(path).readAsBytes(), password);
    final metaBytes = entries['meta.json'];
    final dbBytes = entries['klk.db'];
    if (metaBytes == null || dbBytes == null) throw const BackupException('La copia está incompleta');
    final meta = jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;
    final dbKey = meta['dbKey'] as String?;
    if (dbKey == null || dbKey.isEmpty) throw const BackupException('La copia está dañada');

    await _exclusive(() async {
      final currentKey = await _store.databaseKey();
      await _db?.close();
      _db = null;
      final dbPath = await LocalDb.filePath();
      final backupOfCurrent = '$dbPath.antes';
      try {
        // Por si algo falla a mitad, guardo la base actual hasta terminar.
        if (await File(dbPath).exists()) await File(dbPath).copy(backupOfCurrent);
        for (final extra in ['-wal', '-shm', '-journal']) {
          final f = File('$dbPath$extra');
          if (await f.exists()) await f.delete();
        }
        await File(dbPath).writeAsBytes(dbBytes, flush: true);
        _db = await LocalDb.open(dbKey); // falla aquí si la copia no se puede abrir
        await _store.setDatabaseKey(dbKey);
      } catch (_) {
        await _db?.close();
        _db = null;
        try {
          if (await File(backupOfCurrent).exists()) await File(backupOfCurrent).copy(dbPath);
          _db = await LocalDb.open(currentKey);
        } catch (_) {
          // Muy raro: ni la copia ni la base anterior se abren. Se reintenta al reiniciar KLK.
        }
        throw const BackupException('No se pudo abrir la copia. Tus chats actuales siguen intactos.');
      } finally {
        final f = File(backupOfCurrent);
        if (await f.exists()) await f.delete();
      }
      final dir = await MediaStore.directory();
      for (final e in entries.entries) {
        if (!e.key.startsWith('media/')) continue;
        final name = pth.basename(e.key);
        if (name.isEmpty || name.startsWith('.')) continue;
        await File(pth.join(dir.path, name)).writeAsBytes(e.value, flush: true);
      }
      final prof = meta['profile'];
      if (prof is Map) {
        profile = Profile.fromJson(prof.cast<String, dynamic>());
        await _store.write(_profileKey, jsonEncode(profile.toJson()));
      }
      final pin = meta['pin'];
      if (pin is String && pin.isNotEmpty) await _store.write(_pinKey, pin);
    });
    _messages.clear();
    await _reloadChats();
    if (!isDemo) unawaited(_broadcastProfile());
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
  /// Cambia el nombre con el que veo a un contacto (o grupo, solo para mí).
  Future<void> renameChat(String chatId, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    await _db!.setTitle(chatId, n);
    await _reloadChats();
  }

  /// Elimina un contacto: su chat y todos los mensajes desaparecen de este móvil.
  /// (Como en WhatsApp, no se le avisa. Si vuelve a escribir, aparecerá como contacto nuevo.)
  Future<void> deleteContact(String chatId) async {
    // Borrar el chat de una comunidad es salirse de ella
    if (isCommunityChat(chatId) && !isDemo && _api != null) {
      try {
        await _api!.leaveCommunity(chatId.substring('community:'.length));
      } catch (_) {}
      final code = chatId.substring('community:'.length);
      communities = [for (final c in communities) c.id == code ? c.copyWith(joined: false) : c];
    }
    if (openChatId == chatId) openChatId = null;
    _messages.remove(chatId);
    await _db!.deleteChatWithMessages(chatId);
    await _reloadChats();
  }

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
  // ---------- Comunidades por país ----------

  List<Community> communities = const [];
  bool communitiesLoading = false;
  String? communitiesError;
  final Map<String, DateTime> _communitySynced = {};

  /// Carga la lista de comunidades con los miembros reales (del servidor).
  Future<void> loadCommunities() async {
    communitiesLoading = true;
    communitiesError = null;
    notifyListeners();
    try {
      if (isDemo || _api == null) {
        final joined = {for (final c in chats.where((c) => isCommunityChat(c.id))) c.id};
        communities = [
          for (final c in demoCommunities)
            c.copyWith(joined: joined.contains(c.chatId), members: joined.contains(c.chatId) ? 1 : 0),
        ];
      } else {
        communities = [for (final j in await _api!.communities()) Community.fromJson(j)];
      }
    } catch (e) {
      communitiesError = e.toString();
    } finally {
      communitiesLoading = false;
      notifyListeners();
    }
  }

  /// Unirme o salirme de una comunidad. Al unirme aparece su chat en mi lista.
  Future<void> setCommunityJoined(Community c, bool join) async {
    if (!isDemo && _api != null) {
      if (join) {
        await _api!.joinCommunity(c.id);
      } else {
        await _api!.leaveCommunity(c.id);
      }
    }
    if (join) {
      final existing = await _db!.chat(c.chatId);
      await _db!.upsertChat(existing?.copyWith(title: c.title) ??
          Chat(id: c.chatId, title: c.title, isGroup: true, members: const [], updatedAt: DateTime.now()));
      if (existing == null) {
        await _system(c.chatId,
            '${c.flag} Te uniste a la comunidad. Lo que escribas aquí lo verán todos sus miembros; tu número no se muestra.');
      }
      _communitySynced.remove(c.chatId);
      unawaited(_syncCommunityMembers(c.chatId));
    } else {
      _messages.remove(c.chatId);
      await _db!.deleteChatWithMessages(c.chatId);
    }
    communities = [
      for (final x in communities)
        x.id == c.id ? x.copyWith(joined: join, members: (x.members + (join ? 1 : -1)).clamp(0, 1 << 30).toInt()) : x,
    ];
    await _reloadChats();
  }

  /// Unirme a todas las comunidades de golpe.
  Future<void> joinAllCommunities() async {
    for (final c in communities.where((c) => !c.joined).toList()) {
      await setCommunityJoined(c, true);
    }
    await loadCommunities();
  }

  /// Pide al servidor los miembros actuales (como mucho cada 30 s) antes de enviar.
  Future<void> _syncCommunityMembers(String chatId, {bool force = false}) async {
    if (isDemo || _api == null) return;
    final last = _communitySynced[chatId];
    if (!force && last != null && DateTime.now().difference(last).inSeconds < 30) return;
    try {
      final ids = await _api!.communityMembers(chatId.substring('community:'.length));
      final chat = await _db!.chat(chatId);
      if (chat == null) return;
      final known = {for (final m in chat.members) m.id: m};
      final members = [
        for (final id in ids)
          if (id != myId) known[id] ?? GroupMember(id: id, phone: '', name: ''),
      ];
      await _db!.upsertChat(chat.copyWith(members: members));
      _communitySynced[chatId] = DateTime.now();
    } catch (e) {
      debugPrint('Miembros de la comunidad: $e');
    }
  }

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
      for (final c in chats.where((c) => !c.isGroup && !c.blocked && c.identityKey != null)) {
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
  Future<void> updateProfile({
    String? name,
    String? photoSourcePath,
    bool removePhoto = false,
    String? birthday,
    bool removeBirthday = false,
  }) async {
    String? newPhoto;
    if (photoSourcePath != null) newPhoto = await MediaStore.importFile(photoSourcePath);
    profile = profile.copyWith(
      name: name?.trim(),
      photoPath: newPhoto,
      clearPhoto: removePhoto,
      birthday: isValidBirthday(birthday) ? birthday : null,
      clearBirthday: removeBirthday,
    );
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
      final targets = chats.where(
          (c) => !c.isGroup && !c.blocked && c.identityKey != null && (onlyChatId == null || c.id == onlyChatId));
      for (final c in targets) {
        await _sendEncrypted(c.id, Payload(kind: 'profile', text: profile.name, media: photo, birthday: profile.birthday),
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
  // ---------- En línea y última conexión ----------

  /// Lo que me contó cada contacto de su presencia.
  final Map<String, Presence> presence = {};
  final Map<String, DateTime> _presenceWatchers = {}; // quién me preguntó hace poco
  bool _foreground = true;
  DateTime? _myLastSeen;
  static const _lastSeenKey = 'klk.lastSeen';

  PrivacySettings get _privacy => _ref.read(privacyProvider);

  /// Mi última conexión real (la última vez que salí de KLK).
  DateTime? get myLastSeen => _myLastSeen;

  /// ¿Comparto mi presencia con este chat? (Privacidad → Última conexión)
  bool _sharesPresenceWith(String chatId) {
    final c = chatById(chatId);
    if (c == null || c.isGroup || c.blocked) return false;
    final saved = c.title != 'Contacto nuevo' && c.title != prettyPhone(c.phone);
    return _gate.canShareLastSeenWith(isContact: saved);
  }

  Payload _myPresence() {
    final p = _privacy;
    final frozen = p.frozenLastSeen;
    final isOnline = _foreground && online && !p.hideOnline && frozen == null;
    final seen = frozen ?? (isOnline ? null : (_myLastSeen ?? DateTime.now()));
    return Payload(kind: 'presence', on: isOnline, exp: seen == null ? null : seen.millisecondsSinceEpoch ~/ 1000);
  }

  Future<void> _sendPresence(String chatId) async {
    if (isDemo || !_sharesPresenceWith(chatId)) return;
    try {
      await _sendEncrypted(chatId, _myPresence(), ref: 'x-presence', ephemeral: true);
    } catch (_) {}
  }

  /// La pantalla del chat lo llama al abrirse y cada 20 s: pregunta si el otro está en línea.
  Future<void> watchPresence(String chatId) async {
    final c = chatById(chatId);
    if (c == null || c.isGroup || c.blocked) return;
    // Reciprocidad, como WhatsApp: si no enseñas tu última conexión, no ves la de los demás
    if (!_privacy.canSeeOthersLastSeen) return;
    if (isDemo) {
      presence[chatId] = Presence(online: true, at: DateTime.now());
      notifyListeners();
      return;
    }
    try {
      await _sendEncrypted(chatId, const Payload(kind: 'presence?'), ref: 'x-presence', ephemeral: true);
    } catch (_) {}
  }

  Future<void> _announcePresence() async {
    final now = DateTime.now();
    _presenceWatchers.removeWhere((_, t) => now.difference(t).inMinutes > 3);
    final targets = {..._presenceWatchers.keys, if (openChatId != null) openChatId!};
    for (final id in targets) {
      await _sendPresence(id);
    }
  }

  /// KLK pasa a segundo plano: mi última conexión es ahora.
  void onPause() {
    _foreground = false;
    _myLastSeen = DateTime.now();
    unawaited(_store.write(_lastSeenKey, _myLastSeen!.toIso8601String()).catchError((_) {}));
    unawaited(_announcePresence());
  }

  Future<void> _loadLastSeen() async {
    try {
      _myLastSeen = DateTime.tryParse(await _store.read(_lastSeenKey) ?? '');
    } catch (_) {}
  }

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
    for (final s in _live.values) {
      await s.cancel();
    }
    for (final t in _liveEnd.values) {
      t.cancel();
    }
    _live.clear();
    _liveEnd.clear();
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
    announcements = [];
    _dismissedNews = {};
    banned = false;
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
      await _alert(chatId, reply);
    });
  }

  /// Modo demo: algunos "votan" en la encuesta que acabo de mandar.
  void _simulateVotes(String messageId) {
    final rnd = Random();
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: 1500 + i * 1100), () async {
        final m = await _db?.message(messageId);
        final media = m?.media;
        if (m == null || media == null || media.pollOptions.isEmpty) return;
        final votes = Map<String, List<int>>.from(media.votes);
        votes[demoVoters[rnd.nextInt(demoVoters.length)]] = [rnd.nextInt(media.pollOptions.length)];
        await _db?.updateMessage(m.copyWith(media: media.copyWith(votes: votes)));
        await _refresh();
      });
    }
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
    _shots?.cancel();
    for (final s in _live.values) {
      s.cancel();
    }
    for (final t in _liveEnd.values) {
      t.cancel();
    }
    _ws?.sink.close();
    _db?.close();
    super.dispose();
  }
}
