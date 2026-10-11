import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config.dart';
import '../../core/network/api_client.dart';
import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_screen.dart';
import '../messaging/app_controller.dart';

/// Enlace de mi contacto: https://servidor/c/18095551234?n=Emmanuel
/// Si lo abre alguien sin KLK, la página le explica cómo descargarla.
String contactLink(String server, String phone, String name) {
  final base = server.isEmpty ? KlkConfig.officialServer : server;
  final digits = phone.replaceAll(RegExp(r'\D'), '');
  final n = name.trim();
  return Uri.parse(base)
      .replace(path: '/c/$digits', queryParameters: n.isEmpty ? null : {'n': n})
      .toString();
}

/// Lee un código QR de KLK. Devuelve (teléfono E.164, nombre) o null si no es de KLK.
(String, String)? parseContactLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  final m = RegExp(r'^/c/(\d{8,15})/?$').firstMatch(uri.path);
  if (m == null) return null;
  return ('+${m.group(1)}', (uri.queryParameters['n'] ?? '').trim());
}

/// Mi código QR, para que me añadan en KLK messenger sin escribir mi número.
class MyQrScreen extends ConsumerWidget {
  const MyQrScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final s = app.session;
    final name = app.profile.name.trim().isEmpty ? 'Yo' : app.profile.name.trim();
    final link = s == null ? '' : contactLink(s.server, s.phone, app.profile.name);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi código QR'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Compartir',
            icon: const Icon(Icons.ios_share),
            onPressed: link.isEmpty
                ? null
                : () => Share.share('¡Klk! Escríbeme por KLK messenger 🇩🇴\n$link',
                    subject: 'Mi contacto de KLK messenger'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 24), children: [
          Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
            Container(
              margin: const EdgeInsets.only(top: 40),
              padding: const EdgeInsets.fromLTRB(20, 52, 20, 24),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(children: [
                Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text('Contacto de KLK messenger',
                    style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                  child: link.isEmpty
                      ? const SizedBox(width: 220, height: 220)
                      : QrImageView(
                          data: link,
                          size: 220,
                          backgroundColor: Colors.white,
                          errorCorrectionLevel: QrErrorCorrectLevel.H,
                          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF002D62)),
                          dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square, color: Color(0xFF002D62)),
                          embeddedImage: const AssetImage('assets/brand/klk_header.png'),
                          embeddedImageStyle: const QrEmbeddedImageStyle(size: Size(58, 51)),
                        ),
                ),
                if (s != null) ...[
                  const SizedBox(height: 14),
                  Text(prettyPhone(s.phone), style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
                ],
              ]),
            ),
            ChatAvatar(id: 'me', title: name, photoPath: app.profile.photoPath, radius: 40),
          ]),
          const SizedBox(height: 18),
          Text(
            'Tu código QR es privado. Si lo compartes, esa persona podrá escanearlo con KLK '
            'para añadirte como contacto. Si no tiene KLK, le saldrá cómo descargarla.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65)),
          ),
          const SizedBox(height: 28),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrScannerScreen())),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Escanear', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: const StadiumBorder()),
            onPressed: link.isEmpty
                ? null
                : () => Share.share('¡Klk! Escríbeme por KLK messenger 🇩🇴\n$link',
                    subject: 'Mi contacto de KLK messenger'),
            icon: const Icon(Icons.share_outlined),
            label: const Text('Compartir mi enlace'),
          ),
        ]),
      ),
    );
  }
}

/// Escáner de códigos QR de KLK: abre el chat con esa persona.
class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  final _ctrl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _busy = false;
  String? _lastBad;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    final raw = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    final parsed = parseContactLink(raw);
    if (parsed == null) {
      if (_lastBad != raw) {
        _lastBad = raw;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Ese código no es de KLK messenger')));
      }
      return;
    }
    setState(() => _busy = true);
    unawaited(_ctrl.stop());
    final (phone, name) = parsed;
    try {
      final id = await ref.read(appProvider).startChatWithPhone(phone, name);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      setState(() => _busy = false);
      unawaited(_ctrl.start());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No se pudo añadir. Revisa tu conexión.')));
      setState(() => _busy = false);
      unawaited(_ctrl.start());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Escanear código'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Linterna',
            color: Colors.white,
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _ctrl.toggleTorch(),
          ),
        ],
      ),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(
          controller: _ctrl,
          onDetect: _onDetect,
          errorBuilder: (context, error) => const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('KLK no puede usar la cámara. Actívala en Ajustes del móvil → KLK messenger.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            _busy ? 'Abriendo el chat…' : 'Apunta al código QR de KLK de tu contacto',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ]),
    );
  }
}
