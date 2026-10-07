import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/brand/klk_logo.dart';

/// Desbloqueo con Face ID / Touch ID o, si no hay, con el código del iPhone.
class AppLockService {
  static final _auth = LocalAuthentication();

  /// ¿El móvil tiene Face ID, Touch ID o código configurado?
  static Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
    } on PlatformException {
      return false;
    }
  }
}

/// Pantalla que tapa KLK hasta que el dueño se identifica.
class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.onUnlocked});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _trying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_trying) return;
    setState(() => _trying = true);
    final ok = await AppLockService.authenticate('Desbloquea KLK para ver tus chats');
    if (!mounted) return;
    setState(() => _trying = false);
    if (ok) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const KlkEmblem(size: 96),
              const SizedBox(height: 20),
              const Text('KLK está bloqueado', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Usa Face ID, Touch ID o el código de tu iPhone.',
                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _trying ? null : _unlock,
                icon: const Icon(Icons.face_unlock_outlined),
                label: const Text('Desbloquear'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
