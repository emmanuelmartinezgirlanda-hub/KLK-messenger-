import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/brand/klk_brand.dart';
import '../../core/config.dart';
import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';
import 'otp_screen.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  Country _country = countries.first;
  final _phone = TextEditingController();
  final _server = TextEditingController(text: KlkConfig.defaultServer);
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final e164 = toE164(_country, _phone.text);
    if (!isValidE164(e164)) {
      setState(() => _error = 'Escribe un número completo, por ejemplo ${_country.example}.');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await ref.read(appProvider).requestCode(e164, _server.text);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => OtpScreen(phone: e164)));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.asset('assets/brand/klk_logo.png', height: 220, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 24),
            Text(KlkBrand.slogan, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(
              'Mensajería privada para los dominicanos del mundo entero. '
              'Cifrada de punta a punta: ni nosotros podemos leer tus mensajes.',
              style: text.bodyLarge?.copyWith(color: cs.onSurface.withValues(alpha: 0.7), height: 1.45),
            ),
            const SizedBox(height: 40),
            Text('Tu número de teléfono', style: text.labelLarge),
            const SizedBox(height: 8),
            Row(children: [
              DropdownButtonHideUnderline(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: DropdownButton<Country>(
                    value: _country,
                    items: [
                      for (final c in countries)
                        DropdownMenuItem(value: c, child: Text('${c.flag} ${c.dialCode}')),
                    ],
                    selectedItemBuilder: (_) => [
                      for (final c in countries) Center(child: Text('${c.flag} ${c.dialCode}')),
                    ],
                    onChanged: (c) => setState(() => _country = c ?? _country),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumberNational],
                  decoration: InputDecoration(
                    hintText: _country.example,
                    filled: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF6B7A))),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Enviarme el código', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Opciones avanzadas', style: text.bodyMedium),
              children: [
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Servidor',
                    hintText: 'https://api.tudominio.com',
                    helperText: 'Déjalo vacío para probar KLK en modo demo (código 123456).',
                    helperMaxLines: 2,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
