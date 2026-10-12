import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';
import '../../core/l10n/l10n.dart';

class OtpScreen extends ConsumerStatefulWidget {
  final String phone;
  const OtpScreen({super.key, required this.phone});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(appProvider).verify(_code.text);
      // Al verificar, la app cambia de fase y muestra la pantalla principal.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (e.code == 'pin_required' || e.code == 'bad_pin') {
        if (mounted) setState(() => _busy = false);
        await _askPin(e);
        return;
      }
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// La cuenta tiene PIN de seguridad: se pide antes de entrar.
  Future<void> _askPin(ApiException first) async {
    var info = first;
    while (mounted) {
      final left = (info.data['attemptsLeft'] as num?)?.toInt();
      final pin = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _PinDialog(
          wrong: info.code == 'bad_pin',
          attemptsLeft: left,
        ),
      );
      if (pin == null || !mounted) return;
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        await ref.read(appProvider).verifyPin(pin);
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      } on ApiException catch (e) {
        if (e.code == 'bad_pin' || e.code == 'pin_required') {
          info = e;
          continue;
        }
        if (mounted) setState(() => _error = e.toString());
        return;
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final demo = ref.read(appProvider).pendingServer.isEmpty;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Verifica tu número'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: tr('Escribe el código de 6 cifras que enviamos al ')),
              TextSpan(text: prettyPhone(widget.phone), style: const TextStyle(fontWeight: FontWeight.w700)),
              const TextSpan(text: '.'),
            ]), style: const TextStyle(fontSize: 16, height: 1.4)),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: '······',
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
              onChanged: (v) {
                setState(() {});
                if (v.length == 6 && !_busy) _verify();
              },
            ),
            const SizedBox(height: 12),
            if (demo)
              Text(tr('Modo demo: el código es 123456'), style: TextStyle(color: cs.secondary, fontWeight: FontWeight.w600)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF6B7A))),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy || _code.text.length != 6 ? null : _verify,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('Entrar a KLK'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}


class _PinDialog extends StatefulWidget {
  final bool wrong;
  final int? attemptsLeft;
  const _PinDialog({required this.wrong, this.attemptsLeft});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.attemptsLeft;
    return AlertDialog(
      title: Text(tr('PIN de seguridad')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Esta cuenta está protegida con un PIN de 6 números. Escríbelo para entrar.')),
        if (widget.wrong) ...[
          const SizedBox(height: 8),
          Text(
            left == null ? 'PIN incorrecto.' : 'PIN incorrecto. Te quedan $left intentos.',
            style: const TextStyle(color: Color(0xFFFF6B7A), fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _pin,
          autofocus: true,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, letterSpacing: 10),
          onChanged: (_) => setState(() {}),
        ),
        Text(tr('¿Lo olvidaste? Podrás entrar sin PIN 7 días después de la última vez que se usó la cuenta.'),
            style: TextStyle(fontSize: 12.5)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancelar'))),
        FilledButton(
          onPressed: _pin.text.length == 6 ? () => Navigator.pop(context, _pin.text) : null,
          child: Text(tr('Entrar')),
        ),
      ],
    );
  }
}
