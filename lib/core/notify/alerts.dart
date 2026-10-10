import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../security/secure_store.dart';

/// Avisos de mensajes nuevos: sonido, notificación y número en el icono.
///
/// - Con la app abierta en otro chat: suena (el aviso visual ya lo pone la pantalla de inicio).
/// - Con el chat abierto: solo una vibración suave, como WhatsApp.
/// - En segundo plano: notificación con sonido y el número de no leídos en el icono.
///
/// Nota: con la app cerrada del todo, iOS solo entrega avisos mediante las
/// notificaciones push de Apple, que necesitan la cuenta de desarrollador de pago.
class Alerts with WidgetsBindingObserver {
  Alerts._();
  static final instance = Alerts._();

  static const _soundKey = 'klk.notif.sound';
  static const _showKey = 'klk.notif.show';
  static const _previewKey = 'klk.notif.preview';
  static const _vibrateKey = 'klk.notif.vibrate';
  static const _badgeId = 0x7ffffff0;

  final _plugin = FlutterLocalNotificationsPlugin();
  final _store = SecureStore();
  bool _ready = false;
  bool _foreground = true;

  /// Ajustes (se cambian desde Ajustes → Notificaciones).
  final settings = ValueNotifier<AlertSettings>(const AlertSettings());

  /// Total de mensajes sin leer (lo da el controlador de la app).
  int Function()? unreadTotal;

  /// Se llama al tocar una notificación.
  void Function(String chatId)? onOpenChat;
  String? _pendingOpen;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    WidgetsBinding.instance.addObserver(this);
    await _loadSettings();
    if (kIsWeb || !(Platform.isIOS || Platform.isAndroid)) return;
    try {
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _plugin.initialize(
        const InitializationSettings(
          iOS: darwin,
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (r) => _open(r.payload),
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) _open(launch!.notificationResponse?.payload);
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('Notificaciones no disponibles: $e');
    }
  }

  void _open(String? chatId) {
    if (chatId == null || chatId.isEmpty) return;
    final cb = onOpenChat;
    if (cb == null) {
      _pendingOpen = chatId; // la pantalla de inicio aún no está lista
    } else {
      cb(chatId);
    }
  }

  /// La pantalla de inicio se registra aquí; si se abrió la app tocando un aviso, abre ese chat.
  void attach(void Function(String chatId) open) {
    onOpenChat = open;
    final p = _pendingOpen;
    _pendingOpen = null;
    if (p != null) open(p);
  }

  Future<void> _loadSettings() async {
    Future<bool> flag(String k) async {
      try {
        return (await _store.read(k)) != '0';
      } catch (_) {
        return true;
      }
    }

    settings.value = AlertSettings(
      sound: await flag(_soundKey),
      show: await flag(_showKey),
      preview: await flag(_previewKey),
      vibrate: await flag(_vibrateKey),
    );
  }

  Future<void> update(AlertSettings s) async {
    settings.value = s;
    try {
      await _store.write(_soundKey, s.sound ? '1' : '0');
      await _store.write(_showKey, s.show ? '1' : '0');
      await _store.write(_previewKey, s.preview ? '1' : '0');
      await _store.write(_vibrateKey, s.vibrate ? '1' : '0');
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground && state != AppLifecycleState.paused) return;
    _foreground = fg;
    if (fg) {
      // Al volver, se quitan los avisos ya vistos y el número queda en lo que falte por leer.
      unawaited(_clearShown());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      unawaited(setBadge(unreadTotal?.call() ?? 0));
    }
  }

  Future<void> _clearShown() async {
    if (!_canNotify) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
    await setBadge(unreadTotal?.call() ?? 0);
  }

  bool get _canNotify => _ready && !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  /// Pone el número rojo en el icono de KLK (iOS).
  Future<void> setBadge(int n) async {
    if (!_canNotify || !Platform.isIOS) return;
    try {
      await _plugin.show(
        _badgeId,
        null,
        null,
        NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: false,
            presentBanner: false,
            presentList: false,
            presentSound: false,
            presentBadge: true,
            badgeNumber: n < 0 ? 0 : n,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _plugin.cancel(_badgeId);
    } catch (_) {}
  }

  /// Llega un mensaje nuevo.
  Future<void> incoming({
    required String chatId,
    required String title,
    required String text,
    required bool chatOpen,
  }) async {
    final s = settings.value;
    if (chatOpen && _foreground) {
      if (s.vibrate) unawaited(HapticFeedback.lightImpact());
      return;
    }
    if (s.vibrate && _foreground) unawaited(HapticFeedback.mediumImpact());
    if (!_canNotify) return;
    final badge = unreadTotal?.call() ?? 0;
    final body = s.preview ? text : 'Mensaje nuevo';
    try {
      if (_foreground) {
        // En primer plano la pantalla ya enseña el aviso: solo el sonido.
        if (!s.sound) return;
        await _plugin.show(
          chatId.hashCode & 0x3fffffff,
          title,
          body,
          const NotificationDetails(
            iOS: DarwinNotificationDetails(
              presentAlert: false,
              presentBanner: false,
              presentList: false,
              presentSound: true,
              presentBadge: false,
            ),
            android: AndroidNotificationDetails('klk_msgs_quiet', 'Sonido con KLK abierto',
                importance: Importance.low, priority: Priority.low, playSound: true),
          ),
          payload: chatId,
        );
        unawaited(Future<void>.delayed(const Duration(seconds: 2), () => _plugin.cancel(chatId.hashCode & 0x3fffffff)));
        return;
      }
      if (!s.show) return;
      await _plugin.show(
        chatId.hashCode & 0x3fffffff,
        title,
        body,
        NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: s.sound,
            presentBadge: true,
            badgeNumber: badge,
            threadIdentifier: chatId,
          ),
          android: AndroidNotificationDetails(
            'klk_msgs',
            'Mensajes',
            channelDescription: 'Mensajes nuevos de KLK',
            importance: Importance.high,
            priority: Priority.high,
            playSound: s.sound,
            number: badge,
          ),
        ),
        payload: chatId,
      );
    } catch (e) {
      debugPrint('No se pudo avisar: $e');
    }
  }
}

@immutable
class AlertSettings {
  final bool sound, show, preview, vibrate;
  const AlertSettings({this.sound = true, this.show = true, this.preview = true, this.vibrate = true});

  AlertSettings copyWith({bool? sound, bool? show, bool? preview, bool? vibrate}) => AlertSettings(
        sound: sound ?? this.sound,
        show: show ?? this.show,
        preview: preview ?? this.preview,
        vibrate: vibrate ?? this.vibrate,
      );
}
