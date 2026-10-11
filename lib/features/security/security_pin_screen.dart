import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../messaging/app_controller.dart';

/// PIN de seguridad (verificación en dos pasos): si alguien consigue tu SIM,
/// no puede registrar tu número en otro móvil sin este PIN.
class SecurityPinScreen extends ConsumerStatefulWidget {
  const SecurityPinScreen({super.key});

  @override
  ConsumerState<SecurityPinScreen> createState() => _SecurityPinScreenState();
}

class _SecurityPinScreenState extends ConsumerState<SecurityPinScreen> {
  bool? _enabled;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = ref.read(appProvider);
    if (app.isDemo) {
      setState(() => _enabled = false);
      return;
    }
    try {
      final on = await app.pinEnabled();
      if (mounted) setState(() => _enabled = on);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<String?> _askNewPin() async {
    final first = await _pinDialog('Crea tu PIN', 'Escribe 6 números que recuerdes. No uses tu fecha de nacimiento.');
    if (first == null || !mounted) return null;
    final second = await _pinDialog('Repite el PIN', 'Escríbelo otra vez para confirmarlo.');
    if (second == null) return null;
    if (first != second) {
      _snack('Los dos PIN no coinciden. Prueba otra vez.');
      return null;
    }
    if (RegExp(r'^(\d)\1{5}$').hasMatch(first) || first == '123456' || first == '654321') {
      _snack('Ese PIN es muy fácil de adivinar. Elige otro.');
      return null;
    }
    return first;
  }

  Future<String?> _pinDialog(String title, String text) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              maxLength: 6,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, letterSpacing: 10),
              onChanged: (_) => set(() {}),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancelar')),
            FilledButton(
              onPressed: ctrl.text.length == 6 ? () => Navigator.pop(d, ctrl.text) : null,
              child: const Text('Siguiente'),
            ),
          ],
        ),
      ),
    ).whenComplete(ctrl.dispose);
  }

  Future<void> _set() async {
    final pin = await _askNewPin();
    if (pin == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(appProvider).setRegistrationPin(pin);
      if (mounted) setState(() => _enabled = true);
      _snack('PIN guardado 🔒');
    } on ApiException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack('No se pudo guardar. Revisa tu conexión.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('¿Quitar el PIN?'),
        content: const Text('Sin PIN, cualquiera que consiga tu SIM podría entrar en tu cuenta en otro móvil.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Quitar')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(appProvider).clearRegistrationPin();
      if (mounted) setState(() => _enabled = false);
      _snack('PIN quitado');
    } catch (_) {
      _snack('No se pudo quitar. Revisa tu conexión.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final app = ref.watch(appProvider);
    final on = _enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('PIN de seguridad')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Icon(on == true ? Icons.verified_user : Icons.shield_outlined, size: 72, color: cs.primary),
        const SizedBox(height: 16),
        Text(on == true ? 'Tu cuenta está protegida' : 'Protege tu cuenta con un PIN',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Text(
          'Si alguien consigue tu SIM o tu código SMS, no podrá entrar en tu KLK en otro móvil sin este PIN de 6 números.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7), fontSize: 15),
        ),
        const SizedBox(height: 28),
        if (app.isDemo)
          const Text('En el modo demo no hay PIN. Entra con tu número para activarlo.', textAlign: TextAlign.center)
        else if (on == null && _error == null)
          const Center(child: CircularProgressIndicator())
        else if (_error != null)
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFF6B7A)))
        else ...[
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
            onPressed: _busy ? null : _set,
            icon: const Icon(Icons.pin_outlined),
            label: Text(on! ? 'Cambiar el PIN' : 'Activar el PIN'),
          ),
          if (on) ...[
            const SizedBox(height: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), shape: const StadiumBorder()),
              onPressed: _busy ? null : _clear,
              child: const Text('Quitar el PIN'),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            'Si lo olvidas, podrás entrar sin PIN cuando pasen 7 días sin usar la cuenta.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ]),
    );
  }
}
