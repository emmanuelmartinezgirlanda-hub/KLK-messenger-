import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
import '../../core/crypto/signal_engine.dart';
import '../../core/database/local_db.dart';
import '../../core/l10n/l10n.dart';
import '../../core/media/media_store.dart';
import '../../core/network/api_client.dart';
import '../../core/network/link_preview.dart';
import '../../core/network/presence_gate.dart';
import '../../core/notify/alerts.dart';
import '../../core/security/secure_store.dart';
import '../calls/call_log.dart';
import '../../core/util/phone.dart';
import '../privacy/domain/privacy_settings.dart';
import '../privacy/presentation/privacy_provider.dart';
import '../communities/community.dart';
import '../plus/plus_state.dart';
import '../san/san.dart';
import '../business/business.dart';
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
  static const _plusKey = 'klk.plus.until';

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
  CryptoEngine? _crypto; // cifrado viejo (KLK-v0), solo para contactos sin actualizar
  SignalEngine? _signal; // Signal Protocol
  /// Contactos con una versión vieja de KLK (sin Signal): se les escribe con el cifrado viejo.
  final Map<String, DateTime> _legacyPeers = {};
  /// Tras "pin_required": permiso de unos minutos para terminar el registro con el PIN.
  String? pendingRegToken;
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

  /// Mi @usuario y mi correo (de la cuenta en el servidor).
  String myUsername = '';
  String myEmail = '';
  bool emailOnServer = false; // ¿el servidor manda códigos por correo?

  Future<void> loadAccountInfo() async {
    if (isDemo || _api == null) return;
    try {
      final j = await _api!.accountMe();
      myUsername = j['username'] as String? ?? '';
      myEmail = j['email'] as String? ?? '';
      emailOnServer = j['emailLogin'] == true;
      notifyListeners();
    } catch (_) {}
  }

  /// Pone (o quita, con '') mi @usuario.
  Future<void> setUsername(String username) async {
    final u = username.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (isDemo) {
      myUsername = u;
    } else {
      myUsername = await _api!.setUsername(u);
    }
    notifyListeners();
  }

  Future<void> requestLinkEmail(String email) async {
    if (isDemo) return;
    await _api!.requestLinkEmail(email.trim().toLowerCase());
  }

  Future<void> verifyLinkEmail(String email, String code) async {
    final e = email.trim().toLowerCase();
    if (isDemo) {
      if (code.trim() != KlkConfig.demoCode) {
        throw const ApiException(403, 'bad_code', 'Código incorrecto. En modo demo el código es 123456.');
      }
      myEmail = e;
    } else {
      myEmail = await _api!.verifyLinkEmail(e, code.trim());
    }
    notifyListeners();
  }

  Future<void> removeEmail() async {
    if (!isDemo) await _api!.removeEmail();
    myEmail = '';
    notifyListeners();
  }

  /// Busca a alguien por su @usuario y abre (o crea) el chat. Devuelve el id
  /// del chat, o null si no hay nadie con ese usuario.
  Future<String?> startChatWithUsername(String username) async {
    final u = username.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (u.isEmpty) return null;
    if (u == myUsername) throw const ApiException(400, 'self', 'Ese eres tú.');
    if (isDemo) return null;
    final id = await _api!.lookupUsername(u);
    if (id == null) return null;
    return startChatWithAccount(id, '@$u');
  }

  /// Mi número de teléfono (null si entré con correo: el correo no se manda a nadie).
  String? get myPhone {
    final p = session?.phone;
    return p == null || p.startsWith('mail:') ? null : p;
  }

  /// ¿Entré con correo?
  bool get signedInWithEmail => session?.phone.startsWith('mail:') ?? false;

  List<Message> messagesFor(String chatId) => _messages[chatId] ?? const [];
  bool isTyping(String chatId) => (_typingUntil[chatId]?.isAfter(DateTime.now())) ?? false;
  bool isRecording(String chatId) => (_recordingUntil[chatId]?.isAfter(DateTime.now())) ?? false;

  /// Chats de la lista principal (sin los ocultos).
  /// Chats visibles; los fijados van arriba (en el orden en que se fijaron).
  List<Chat> get visibleChats {
    final list = chats.where((c) => !c.hidden && !c.archived).toList();
    if (pinnedChats.isEmpty) return list;
    final pinned = [for (final id in pinnedChats) ...list.where((c) => c.id == id)];
    return [...pinned, ...list.where((c) => !pinnedChats.contains(c.id))];
  }

  // ---------- Archivar, silenciar, destacar, editar y notas ----------

  /// Chats archivados (no salen en la lista principal).
  List<Chat> get archivedChats => chats.where((c) => c.archived && !c.hidden).toList();

  Future<void> setArchived(String chatId, bool archived) async {
    await _db!.setArchived(chatId, archived);
    await _refresh();
  }

  /// Silencia un chat ([duration] null = siempre) o lo vuelve a activar ([unmute]).
  Future<void> setMuted(String chatId, {Duration? duration, bool unmute = false}) async {
    final until = unmute ? null : (duration == null ? DateTime(9999) : DateTime.now().add(duration));
    await _db!.setMuted(chatId, until);
    await _refresh();
  }

  Future<void> toggleStar(Message m) async {
    final fresh = await _db!.message(m.id) ?? m;
    await _db!.setStarred(m.id, !fresh.starred);
    await _refresh();
  }

  Future<List<Message>> starredMessages() async => _db == null ? const [] : _db!.starredMessages();

  /// Se puede editar un mensaje de texto mío durante 15 minutos.
  static const editWindow = Duration(minutes: 15);

  bool canEdit(Message m) =>
      m.isMine &&
      !m.deleted &&
      m.status != MessageStatus.scheduled &&
      m.status != MessageStatus.failed &&
      (m.media == null || m.body.isNotEmpty) &&
      DateTime.now().difference(m.createdAt) < editWindow;

  Future<void> editMessage(Message m, String newText) async {
    final text = newText.trim();
    if (!canEdit(m) || text.isEmpty || text == m.body) return;
    final now = DateTime.now();
    final url = firstUrl(text);
    LinkPreview? link;
    if (url != null && !isDemo) link = await LinkPreviewFetcher.fetch(url);
    await _db!.editMessage(m.id, text, now, linkJson: link == null ? null : jsonEncode(link.toJson()));
    await _refresh();
    if (isDemo || isNotesChat(m.chatId)) return;
    try {
      await _sendToChat(m.chatId, Payload(kind: 'edit', target: m.id, text: text, link: link?.toJson()),
          ref: 'x-${_uuid.v4()}');
    } catch (_) {}
  }

  bool isNotesChat(String chatId) => chatId == notesChatId;

  /// Abre (o crea) "Notas para mí": un chat contigo mismo que nunca sale del móvil.
  Future<String> openNotes() async {
    final db = _db!;
    if (await db.chat(notesChatId) == null) {
      await db.upsertChat(Chat(id: notesChatId, title: 'Notas para mí', updatedAt: DateTime.now()));
      await db.addMessage(Message(
        id: _uuid.v4(),
        chatId: notesChatId,
        kind: MessageKind.system,
        body: '📝 Guarda aquí tus notas, enlaces, fotos y audios. Solo los ves tú.',
        status: MessageStatus.read,
        createdAt: DateTime.now(),
      ));
    }
    await _refresh();
    return notesChatId;
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
    unawaited(_loadCalls());
    unawaited(_loadSanBanks());
    unawaited(_loadBlockedMembers());
    unawaited(_loadBusiness());
    await _loadPinnedChats();
    _db = await LocalDb.open(await _store.databaseKey());
    try {
      await _db!.failInterruptedUploads();
    } catch (_) {}
    final savedProfile = await _store.read(_profileKey);
    if (savedProfile != null) profile = Profile.fromJson(jsonDecode(savedProfile) as Map<String, dynamic>);
    try {
      final until = DateTime.tryParse(await _store.read(_plusKey) ?? '');
      setPlus(until); // copia guardada: Plus funciona aunque no haya conexión
    } catch (_) {}
    // Recordatorios automáticos del san (Plus), cuando ya haya conexión
    unawaited(Future.delayed(const Duration(seconds: 8), runSanAutoReminders));
    try {
      final news = await _store.read(_newsKey);
      if (news != null) _dismissedNews = (jsonDecode(news) as List).cast<String>().toSet();
    } catch (_) {}
    _crypto = await _loadCrypto();
    try {
      _signal = await SignalEngine.open(seed: base64Decode((await _store.identitySeed())!), kv: _DbSignalKv(_db!));
    } catch (e) {
      debugPrint('Signal: $e');
    }
    if (session!.isDemo) {
      if ((await _db!.chats()).isEmpty) await seedDemo(_db!);
      unawaited(_loadAnnouncements());
    } else {
      _api = ApiClient(session!.server, token: session!.token);
      unawaited(_connect());
      unawaited(loadAccountInfo());
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
    unawaited(runSanAutoReminders());
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

  /// Entrar con correo: pide el código. Luego se sigue con [verify] como con SMS.
  Future<void> requestEmailCode(String email, String server) async {
    final e = email.trim().toLowerCase();
    pendingPhone = 'mail:$e';
    pendingServer = server.trim();
    if (pendingServer.isNotEmpty) {
      await ApiClient(pendingServer).requestEmailCode(e);
    }
  }

  /// ¿El servidor deja entrar con correo? (en el modo demo, sí)
  Future<bool> emailLoginAvailable(String server) async {
    if (server.trim().isEmpty) return true;
    return ApiClient(server.trim()).emailLoginAvailable();
  }

  /// Termina el registro con el PIN de seguridad (tras "pin_required").
  Future<void> verifyPin(String pin) => verify('', pin: pin);

  Future<void> verify(String code, {String? pin}) async {
    final phone = pendingPhone!;
    if (pendingServer.isEmpty) {
      if (code != KlkConfig.demoCode) {
        throw const ApiException(403, 'bad_code', 'Código incorrecto. En modo demo el código es 123456.');
      }
      session = Session(phone: phone, server: '', accountId: 'demo-me', token: '');
    } else {
      final crypto = await _loadCrypto();
      final api = ApiClient(pendingServer);
      final ({String accountId, String token}) res;
      try {
        final deviceName = Platform.isIOS ? 'iPhone' : (Platform.isAndroid ? 'Android' : 'PC');
        final regId = Random.secure().nextInt(16380) + 1;
        res = phone.startsWith('mail:')
            ? await api.verifyEmail(
                email: phone.substring(5),
                code: pin == null ? code : '',
                regToken: pin == null ? '' : (pendingRegToken ?? ''),
                pin: pin ?? '',
                deviceName: deviceName,
                registrationId: regId,
                identityKey: crypto.identityPublic,
              )
            : await api.verify(
                phone: phone,
                code: pin == null ? code : '',
                regToken: pin == null ? '' : (pendingRegToken ?? ''),
                pin: pin ?? '',
                deviceName: deviceName,
                registrationId: regId,
                identityKey: crypto.identityPublic,
              );
      } on ApiException catch (e) {
        final tok = e.data['regToken'];
        if (tok is String && tok.isNotEmpty) pendingRegToken = tok;
        rethrow;
      }
      pendingRegToken = null;
      // Registrarse otra vez borra mis claves del servidor: hay que volver a subirlas.
      await _store.write('signal.spk.uploaded.${res.accountId}', '');
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
      unawaited(_registerPush());
      unawaited(refreshPlus());
      unawaited(_loadAnnouncements());
      unawaited(_ensureSignalKeys());
    } catch (e) {
      debugPrint('WebSocket: $e');
      if (await _checkSessionReplaced(e)) {
        _ws = null;
        online = false;
        notifyListeners();
        return;
      }
      // ¿No conecta porque el dueño bloqueó la cuenta? (como mucho 1 vez por minuto)
      if (DateTime.now().difference(_bannedCheckedAt) > const Duration(minutes: 1)) {
        _bannedCheckedAt = DateTime.now();
        unawaited(_loadAnnouncements());
      }
      _onDisconnect();
    }
  }

  /// Este número se abrió en otro dispositivo (KLK, por ahora, es de un solo
  /// dispositivo por número) y el servidor ya no acepta la sesión de aquí.
  bool sessionReplaced = false;

  /// ¿La conexión falló porque el servidor ya no acepta mi sesión?
  Future<bool> _checkSessionReplaced(Object error) async {
    if (!error.toString().contains('401') || _api == null) return false;
    try {
      await _api!.plusStatus();
      return false;
    } on ApiException catch (e) {
      if (e.status != 401) return false;
      sessionReplaced = true;
      _retry?.cancel();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Volver a entrar con mi número en este dispositivo. Los chats NO se borran:
  /// se usan la misma base de datos y las mismas claves de este móvil.
  Future<void> signInAgain() async {
    final old = session;
    _retry?.cancel();
    _tick?.cancel();
    await _ws?.sink.close();
    _ws = null;
    online = false;
    await _db?.close();
    _db = null;
    _api = null;
    _messages.clear();
    _calls = [];
    _outbox.clear();
    await _store.clearSession();
    pendingPhone = old?.phone;
    pendingServer = old?.server ?? '';
    session = null;
    sessionReplaced = false;
    phase = AppPhase.onboarding;
    notifyListeners();
  }

  void _onDisconnect() {
    _ws = null;
    if (online) {
      online = false;
      notifyListeners();
    }
    if (sessionReplaced || session == null || session!.isDemo || (_retry?.isActive ?? false)) return;
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
      final opened = await _open(from, (f['type'] as num?)?.toInt() ?? 1, base64Decode(f['content'] as String));
      if (opened == null) return;
      final p = Payload.decode(opened.plaintext);
      final identity = base64Encode(opened.senderIdentity);
      final db = _db!;
      final g = p.group;

      // Chat individual con el remitente: lo creo solo si me escribe directamente.
      var direct = await db.chat(from);
      if (direct == null && g == null) {
        if (p.kind != 'text') return;
        // El número lo pone el remitente: solo me lo creo si el servidor dice que
        // ese número es de verdad de esta cuenta (si no, alguien podría hacerse pasar por otro).
        final phone = await _verifiedPhone(p.senderPhone, from);
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

      // Grupo: el id tiene que ser de un grupo de verdad (no el de un contacto ni el de
      // mis notas) y, si ya lo tengo, quien escribe tiene que ser miembro.
      if (g != null) {
        final gid = g['id'];
        if (gid is! String || !(_groupIdRe.hasMatch(gid) || _communityIdRe.hasMatch(gid))) return;
        final known = await db.chat(gid);
        if (known != null && !known.isGroup) return;
        // Comunidad a la que no pertenezco (me salí hace poco): no se acepta nada
        if (isCommunityChat(gid) && known == null) return;
        if (known != null && !isCommunityChat(gid) && !known.members.any((m) => m.id == from)) return;
        // Bloqueado (en un grupo o comunidad, o como contacto): no recibo nada suyo.
        await _loadBlockedMembers();
        if (_blockedMembers.contains(from) || (direct?.blocked ?? false)) return;
      }

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
            if (e != null) _rememberLastSeen(from, e);
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
        case 'san':
          {
            final m = await db.message(p.target ?? '');
            final media = m?.media;
            final ev = p.san;
            if (m != null && media != null && ev != null && media.type == MediaType.san && m.chatId == chatId &&
                (ev['a'] == 'bank' || ev['a'] == 'nobank')) {
              await _receiveSanBank(m, ev, from, chatId);
            } else if (m != null && media != null && ev != null && media.type == MediaType.san && m.chatId == chatId) {
              final next = San.tryParse(media.san)?.apply(ev, from);
              if (next != null) {
                final updated = m.copyWith(media: media.copyWith(san: next.toJson()));
                await db.updateMessage(updated);
                unawaited(_scheduleSan(updated));
              }
            }
          }
        case 'biz':
          if (g == null) await _receiveBizStatus(p, from, chatId);
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
        case 'edit':
          {
            final m = await db.message(p.target ?? '');
            final text = (p.text ?? '').trim();
            // Solo el autor puede editar su mensaje
            final author = m != null &&
                m.kind == MessageKind.incoming &&
                m.chatId == chatId &&
                !m.deleted &&
                (g == null ? chatId == from : m.sender == senderName);
            if (author && text.isNotEmpty && text.length <= 65536) {
              final link = _trustedPreview(p.link, p.text ?? '');
              await db.editMessage(m.id, text, DateTime.now(),
                  linkJson: link == null ? null : jsonEncode(link.toJson()));
            }
          }
        case 'shot':
          {
            final who = g == null ? (direct?.title ?? 'Tu contacto') : senderName;
            await _system(chatId, '📸 $who hizo una captura de pantalla del chat');
          }
        case 'status':
          await _receiveStatus(p, from: from, name: direct?.title ?? prettyPhone(p.senderPhone ?? ''));
        case 'unstatus':
          {
            // Su autor borró un estado: solo puede borrar los suyos
            final gone = await db.deleteStatus(p.target ?? '', ownerId: from);
            if (gone != null) {
              try {
                await File(gone).delete();
              } catch (_) {}
            }
          }
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
    var media = p.media == null ? null : MessageMedia.fromJson(p.media!);
    if (media?.type == MediaType.san) {
      // El organizador de un san es siempre quien lo envía (y empieza sin pagos).
      final san = San.tryParse(media!.san);
      if (san == null) return;
      final fixed = San(
          name: san.name,
          amount: san.amount,
          currency: san.currency,
          period: san.period,
          start: san.start,
          organizer: from,
          slots: san.slots,
          photos: san.photos);
      media = media.copyWith(san: fixed.toJson());
    }
    if (media?.type == MediaType.biz) {
      // Un pedido o cita solo vale si me lo mandan a MÍ como negocio, en un chat
      // individual, y siempre empieza como pendiente.
      final deal = BizDeal.tryParse(media!.biz);
      if (deal == null || isGroup || deal.biz != myId) return;
      media = media.copyWith(biz: deal.fresh().toJson());
    }
    final exp = media?.type == MediaType.san || media?.type == MediaType.biz ? null : p.exp;
    final msg = Message(
      id: id,
      chatId: chatId,
      kind: MessageKind.incoming,
      sender: senderName,
      senderId: isGroup ? from : null,
      body: p.text ?? '',
      status: MessageStatus.delivered,
      createdAt: ts,
      media: media,
      replyToId: p.reply?['id'] as String?,
      replyPreview: p.reply?['p'] as String?,
      expiresAt: exp == null || exp <= 0 ? null : ts.add(Duration(seconds: exp)),
      link: _trustedPreview(p.link, p.text ?? ''),
    );
    final mentioned = isGroup && (p.mentions?.contains(myId) ?? false);
    await db.addMessage(msg, countUnread: openChatId != chatId);
    if (media?.needsDownload ?? false) unawaited(_downloadMedia(msg));
    if (media?.type == MediaType.san) unawaited(_scheduleSan(msg));
    _typingUntil.remove(chatId);
    _recordingUntil.remove(chatId);

    if (openChatId != chatId) {
      final chat = await db.chat(chatId);
      // Silenciado: sin aviso, salvo que me mencionen con @
      if (chat != null && !chat.hidden && (!chat.muted || mentioned)) onNotify?.call(chat, msg);
    }
    await _alert(chatId, msg, mentioned: mentioned);
    // Confirmaciones solo en chats individuales
    if (!isGroup) {
      if (_gate.canSendDelivered()) {
        await _sendEncrypted(from, Payload(kind: 'delivered', ids: [id]), ref: 'x-${_uuid.v4()}');
      }
      if (openChatId == chatId) await _sendReadReceipts(chatId);
    }
  }

  /// Sonido, notificación y número en el icono (ver core/notify/alerts.dart).
  Future<void> _alert(String chatId, Message msg, {bool mentioned = false}) async {
    try {
      await _reloadChats();
      final chat = chats.where((c) => c.id == chatId).firstOrNull;
      if (chat == null || chat.hidden || chat.blocked) return;
      if (chat.muted && !mentioned) return;
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
    _setAboutOf(from, About.tryParse(p.about));
    await db.setBirthday(from, isValidBirthday(p.birthday) ? p.birthday : null);
    final name = (p.text ?? '').trim();
    final current = await db.chat(from);
    // Si el chat aún muestra solo el número, usa el nombre que el contacto eligió.
    // Si no lo tengo guardado, uso el nombre que eligió, pero con «~» delante
    // (como WhatsApp): así se ve que no es un nombre puesto por mí.
    if (name.isNotEmpty && current != null && isUnsavedTitle(current.title, current.phone)) {
      final clean = name.replaceAll(RegExp(r'^[~\s]+'), '');
      if (clean.isNotEmpty) await db.setTitle(from, '~ ${clean.length > 40 ? clean.substring(0, 40) : clean}');
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

  /// La vista previa del enlace la pone el remitente: solo se acepta si su
  /// dirección está escrita en el mensaje (si no, podría enseñar un enlace y abrir otro).
  static LinkPreview? _trustedPreview(Map<String, dynamic>? j, String text) {
    if (j == null) return null;
    try {
      final lp = LinkPreview.fromJson(j);
      final u = Uri.tryParse(lp.url);
      if (u == null || !(u.scheme == 'https' || u.scheme == 'http')) return null;
      return text.contains(lp.url) ? lp : null;
    } catch (_) {
      return null;
    }
  }

  static final _groupIdRe = RegExp(r'^g-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  static final _communityIdRe = RegExp(r'^community:[A-Z]{2}$');

  /// Número que dice tener quien me escribe, comprobado con el servidor.
  /// Si no coincide con su cuenta (o no se puede comprobar), no se muestra.
  Future<String> _verifiedPhone(String? claimed, String accountId) async {
    final phone = (claimed ?? '').trim();
    if (phone.isEmpty || !isValidE164(phone) || _api == null) return '';
    try {
      return await _api!.lookup(phone) == accountId ? phone : '';
    } catch (_) {
      return '';
    }
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

  // ---------- Cifrado Signal ----------

  bool _isLegacyPeer(String accountId) {
    final t = _legacyPeers[accountId];
    return t != null && DateTime.now().difference(t) < const Duration(minutes: 10);
  }

  /// Cifra para un contacto: Signal Protocol si su app ya lo tiene; si no, el cifrado viejo.
  Future<({int type, List<int> body})> _seal(String accountId, String identityKey, List<int> plain) async {
    final sig = _signal;
    if (sig != null && _api != null && !_isLegacyPeer(accountId)) {
      if (!await sig.hasSession(accountId)) {
        final b = await _api!.bundle(accountId);
        if (b.isLegacy) {
          _legacyPeers[accountId] = DateTime.now();
        } else {
          await sig.startSession(accountId, b);
        }
      }
      if (!_isLegacyPeer(accountId)) return sig.encrypt(accountId, plain);
    }
    return (type: 1, body: await _crypto!.encrypt(plain, base64Decode(identityKey)));
  }

  /// Descifra un sobre. null = no se pudo (ya se avisó en el chat si hacía falta).
  Future<({List<int> plaintext, List<int> senderIdentity})?> _open(String from, int type, List<int> body) async {
    if (type == 1) {
      _legacyPeers[from] = DateTime.now(); // su app es vieja: le contesto con el cifrado viejo
      return _crypto!.decrypt(body);
    }
    final sig = _signal;
    if (sig == null) return null;
    try {
      final r = await sig.decrypt(from, type, body);
      _legacyPeers.remove(from);
      return r;
    } catch (e) {
      final name = e.runtimeType.toString();
      if (name.contains('Duplicate')) return null; // ya lo había recibido
      debugPrint('No se pudo descifrar ($name): $e');
      // Sesión rota (p. ej. alguien reinstaló): se empieza otra en el próximo mensaje.
      await sig.resetSession(from);
      if (await _db?.chat(from) != null) {
        await _system(from, '⚠️ No se pudo leer un mensaje de este contacto. Pídele que te lo vuelva a enviar.');
      }
      return null;
    }
  }

  /// Publica mi signed prekey y repone las claves de un solo uso cuando quedan pocas.
  bool _ensuringKeys = false;
  Future<void> _ensureSignalKeys() async {
    final sig = _signal, api = _api;
    if (sig == null || api == null || isDemo || _ensuringKeys) return;
    _ensuringKeys = true;
    try {
      final spk = await sig.signedPreKey();
      final flag = 'signal.spk.uploaded.${session?.accountId}';
      if (spk.rotated || await _store.read(flag) != '${spk.keyId}') {
        await api.putKeys(signedPreKey: (keyId: spk.keyId, publicKey: spk.publicKey, signature: spk.signature));
        await _store.write(flag, '${spk.keyId}');
      }
      if (await api.preKeyCount() < 25) {
        await api.putKeys(preKeys: await sig.newPreKeys(100));
      }
    } catch (e) {
      debugPrint('Claves Signal: $e');
    } finally {
      _ensuringKeys = false;
    }
  }

  /// Número de seguridad de un chat individual (60 cifras), o null.
  String? safetyNumber(String chatId) {
    final sig = _signal, chat = chatById(chatId), me = session;
    final key = chat?.identityKey;
    if (sig == null || chat == null || chat.isGroup || key == null || me == null) return null;
    try {
      return sig.safetyNumber(me.accountId, chat.id, base64Decode(key));
    } catch (_) {
      return null;
    }
  }

  /// ¿Este contacto ya usa el cifrado nuevo (Signal)?
  bool usesSignal(String chatId) => !_isLegacyPeer(chatId);

  // ---------- PIN de seguridad ----------

  /// Cliente del servidor para las recargas (null en modo demo o sin sesión).
  ApiClient? get topupApi => isDemo ? null : _api;

  Future<bool> pinEnabled() async => _api == null ? false : _api!.pinEnabled();
  Future<void> setRegistrationPin(String pin) => _api!.setPin(pin);
  Future<void> clearRegistrationPin() => _api!.clearPin();

  // ---------- Envío ----------

  Future<void> _sendEncrypted(String chatId, Payload p,
      {required String ref, DateTime? deliverAt, bool ephemeral = false}) async {
    if (isNotesChat(chatId)) return; // las notas nunca salen del móvil
    final chat = await _db!.chat(chatId);
    final key = chat?.identityKey;
    if (key == null) throw StateError('Sin clave del contacto');
    await _sendTo(chatId, key, p, ref: ref, deliverAt: deliverAt, ephemeral: ephemeral);
  }

  Future<void> _sendTo(String accountId, String identityKey, Payload p,
      {required String ref, DateTime? deliverAt, bool ephemeral = false}) async {
    final sealed = await _seal(accountId, identityKey, p.encode());
    final frame = jsonEncode({
      't': 'send',
      'ref': ref,
      'to': accountId,
      'messages': [
        {'device': 1, 'type': sealed.type, 'content': base64Encode(sealed.body)}
      ],
      if (deliverAt != null) 'deliverAt': deliverAt.toUtc().toIso8601String(),
      if (ephemeral) 'ephemeral': true,
      // Solo los mensajes de verdad piden aviso push (no las confirmaciones de lectura…)
      if (!ephemeral && p.kind == 'text') 'push': 'msg',
    });
    if (!ephemeral) _outbox[ref] = frame;
    _ws?.sink.add(frame);
  }

  /// Envía a un chat individual o a cada miembro de un grupo.
  Future<void> _sendToChat(String chatId, Payload p,
      {required String ref, DateTime? deliverAt, bool ephemeral = false}) async {
    if (isNotesChat(chatId)) return; // las notas nunca salen del móvil
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
      senderPhone: community ? null : myPhone,
      media: p.media,
      reply: p.reply,
      exp: p.exp,
      emoji: p.emoji,
      target: p.target,
      options: p.options,
      loc: p.loc,
      mentions: p.mentions,
      link: p.link,
      san: p.san,
      group: _groupMeta(chat, members),
    );
    for (final m in members) {
      if (m.identityKey == null) continue;
      await _sendTo(m.id, m.identityKey!, withGroup,
          ref: ephemeral ? 'x-${p.kind}' : '$ref|${m.id}', deliverAt: deliverAt, ephemeral: ephemeral);
    }
  }

  /// Envía algo solo a UNA persona de un chat (en grupos, con los datos del grupo
  /// para que le llegue al chat correcto). Lo usan los datos del banco del san.
  Future<void> _sendToChatMember(String chatId, String accountId, Payload p, {required String ref}) async {
    final chat = await _db!.chat(chatId);
    if (chat == null) throw StateError('Chat no encontrado');
    if (!chat.isGroup) {
      if (chatId != accountId) throw StateError('No es de este chat');
      return _sendEncrypted(chatId, p, ref: ref);
    }
    final members = await _membersWithKeys(chat);
    final target = members.where((m) => m.id == accountId && m.identityKey != null).firstOrNull;
    if (target == null) throw StateError('Esa persona no está en el grupo');
    await _sendTo(
        target.id,
        target.identityKey!,
        Payload(
          kind: p.kind,
          target: p.target,
          san: p.san,
          senderPhone: isCommunityChat(chat.id) ? null : myPhone,
          group: _groupMeta(chat, members),
        ),
        ref: '$ref|${target.id}');
  }

  Map<String, dynamic> _groupMeta(Chat chat, List<GroupMember> members) => {
        'id': chat.id,
        'n': chat.title,
        'm': [
          GroupMember(id: myId, phone: isCommunityChat(chat.id) ? '' : (myPhone ?? ''), name: profile.name)
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

  Future<void> sendText(String chatId, String text,
      {DateTime? at, Message? replyTo, List<String> mentions = const []}) async {
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

    // Vista previa del enlace (como mucho 4 s; si no llega, se envía sin ella).
    LinkPreview? link;
    final url = firstUrl(text);
    if (url != null && !isDemo) {
      link = await LinkPreviewFetcher.fetch(url);
      if (link != null) {
        await _db!.updateMessage(m.copyWith(link: link));
        await _refresh();
      }
    }

    if (isNotesChat(chatId)) {
      await _db!.setStatus(m.id, MessageStatus.read);
      await _refresh();
      return;
    }
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
          senderPhone: myPhone,
          reply: replyTo == null ? null : {'id': replyTo.id, 'p': m.replyPreview},
          exp: timer,
          mentions: mentions.isEmpty ? null : mentions,
          link: link?.toJson(),
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
    // El san no desaparece aunque el chat tenga mensajes temporales.
    final timer = media.type == MediaType.san || media.type == MediaType.biz ? null : _timerOf(chatId);
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

    if (isNotesChat(chatId)) {
      await _db!.setStatus(m.id, MessageStatus.read);
      await _refresh();
      return m.id;
    }
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
          senderPhone: myPhone,
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

  // ---------- San (ahorro en grupo) ----------

  /// Envía un san nuevo al chat (yo soy el organizador).
  Future<String> sendSan(String chatId, San san) async {
    final id = await sendMedia(chatId, MessageMedia(type: MediaType.san, san: san.toJson()));
    final m = await _db!.message(id);
    if (m != null) unawaited(_scheduleSan(m));
    return id;
  }

  /// Un cambio en un san: confirmar pago, avisar "ya pagué", terminarlo…
  /// Se aplica aquí y se avisa (cifrado) a todo el grupo.
  Future<bool> sanAction(Message msg, Map<String, dynamic> ev) async {
    final m = await _db!.message(msg.id) ?? msg;
    final media = m.media;
    if (media == null || media.type != MediaType.san) return false;
    final next = San.tryParse(media.san)?.apply(ev, myId);
    if (next == null) return false;
    final updated = m.copyWith(media: media.copyWith(san: next.toJson()));
    await _db!.updateMessage(updated);
    await _refresh();
    unawaited(_scheduleSan(updated));
    if (isDemo || isNotesChat(m.chatId)) return true;
    try {
      await _sendToChat(m.chatId, Payload(kind: 'san', target: m.id, san: ev), ref: 'x-${_uuid.v4()}');
    } catch (e) {
      debugPrint('San: $e');
    }
    return true;
  }

  // ---------- KLK Business: mi negocio, buscar, pedidos y citas ----------

  static const _myBizKey = 'klk.biz.me';
  static const _fiaoKey = 'klk.biz.fiao';
  BizProfile? myBusiness; // mi perfil de negocio (null = cuenta normal)
  List<FiaoAccount> fiao = [];
  bool _bizLoaded = false;

  bool get isBusiness => kBusinessFeatures && myBusiness != null;

  // Negocios con los que he hablado (para el botón de catálogo en su chat).
  static const _knownBizKey = 'klk.biz.known';
  Map<String, BizProfile> _knownBiz = {};
  BizProfile? knownBusiness(String chatId) => kBusinessFeatures ? _knownBiz[chatId] : null;

  void _rememberBusiness(BizProfile b) {
    _knownBiz = {..._knownBiz, b.id: b};
    unawaited(_store
        .write(_knownBizKey, jsonEncode([for (final x in _knownBiz.values.take(200)) x.toJson()]))
        .catchError((_) {}));
  }

  Future<void> _loadBusiness() async {
    if (_bizLoaded) return;
    _bizLoaded = true;
    try {
      myBusiness = BizProfile.tryParse(jsonDecode(await _store.read(_myBizKey) ?? 'null'));
      final known = jsonDecode(await _store.read(_knownBizKey) ?? '[]');
      _knownBiz = {
        if (known is List)
          for (final x in known)
            if (BizProfile.tryParse(x) case final b? when b.id.isNotEmpty) b.id: b,
      };
      final raw = jsonDecode(await _store.read(_fiaoKey) ?? '[]');
      fiao = [
        if (raw is List)
          for (final x in raw)
            if (FiaoAccount.tryParse(x) case final a?) a,
      ];
      notifyListeners();
    } catch (_) {}
    if (kBusinessFeatures) unawaited(refreshMyBusiness());
  }

  /// Vuelve a leer mi perfil de negocio del servidor (por si cambió en otro móvil).
  Future<void> refreshMyBusiness() async {
    if (isDemo || _api == null) return;
    try {
      final j = await _api!.myBusiness();
      myBusiness = j == null ? null : BizProfile.tryParse(j);
      await _saveMyBusinessLocal();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveMyBusinessLocal() async {
    final b = myBusiness;
    if (b == null) {
      await _store.delete(_myBizKey);
    } else {
      await _store.write(_myBizKey, jsonEncode(b.toJson()));
    }
  }

  /// Crea o cambia mi perfil de negocio (público).
  Future<BizProfile> saveMyBusiness(BizProfile p) async {
    var saved = p;
    if (!isDemo) {
      final j = await _api!.saveBusiness(p.toRequest());
      saved = BizProfile.tryParse(j) ?? p;
    } else {
      saved = BizProfile.tryParse({...p.toJson(), 'id': myId}) ?? p;
    }
    myBusiness = saved;
    await _saveMyBusinessLocal();
    notifyListeners();
    return saved;
  }

  /// Cliente del servidor (null en el modo demo). Lo usa KLK Mi Gente.
  ApiClient? get serverApi => isDemo ? null : _api;

  /// Sube una foto del negocio (logo o producto) y devuelve su id.
  Future<String> uploadBizImage(List<int> bytes) async {
    if (isDemo || _api == null) {
      throw const ApiException(0, 'demo', 'En el modo demo no se pueden subir fotos.');
    }
    return _api!.uploadBusinessImage(bytes);
  }

  /// Dirección de una foto del negocio (null si no hay o en el modo demo).
  String? bizImageUrl(String id) => id.isEmpty || _api == null ? null : _api!.businessImageUrl(id);

  /// Enlace para compartir un negocio: su página pública con logo y catálogo.
  String bizShareLink(String accountId) =>
      _api == null ? 'https://klkmessenger.com/' : _api!.businessPageUrl(accountId);

  /// Vuelvo a ser cuenta normal: el perfil deja de ser público.
  Future<void> closeMyBusiness() async {
    if (!isDemo) await _api!.deleteBusiness();
    myBusiness = null;
    await _saveMyBusinessLocal();
    notifyListeners();
  }

  Future<List<BizProfile>> searchBusinesses({String q = '', BizKind? kind, String country = ''}) async {
    if (isDemo) {
      final all = demoBusinesses();
      final t = foldForSearch(q);
      return all
          .where((b) => (kind == null || b.kind == kind) && (t.isEmpty || foldForSearch('${b.name} ${b.city}').contains(t)))
          .toList();
    }
    final list = await _api!.searchBusinesses(q: q, kind: kind?.name ?? '', country: country);
    return [
      for (final j in list)
        if (BizProfile.tryParse(j) case final b? when b.id != myId) b,
    ];
  }

  Future<BizProfile?> businessProfile(String accountId) async {
    if (isDemo) return demoBusinesses().where((b) => b.id == accountId).firstOrNull;
    try {
      final b = BizProfile.tryParse(await _api!.business(accountId));
      if (b != null && _knownBiz.containsKey(b.id)) _rememberBusiness(b);
      return b;
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Abre (o crea) el chat con un negocio. Devuelve el id del chat.
  Future<String> startChatWithBusiness(BizProfile b) async {
    if (b.id == myId) throw const ApiException(400, 'self', 'Este es tu propio negocio.');
    _rememberBusiness(b);
    return startChatWithAccount(b.id, b.name);
  }

  /// Abre (o crea) un chat con una cuenta de KLK de la que solo sé el id y
  /// el nombre (un negocio, alguien que vende en Mi Gente…). Su número no se ve.
  Future<String> startChatWithAccount(String accountId, String name) async {
    if (accountId == myId) throw const ApiException(400, 'self', 'Eres tú.');
    final existing = await _db!.chat(accountId);
    if (existing != null) {
      // Si no lo tenía guardado con nombre, le pongo este.
      if (existing.phone.isEmpty && existing.title != name && name.isNotEmpty) {
        await _db!.upsertChat(existing.copyWith(title: name));
      }
      await _reloadChats();
      return accountId;
    }
    String? identity;
    if (!isDemo) identity = base64Encode(await _api!.identityOf(accountId));
    await _db!.upsertChat(Chat(id: accountId, title: name, identityKey: identity, updatedAt: DateTime.now()));
    await _reloadChats();
    if (!isDemo) unawaited(_broadcastProfile(accountId));
    return accountId;
  }

  /// Envío un pedido o una cita al negocio. Devuelve el id del chat.
  Future<String> sendBizDeal(BizProfile b, BizDeal deal) async {
    final chatId = await startChatWithBusiness(b);
    final id = await sendMedia(chatId, MessageMedia(type: MediaType.biz, biz: deal.toJson(), name: deal.summary()));
    if (isDemo) {
      // Demo: el negocio acepta a los pocos segundos.
      Future.delayed(const Duration(seconds: 3), () async {
        final m = await _db?.message(id);
        final d = BizDeal.tryParse(m?.media?.biz);
        final next = d?.apply({'s': BizStatus.accepted}, d.biz);
        if (m == null || next == null) return;
        await _db!.updateMessage(m.copyWith(media: m.media!.copyWith(biz: next.toJson())));
        await _system(chatId, deal.isOrder ? '✅ ${b.name} aceptó tu pedido' : '✅ ${b.name} confirmó tu cita');
        await _refresh();
      });
    }
    return chatId;
  }

  /// Cambio el estado de un pedido o cita (aceptar, en camino, cancelar…).
  Future<bool> bizAction(Message msg, String status) async {
    final m = await _db!.message(msg.id) ?? msg;
    final media = m.media;
    if (media == null || media.type != MediaType.biz) return false;
    final next = BizDeal.tryParse(media.biz)?.apply({'s': status}, myId);
    if (next == null) return false;
    final updated = m.copyWith(media: media.copyWith(biz: next.toJson()));
    await _db!.updateMessage(updated);
    await _refresh();
    unawaited(_scheduleBiz(updated));
    if (isDemo || isNotesChat(m.chatId)) return true;
    try {
      await _sendToChat(m.chatId, Payload(kind: 'biz', target: m.id, biz: {'s': status}), ref: 'x-${_uuid.v4()}');
    } catch (e) {
      debugPrint('Negocio: $e');
    }
    return true;
  }

  /// Llega un cambio de estado de un pedido o cita del chat [chatId].
  Future<void> _receiveBizStatus(Payload p, String from, String chatId) async {
    final db = _db!;
    final m = await db.message(p.target ?? '');
    final media = m?.media;
    final ev = p.biz;
    if (m == null || media == null || ev == null || media.type != MediaType.biz || m.chatId != chatId) return;
    final deal = BizDeal.tryParse(media.biz);
    final next = deal?.apply(ev, from);
    if (deal == null || next == null) return;
    final updated = m.copyWith(media: media.copyWith(biz: next.toJson()));
    await db.updateMessage(updated);
    unawaited(_scheduleBiz(updated));
    final who = from == deal.biz ? deal.bizName : (chatById(chatId)?.title ?? 'El cliente');
    final what = deal.isOrder ? 'tu pedido' : 'tu cita';
    final text = switch (next.status) {
      BizStatus.accepted => deal.isOrder ? '✅ $who aceptó $what' : '✅ $who confirmó $what',
      BizStatus.rejected => '❌ $who no puede atender $what',
      BizStatus.onTheWay => '🛵 $what de $who va en camino',
      BizStatus.done => deal.isOrder ? '📦 $who marcó $what como entregado' : '✅ $who marcó $what como atendida',
      BizStatus.cancelled => '🚫 $who canceló ${deal.isOrder ? 'el pedido' : 'la cita'}',
      _ => '',
    };
    if (text.isEmpty) return;
    await _system(chatId, text);
    final chat = await db.chat(chatId);
    if (chat != null && openChatId != chatId && !chat.hidden && !chat.muted) {
      onNotify?.call(chat, Message(
        id: 'biz-${m.id}-${next.status}',
        chatId: chatId,
        kind: MessageKind.incoming,
        body: text,
        status: MessageStatus.delivered,
        createdAt: DateTime.now(),
      ));
    }
  }

  /// Recordatorio de una cita confirmada: 1 hora antes (cliente y negocio).
  Future<void> _scheduleBiz(Message m) async {
    final deal = BizDeal.tryParse(m.media?.biz);
    if (deal == null || !deal.isBooking || deal.at == null) return;
    final id = 'biz-cita-${m.id}'.hashCode & 0x3fffffff;
    final at = deal.at!.subtract(const Duration(hours: 1));
    if (deal.status == BizStatus.accepted && at.isAfter(DateTime.now())) {
      final mineIsBiz = deal.biz == myId;
      final who = mineIsBiz ? (chatById(m.chatId)?.title ?? 'un cliente') : deal.bizName;
      await Alerts.instance.scheduleAt(id, '📅 Cita en 1 hora',
          '${deal.service}${mineIsBiz ? ' con $who' : ' en $who'} a las ${DateFormat('h:mm a', 'es').format(deal.at!)}.', at,
          chatId: m.chatId);
    } else {
      await Alerts.instance.cancelScheduled(id);
    }
  }

  /// Citas ya pedidas a este negocio (para no ofrecer esas horas otra vez desde este móvil).
  Future<Set<DateTime>> bookedSlots(String bizId) async {
    if (_db == null) return {};
    final out = <DateTime>{};
    for (final m in await _db!.messagesOfType(bizId, MediaType.biz)) {
      final d = BizDeal.tryParse(m.media?.biz);
      if (d != null && d.isBooking && d.at != null && !d.closed) out.add(d.at!);
    }
    return out;
  }

  // ---------- La libreta del fiao (solo en este móvil) ----------

  void _saveFiao() {
    unawaited(_store.write(_fiaoKey, jsonEncode([for (final a in fiao) a.toJson()])).catchError((_) {}));
    notifyListeners();
  }

  double get fiaoTotal => fiao.fold(0.0, (t, a) => t + (a.balance > 0 ? a.balance : 0));

  /// Apunta [amount] a la cuenta de un cliente (negativo = pagó). La crea si no existe.
  void fiaoAdd({required String id, required String name, required double amount, String note = ''}) {
    final i = fiao.indexWhere((a) => (id.isNotEmpty && a.id == id) || (id.isEmpty && a.id.isEmpty && a.name == name));
    final e = FiaoEntry(amount, note, DateTime.now());
    if (i < 0) {
      fiao = [...fiao, FiaoAccount(id: id, name: name, entries: [e])];
    } else {
      fiao = [...fiao]..[i] = fiao[i].add(e);
    }
    _saveFiao();
  }

  void fiaoRemove(FiaoAccount a) {
    fiao = fiao.where((x) => !identical(x, a)).toList();
    _saveFiao();
  }

  /// Le mando al cliente (por el chat, cifrado) cuánto debe.
  Future<void> fiaoRemind(FiaoAccount a) async {
    final b = myBusiness;
    if (a.id.isEmpty || b == null) return;
    await sendText(a.id,
        'Hola ${a.name.split(' ').first} 👋 Tu cuenta en ${b.name} es de ${bizMoney(a.balance, b.currency)}. Cuando puedas, pasa a saldarla. ¡Gracias! 🙏');
    final i = fiao.indexOf(a);
    if (i >= 0) {
      fiao = [...fiao]..[i] = a.reminded(DateTime.now());
      _saveFiao();
    }
  }

  // ---------- Datos del banco para cobrar el san ----------
  // Solo en este móvil (cifrado). Quien organiza ve los de los demás; cada uno, los suyos.
  static const _sanBanksKey = 'klk.san.banks';
  static const _myBankKey = 'klk.san.mybank';
  Map<String, Map<String, SanBank>> _sanBanks = {}; // idMensaje -> cuenta -> datos
  SanBank? _myLastBank; // para rellenar el formulario la próxima vez
  bool _sanBanksLoaded = false;

  SanBank? sanBankOf(String messageId, String accountId) => _sanBanks[messageId]?[accountId];
  SanBank? get myLastSanBank => _myLastBank;

  Future<void> _loadSanBanks() async {
    if (_sanBanksLoaded) return;
    _sanBanksLoaded = true;
    try {
      final raw = await _store.read(_sanBanksKey);
      if (raw != null && raw.isNotEmpty) {
        _sanBanks = {
          for (final e in (jsonDecode(raw) as Map).entries)
            e.key as String: {
              for (final b in (e.value as Map).entries)
                if (SanBank.tryParse(b.value) case final bank?) b.key as String: bank,
            },
        };
      }
      _myLastBank = SanBank.tryParse(jsonDecode(await _store.read(_myBankKey) ?? 'null'));
      notifyListeners();
    } catch (_) {}
  }

  void _saveSanBanks() {
    unawaited(_store
        .write(_sanBanksKey,
            jsonEncode({for (final e in _sanBanks.entries) e.key: {for (final b in e.value.entries) b.key: b.value.toJson()}}))
        .catchError((_) {}));
  }

  /// Guardo MIS datos para cobrar este san y se los mando (cifrados) solo a quien organiza.
  /// [bank] null = borrarlos.
  Future<bool> shareSanBank(Message msg, SanBank? bank) async {
    await _loadSanBanks();
    final san = San.tryParse(msg.media?.san);
    if (san == null || san.slotsOf(myId).isEmpty) return false;
    final mine = Map<String, SanBank>.from(_sanBanks[msg.id] ?? const {});
    if (bank == null) {
      mine.remove(myId);
    } else {
      mine[myId] = bank;
      _myLastBank = bank;
      unawaited(_store.write(_myBankKey, jsonEncode(bank.toJson())).catchError((_) {}));
    }
    _sanBanks[msg.id] = mine;
    _saveSanBanks();
    notifyListeners();
    if (san.organizer == myId || isDemo) return true;
    try {
      await _sendToChatMember(
        msg.chatId,
        san.organizer,
        Payload(kind: 'san', target: msg.id, san: bank == null ? {'a': 'nobank'} : {'a': 'bank', ...bank.toJson()}),
        ref: 'x-${_uuid.v4()}',
      );
      return true;
    } catch (e) {
      debugPrint('San banco: $e');
      return false;
    }
  }

  Future<void> _receiveSanBank(Message m, Map<String, dynamic> ev, String from, String chatId) async {
    await _loadSanBanks();
    final san = San.tryParse(m.media?.san);
    // Solo me sirve si yo organizo y quien lo manda tiene número en el san.
    if (san == null || san.organizer != myId) return;
    final slot = san.slots.where((x) => x.id == from).firstOrNull;
    if (slot == null) return;
    final banks = Map<String, SanBank>.from(_sanBanks[m.id] ?? const {});
    final old = banks[from];
    if (ev['a'] == 'nobank') {
      if (banks.remove(from) == null) return;
      await _system(chatId, '🏦 ${slot.name} quitó su cuenta para cobrar el san «${san.name}».');
    } else {
      final bank = SanBank.tryParse(ev);
      if (bank == null) return;
      banks[from] = bank;
      if (old == null) {
        await _system(chatId, '🏦 ${slot.name} añadió su cuenta para cobrar el san «${san.name}». Solo la ves tú.');
      } else if (!old.sameAccount(bank)) {
        await _system(chatId,
            '⚠️ ${slot.name} CAMBIÓ su cuenta para cobrar el san «${san.name}». Antes de enviar dinero, confírmalo con esa persona (llámala).');
      }
    }
    _sanBanks[m.id] = banks;
    _saveSanBanks();
    notifyListeners();
  }

  /// Cuántos sanes organizo que siguen en marcha (sin Plus solo se puede uno a la vez).
  Future<int> activeSansIOrganize() async {
    final db = _db;
    if (db == null) return 0;
    final now = DateTime.now();
    var n = 0;
    for (final m in await db.sanMessages()) {
      final san = San.tryParse(m.media?.san);
      if (san != null && san.organizer == myId && !san.finished(now)) n++;
    }
    return n;
  }

  // ---------- Recordatorios automáticos del san (KLK Plus) ----------
  // Quien organiza los activa; al abrir KLK, si mañana (o ya) toca pagar y falta
  // gente, se manda solo un recordatorio al chat. Uno por turno.
  static const _sanAutoKey = 'klk.san.auto';
  Map<String, List<int>> _sanAuto = {}; // idMensaje -> turnos ya recordados
  bool _sanAutoLoaded = false;
  bool _sanAutoRunning = false;

  bool sanAutoOn(String messageId) => _sanAuto.containsKey(messageId);

  Future<void> _loadSanAuto() async {
    if (_sanAutoLoaded) return;
    _sanAutoLoaded = true;
    try {
      final raw = await _store.read(_sanAutoKey);
      if (raw != null && raw.isNotEmpty) {
        _sanAuto = (jsonDecode(raw) as Map).map(
            (k, v) => MapEntry(k as String, [for (final x in (v as List)) if (x is num) x.toInt()]));
      }
    } catch (_) {}
  }

  void _saveSanAuto() =>
      unawaited(_store.write(_sanAutoKey, jsonEncode(_sanAuto)).catchError((_) {}));

  Future<void> setSanAuto(String messageId, bool on) async {
    await _loadSanAuto();
    if (on) {
      _sanAuto.putIfAbsent(messageId, () => []);
    } else {
      _sanAuto.remove(messageId);
    }
    _saveSanAuto();
    notifyListeners();
    if (on) unawaited(runSanAutoReminders());
  }

  Future<void> runSanAutoReminders() async {
    await _loadSanAuto();
    final db = _db;
    if (db == null || isDemo || !plusActive.value || _sanAuto.isEmpty || _sanAutoRunning) return;
    _sanAutoRunning = true;
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      for (final id in _sanAuto.keys.toList()) {
        final m = await db.message(id);
        final san = San.tryParse(m?.media?.san);
        if (m == null || san == null || san.organizer != myId || san.finished(now)) {
          _sanAuto.remove(id);
          continue;
        }
        final done = _sanAuto[id]!;
        for (var r = 0; r < san.rounds; r++) {
          final day = san.dateOf(r);
          final from = day.subtract(const Duration(days: 1));
          final until = day.add(const Duration(days: 3));
          if (done.contains(r) || san.roundComplete(r) || today.isBefore(from) || today.isAfter(until)) continue;
          final pending = <String>{
            for (var s = 0; s < san.slots.length; s++)
              if (san.payOf(r, s) != SanPay.paid) san.slots[s].name,
          }.toList();
          final when = today.isBefore(day) ? 'mañana' : (today == day ? 'hoy' : 'ya');
          await sendText(
              m.chatId,
              '⏰ Recordatorio del san «${san.name}» (automático)\n'
              'Turno ${r + 1}: le toca a ${san.slots[r].name} — $when.\n'
              'Faltan por pagar: ${pending.join(', ')}. Cada número: ${san.money(san.amount)}. 🙏');
          done.add(r);
          break; // uno por san cada vez
        }
      }
      _saveSanAuto();
    } catch (e) {
      debugPrint('San automático: $e');
    } finally {
      _sanAutoRunning = false;
    }
  }

  /// Avisos en el móvil: el día antes de pagar y el día que me toca cobrar.
  Future<void> _scheduleSan(Message m) async {
    final san = San.tryParse(m.media?.san);
    if (san == null) return;
    final now = DateTime.now();
    final mine = san.slotsOf(myId);
    final chat = chatById(m.chatId);
    for (var r = 0; r < san.rounds; r++) {
      final payId = 'san-pay-${m.id}-$r'.hashCode & 0x3fffffff;
      final getId = 'san-get-${m.id}-$r'.hashCode & 0x3fffffff;
      final day = san.dateOf(r);
      final payAt = DateTime(day.year, day.month, day.day - 1, 10);
      final getAt = DateTime(day.year, day.month, day.day, 9);
      final active = !san.finished(now) && mine.isNotEmpty && r >= san.currentRound(now) && r < san.currentRound(now) + 4;
      final owe = mine.where((s) => san.payOf(r, s) != SanPay.paid).length;
      if (active && owe > 0 && payAt.isAfter(now)) {
        await Alerts.instance.scheduleAt(payId, '🤝 Mañana toca el san «${san.name}»',
            'Te toca poner ${san.money(san.amount * owe)} para ${san.slots[r].name}.', payAt, chatId: m.chatId);
      } else {
        await Alerts.instance.cancelScheduled(payId);
      }
      if (active && san.slots[r].id == myId && getAt.isAfter(now)) {
        await Alerts.instance.scheduleAt(getId, '🎉 ¡Hoy te toca el san!',
            '«${san.name}»${chat == null ? '' : ' en ${chat.title}'}: te llevas ${san.money(san.pot)}.', getAt,
            chatId: m.chatId);
      } else {
        await Alerts.instance.cancelScheduled(getId);
      }
    }
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
    if (blocked) _notifyBlock(chatId);
    await _refresh();
  }

  /// Apple (1.2): al bloquear también avisamos al equipo de KLK, que lo revisa
  /// en 24 horas. Si no hay red, el bloqueo vale igual en este móvil.
  void _notifyBlock(String accountId) {
    if (isDemo || _api == null) return;
    _api!.blockNotice(accountId).catchError((_) {});
  }

  // ---------- Bloquear y denunciar en grupos y comunidades ----------
  static const _blockedMembersKey = 'klk.blocked.members';
  Set<String> _blockedMembers = {};
  bool _blockedMembersLoaded = false;

  Future<void> _loadBlockedMembers() async {
    if (_blockedMembersLoaded) return;
    _blockedMembersLoaded = true;
    try {
      final raw = await _store.read(_blockedMembersKey);
      if (raw != null && raw.isNotEmpty) _blockedMembers = (jsonDecode(raw) as List).cast<String>().toSet();
    } catch (_) {}
  }

  /// ¿Bloqueé a esta persona (en grupos y comunidades, o como contacto)?
  bool isMemberBlocked(String accountId) =>
      _blockedMembers.contains(accountId) || (chatById(accountId)?.blocked ?? false);

  /// Bloquea (o desbloquea) a alguien de un grupo o comunidad: sus mensajes dejan de llegarme.
  Future<void> setMemberBlocked(String accountId, String name, bool blocked, {String? inChatId}) async {
    await _loadBlockedMembers();
    if (blocked) {
      _notifyBlock(accountId);
      _blockedMembers.add(accountId);
    } else {
      _blockedMembers.remove(accountId);
    }
    await _store.write(_blockedMembersKey, jsonEncode(_blockedMembers.toList()));
    if (chatById(accountId) != null) await _db!.setBlocked(accountId, blocked);
    if (inChatId != null) {
      await _system(inChatId, blocked ? '🚫 Bloqueaste a $name: ya no verás sus mensajes' : '✅ Desbloqueaste a $name');
    }
    await _refresh();
  }

  /// Denuncia a alguien de un grupo o comunidad. [messages]: lo que yo decida adjuntar.
  Future<void> reportMember(String accountId, String reason,
      {List<String> messages = const [], bool block = false, String name = '', String? inChatId}) async {
    if (!isDemo) await _api!.report(accountId, reason, messages: messages.take(5).toList());
    if (block) await setMemberBlocked(accountId, name, true, inChatId: inChatId);
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
        if (media.viewOnce || media.type == MediaType.biz) continue;
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

  /// Vacía un chat: se borran todos los mensajes de este móvil, el contacto se queda.
  Future<void> clearChat(String chatId) async {
    _messages.remove(chatId);
    await _db!.clearChat(chatId);
    await _reloadChats();
    await _refresh();
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
        // Si el servidor dice que estoy dentro pero el chat no está en este móvil
        // (otro móvil, reinstalación…), lo creo para poder escribir.
        var added = false;
        for (final c in communities.where((c) => c.joined)) {
          if (await ensureCommunityChat(c, reload: false)) added = true;
        }
        if (added) await _reloadChats();
      }
    } catch (e) {
      communitiesError = e.toString();
    } finally {
      communitiesLoading = false;
      notifyListeners();
    }
  }

  /// Crea el chat de una comunidad en este móvil si falta. Devuelve si lo creó.
  Future<bool> ensureCommunityChat(Community c, {bool reload = true}) async {
    final db = _db;
    if (db == null) return false;
    final existing = await db.chat(c.chatId);
    if (existing != null) {
      if (existing.title != c.title) {
        await db.setTitle(c.chatId, c.title);
        if (reload) await _reloadChats();
      }
      return false;
    }
    await db.upsertChat(Chat(id: c.chatId, title: c.title, isGroup: true, members: const [], updatedAt: DateTime.now()));
    await _system(c.chatId,
        '${c.flag} Estás en la comunidad. Lo que escribas aquí lo verán todos sus miembros; tu número no se muestra.');
    _communitySynced.remove(c.chatId);
    unawaited(_syncCommunityMembers(c.chatId));
    if (reload) await _reloadChats();
    return true;
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
        senderPhone: myPhone,
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

  /// Borra un estado mío aquí y en los móviles de mis contactos.
  Future<void> deleteStatus(StatusPost post) async {
    if (!post.isMine) return;
    final path = await _db!.deleteStatus(post.id, ownerId: 'me');
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await _reloadChats();
    if (isDemo) return;
    try {
      final payload = Payload(kind: 'unstatus', target: post.id, senderPhone: myPhone);
      for (final c in chats.where((c) => !c.isGroup && !c.blocked && c.identityKey != null)) {
        await _sendTo(c.id, c.identityKey!, payload, ref: 'x-${_uuid.v4()}');
        await Future.delayed(const Duration(milliseconds: 60));
      }
    } catch (e) {
      debugPrint('Borrar estado: $e');
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

  // ---------- KLK Plus ----------

  /// Hasta cuándo tiene Plus esta cuenta (null = no tiene).
  DateTime? get plusUntil => plusUntilNotifier.value;
  bool get plus => plusActive.value;

  /// Pregunta al servidor si hay Plus (al conectar).
  Future<void> refreshPlus() async {
    if (isDemo || _api == null) return;
    try {
      final j = await _api!.plusStatus();
      await _savePlus(j);
    } catch (e) {
      debugPrint('Plus: $e');
    }
    // Renovaciones de Apple: si la suscripción sigue activa, se la paso al servidor.
    if (!plusActive.value && KlkNative.supportsStore) {
      try {
        final jws = await KlkNative.storeEntitlements();
        if (jws.isNotEmpty) await _savePlus(await _api!.plusApple(jws));
      } catch (e) {
        debugPrint('Plus Apple: $e');
      }
    }
  }

  /// Productos de KLK Plus en el App Store (se crean en App Store Connect).
  static const plusProducts = ['klk.plus.mensual', 'klk.plus.anual'];

  /// Compra KLK Plus con Apple. Apple cobra; el servidor comprueba la compra.
  Future<void> buyPlus(String productId) async {
    if (_api == null) throw const ApiException(0, 'demo', 'Entra con tu número para comprar KLK Plus.');
    final jws = await KlkNative.storeBuy(productId, accountId: session?.accountId);
    await _savePlus(await _api!.plusApple([jws]));
  }

  /// «Restaurar compras»: recupera una suscripción ya pagada con este Apple ID.
  Future<bool> restorePlus() async {
    if (_api == null) return false;
    final jws = await KlkNative.storeEntitlements(sync: true);
    if (jws.isEmpty) return false;
    await _savePlus(await _api!.plusApple(jws));
    return plusActive.value;
  }

  /// Activa Plus con un código (solo en versiones de prueba). Lanza ApiException si no vale.
  Future<void> redeemPlus(String code) async {
    if (_api == null) throw const ApiException(0, 'demo', 'Entra con tu número para activar KLK Plus.');
    final j = await _api!.redeemPlus(code.trim());
    await _savePlus(j);
  }

  Future<void> _savePlus(Map<String, dynamic> j) async {
    final until = j['active'] == true ? DateTime.tryParse(j['until'] as String? ?? '') : null;
    setPlus(until);
    try {
      await _store.write(_plusKey, until?.toIso8601String() ?? '');
    } catch (_) {}
    notifyListeners();
  }

  bool _pushRegistered = false;

  /// Avisos push: le da al servidor el token de Apple (iPhone) o de Firebase
  /// (Android) para que avise cuando llegue un mensaje con KLK cerrada. El
  /// aviso no lleva el mensaje.
  Future<void> _registerPush() async {
    final android = Platform.isAndroid && KlkConfig.firebase != null;
    if (_pushRegistered || isDemo || _api == null || !(Platform.isIOS || android)) return;
    _pushRegistered = true;
    try {
      final token = await KlkNative.registerPush(android: android ? KlkConfig.firebase : null);
      if (token == null || token.isEmpty) return;
      await _api!.setPushToken(android ? 'fcm' : 'apns', token, currentLanguageCode());
    } catch (e) {
      _pushRegistered = false; // se reintenta en la próxima conexión
      debugPrint('Avisos push: $e');
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

  // ---------- Perfil ----------

  /// Cambia mi nombre y/o foto y lo envía (cifrado) a mis contactos.
  Future<void> updateProfile({
    String? name,
    String? photoSourcePath,
    bool removePhoto = false,
    String? birthday,
    bool removeBirthday = false,
    About? about,
    bool removeAbout = false,
  }) async {
    String? newPhoto;
    if (photoSourcePath != null) newPhoto = await MediaStore.importFile(photoSourcePath);
    profile = profile.copyWith(
      name: name?.trim(),
      photoPath: newPhoto,
      clearPhoto: removePhoto,
      birthday: isValidBirthday(birthday) ? birthday : null,
      clearBirthday: removeBirthday,
      about: about,
      clearAbout: removeAbout,
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
        await _sendEncrypted(c.id, Payload(
                kind: 'profile',
                text: profile.name,
                media: photo,
                birthday: profile.birthday,
                about: profile.activeAbout(DateTime.now())?.toJson()),
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
  Future<void> logCall(String chatId, String text,
      {bool incoming = false, bool video = false, bool missed = false, int durationMs = 0}) async {
    await _system(chatId, text);
    _addCall(CallRecord(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      chatId: chatId,
      at: DateTime.now(),
      video: video,
      incoming: incoming,
      missed: missed,
      durationMs: durationMs,
    ));
    await _refresh();
  }

  // Servidores para conectar llamadas. Se guardan un rato para que la llamada empiece antes.
  List<Map<String, dynamic>>? _iceServers;
  DateTime _iceServersAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<List<Map<String, dynamic>>> callServers() async {
    final cached = _iceServers;
    if (cached != null && DateTime.now().difference(_iceServersAt) < const Duration(minutes: 30)) return cached;
    final api = _api;
    if (api == null || isDemo) return const [];
    final list = await api.turnServers();
    _iceServers = list;
    _iceServersAt = DateTime.now();
    return list;
  }

  // ---------- Historial de llamadas (pestaña «Llamadas») ----------
  static const _callsKey = 'klk.calls';
  static const _callsSeenKey = 'klk.calls.seen';
  List<CallRecord> _calls = [];
  DateTime _callsSeen = DateTime.fromMillisecondsSinceEpoch(0);

  /// Llamadas, de la más nueva a la más vieja.
  List<CallRecord> get callLog => List.unmodifiable(_calls);

  /// Llamadas perdidas que aún no vi en la pestaña «Llamadas».
  int get newMissedCalls => _calls.where((c) => c.missedIncoming && c.at.isAfter(_callsSeen)).length;

  void markCallsSeen() {
    if (newMissedCalls == 0) return;
    _callsSeen = DateTime.now();
    unawaited(_store.write(_callsSeenKey, _callsSeen.toIso8601String()).catchError((_) {}));
    notifyListeners();
  }

  void _addCall(CallRecord r) {
    _calls = [r, ..._calls];
    if (_calls.length > 300) _calls = _calls.sublist(0, 300);
    _saveCalls();
  }

  void removeCall(String id) {
    _calls = _calls.where((c) => c.id != id).toList();
    _saveCalls();
    notifyListeners();
  }

  void clearCallLog() {
    _calls = [];
    _saveCalls();
    notifyListeners();
  }

  void _saveCalls() {
    unawaited(_store.write(_callsKey, jsonEncode([for (final c in _calls) c.toJson()])).catchError((_) {}));
  }

  Future<void> _loadCalls() async {
    try {
      final raw = await _store.read(_callsKey);
      if (raw != null && raw.isNotEmpty) {
        _calls = [
          for (final e in jsonDecode(raw) as List)
            if (CallRecord.tryParse(e) case final c?) c,
        ];
      }
      _callsSeen = DateTime.tryParse(await _store.read(_callsSeenKey) ?? '') ?? _callsSeen;
      notifyListeners();
    } catch (_) {}
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
    final saved = !isUnsavedTitle(c.title, c.phone);
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
    unawaited(_leaveLastSeen());
  }

  // Las preguntas de "¿estás en línea?" solo llegan si el otro tiene KLK abierta.
  // Para que se vea la última conexión aunque esté cerrada, al salir de KLK dejo
  // (cifrada y guardada en el servidor hasta que la recojan) mi hora de salida a
  // los chats recientes que tienen permiso para verla según mi privacidad.
  DateTime _lastLeftAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _seenOfKey = 'klk.presence.seen';
  Map<String, int> _seenOf = {}; // accountId -> última conexión (segundos)

  Future<void> _leaveLastSeen() async {
    if (isDemo || _api == null) return;
    final now = DateTime.now();
    if (now.difference(_lastLeftAt) < const Duration(minutes: 5)) return;
    _lastLeftAt = now;
    final week = now.subtract(const Duration(days: 7));
    final recent = chats
        .where((c) => !c.isGroup && !c.blocked && !c.isNotes && c.identityKey != null && c.updatedAt.isAfter(week))
        .take(25)
        .toList();
    final me = _myPresence();
    for (final c in recent) {
      if (!_sharesPresenceWith(c.id)) continue;
      try {
        await _sendEncrypted(c.id, me, ref: 'x-seen-${_uuid.v4()}');
      } catch (_) {}
    }
  }

  void _rememberLastSeen(String accountId, int secs) {
    if ((_seenOf[accountId] ?? 0) >= secs) return;
    _seenOf[accountId] = secs;
    unawaited(_store.write(_seenOfKey, jsonEncode(_seenOf)).catchError((_) {}));
  }

  // «Info» de mis contactos (Ausente, En el trabajo…). Se guarda en el móvil.
  static const _aboutKey = 'klk.about';
  Map<String, About> _aboutOf = {};

  /// «Info» vigente de un contacto (null si no tiene o ya caducó).
  About? aboutOf(String accountId) {
    final a = _aboutOf[accountId];
    return a != null && a.activeAt(DateTime.now()) ? a : null;
  }

  void _setAboutOf(String accountId, About? a) {
    if (a == null) {
      if (_aboutOf.remove(accountId) == null) return;
    } else {
      _aboutOf[accountId] = a;
    }
    final now = DateTime.now();
    _aboutOf.removeWhere((_, v) => !v.activeAt(now));
    unawaited(_store
        .write(_aboutKey, jsonEncode(_aboutOf.map((k, v) => MapEntry(k, v.toJson()))))
        .catchError((_) {}));
  }

  Future<void> _loadLastSeen() async {
    try {
      final raw = await _store.read(_aboutKey);
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map;
        _aboutOf = {
          for (final e in m.entries)
            if (About.tryParse(e.value) case final a?) e.key as String: a,
        };
      }
    } catch (_) {}
    try {
      _myLastSeen = DateTime.tryParse(await _store.read(_lastSeenKey) ?? '');
    } catch (_) {}
    try {
      final raw = await _store.read(_seenOfKey);
      if (raw != null && raw.isNotEmpty) {
        _seenOf = (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
        for (final e in _seenOf.entries) {
          presence.putIfAbsent(
              e.key,
              () => Presence(
                  online: false,
                  lastSeen: DateTime.fromMillisecondsSinceEpoch(e.value * 1000),
                  at: DateTime.fromMillisecondsSinceEpoch(e.value * 1000)));
        }
      }
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
  String get myDialCode => dialCodeOf(myPhone ?? '+1');

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
    var title = name.trim().isEmpty ? prettyPhone(phone) : name.trim();
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
    String id;
    var verifiedPhone = phone;
    if (knownAccountId != null) {
      id = knownAccountId;
      // El número de un miembro de grupo lo puso otro miembro: lo compruebo.
      verifiedPhone = await _verifiedPhone(phone, id);
    } else {
      id = await _api!.lookup(phone);
    }
    if (name.trim().isEmpty) title = verifiedPhone.isEmpty ? 'Contacto nuevo' : prettyPhone(verifiedPhone);
    final identity = base64Encode(await _api!.identityOf(id));
    final existing = await _db!.chat(id);
    await _db!.upsertChat(existing?.copyWith(title: title, identityKey: identity) ??
        Chat(id: id, title: title, phone: verifiedPhone, identityKey: identity, updatedAt: DateTime.now()));
    await _reloadChats();
    if (existing == null) unawaited(_broadcastProfile(id));
    return id;
  }

  /// Botón de pánico: borra la base de datos y todas las claves de este móvil.
  /// Elimina la cuenta del servidor (después hay que llamar a [panic] para borrar el móvil).
  Future<void> deleteAccountOnServer() async {
    if (!isDemo && _api != null) await _api!.deleteAccount();
  }

  Future<void> panic() async {
    _signal = null;
    _legacyPeers.clear();
    pendingRegToken = null;
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
    _blockedMembers = {};
    _sanAuto = {};
    _sanBanks = {};
    _myLastBank = null;
    myBusiness = null;
    fiao = [];
    _knownBiz = {};
    _bizLoaded = false;
    _calls = [];
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


/// Las claves de Signal se guardan en la base de datos cifrada (SQLCipher).
class _DbSignalKv implements SignalKeyValue {
  _DbSignalKv(this._db);
  final LocalDb _db;
  @override
  Future<Uint8List?> get(String key) => _db.kvGet(key);
  @override
  Future<void> put(String key, List<int> value) => _db.kvPut(key, value);
  @override
  Future<void> delete(String key) => _db.kvDelete(key);
  @override
  Future<List<String>> keys(String prefix) => _db.kvKeys(prefix);
}
