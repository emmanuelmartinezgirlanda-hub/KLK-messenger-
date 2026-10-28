import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/brand/klk_brand.dart';
import '../../core/brand/klk_logo.dart';
import '../../core/config.dart';
import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';
import 'otp_screen.dart';
import '../../core/l10n/l10n.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  Country _country = countries.first;
  final _phone = TextEditingController();
  final _server = TextEditingController(text: KlkConfig.defaultServer);
  final _email = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _byEmail = false; // entrar con correo en vez de número
  bool _emailAvailable = false; // ¿el servidor lo permite?
  bool _accepted = false; // aceptó las normas (Apple 1.2)

  @override
  void initState() {
    super.initState();
    _checkEmail();
  }

  Future<void> _checkEmail() async {
    final ok = await ref.read(appProvider).emailLoginAvailable(_server.text);
    if (mounted) setState(() => _emailAvailable = ok);
  }

  Future<void> _submitEmail() async {
    final email = _email.text.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[a-z]{2,}$').hasMatch(email)) {
      setState(() => _error = tr('Escribe un correo completo, por ejemplo nombre@gmail.com.'));
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await ref.read(appProvider).requestEmailCode(email, _server.text);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => OtpScreen(phone: 'mail:$email')));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _phone.dispose();
    _server.dispose();
    super.dispose();
  }

  void _open(String path) =>
      launchUrl(Uri.parse('${KlkConfig.officialServer}$path'), mode: LaunchMode.externalApplication);

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
            const Center(child: KlkLogo(height: 220)),
            const SizedBox(height: 24),
            Text(KlkBrand.slogan, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(
              'Mensajería privada para los dominicanos del mundo entero. '
              'Cifrada de punta a punta: ni nosotros podemos leer tus mensajes.',
              style: text.bodyLarge?.copyWith(color: cs.onSurface.withValues(alpha: 0.7), height: 1.45),
            ),
            const SizedBox(height: 32),
            if (_emailAvailable) ...[
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, icon: const Icon(Icons.phone_iphone_rounded), label: Text(tr('Con mi número'))),
                  ButtonSegment(value: true, icon: const Icon(Icons.alternate_email_rounded), label: Text(tr('Con mi correo'))),
                ],
                selected: {_byEmail},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() {
                  _byEmail = v.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: 18),
            ],
            if (_byEmail) ...[
              Text(tr('Tu correo electrónico'), style: text.labelLarge),
              const SizedBox(height: 8),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.email],
                textCapitalization: TextCapitalization.none,
                decoration: InputDecoration(
                  hintText: 'nombre@gmail.com',
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => _accepted ? _submitEmail() : null,
              ),
              const SizedBox(height: 8),
              Text(
                tr('Te mandamos un código por correo. Tus contactos no te verán por tu número: compárteles tu @usuario o tu código QR.'),
                style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.65), height: 1.35),
              ),
            ] else ...[
            Text(tr('Tu número de teléfono'), style: text.labelLarge),
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
                  onSubmitted: (_) => _accepted ? _submit() : null,
                ),
              ),
            ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Color(0xFFFF6B7A))),
            ],
            const SizedBox(height: 16),
            // Apple (norma 1.2): hay que aceptar las normas (tolerancia cero con el
            // contenido ofensivo y los usuarios abusivos) antes de registrarse o entrar.
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _accepted = !_accepted),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Checkbox(value: _accepted, onChanged: (v) => setState(() => _accepted = v ?? false)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 11),
                    child: Text.rich(
                      TextSpan(
                        style: TextStyle(fontSize: 13.5, color: cs.onSurface.withValues(alpha: 0.85), height: 1.4),
                        children: [
                          TextSpan(text: tr('He leído y acepto las ')),
                          TextSpan(
                            text: tr('Normas de uso de KLK'),
                            style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                            recognizer: TapGestureRecognizer()..onTap = () => _open('/normas'),
                          ),
                          TextSpan(text: tr(': tolerancia cero con el contenido ofensivo y los usuarios abusivos. Acepto también la ')),
                          TextSpan(
                            text: tr('Política de privacidad'),
                            style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                            recognizer: TapGestureRecognizer()..onTap = () => _open('/privacidad'),
                          ),
                          const TextSpan(text: '.'),
                        ],
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy || !_accepted ? null : (_byEmail ? _submitEmail : _submit),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('Enviarme el código'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 16),
            // Elegir otro servidor o el modo demo: solo en versiones de prueba.
            if (const bool.fromEnvironment('KLK_TEST'))
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(tr('Opciones avanzadas'), style: text.bodyMedium),
              children: [
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) => _checkEmail(),
                  decoration: InputDecoration(
                    labelText: tr('Servidor'),
                    hintText: 'https://api.tudominio.com',
                    helperText: tr('Déjalo vacío para probar KLK en modo demo (código 123456).'),
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
