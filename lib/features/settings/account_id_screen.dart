import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/network/api_client.dart';
import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';

/// Ajustes → «Usuario y correo»: mi @usuario (para que me encuentren sin mi
/// número) y mi correo (para entrar o recuperar la cuenta si pierdo el número).
class AccountIdScreen extends ConsumerStatefulWidget {
  const AccountIdScreen({super.key});

  @override
  ConsumerState<AccountIdScreen> createState() => _AccountIdScreenState();
}

class _AccountIdScreenState extends ConsumerState<AccountIdScreen> {
  late final _user = TextEditingController(text: ref.read(appProvider).myUsername);
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _savingUser = false;
  bool _sending = false;
  String? _codeSentTo; // esperando el código de este correo
  String? _userError;
  String? _emailError;

  static final _userRe = RegExp(r'^[a-z0-9][a-z0-9_.]{2,19}$');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(appProvider).loadAccountInfo();
      if (mounted && _user.text.isEmpty) _user.text = ref.read(appProvider).myUsername;
    });
  }

  @override
  void dispose() {
    _user.dispose();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  void _say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  String get _typedUser => _user.text.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();

  Future<void> _saveUser() async {
    final u = _typedUser;
    if (u.isNotEmpty && (!_userRe.hasMatch(u) || u.contains('..') || u.endsWith('.'))) {
      setState(() => _userError = tr('De 3 a 20 letras sin acentos, números, punto o guion bajo.'));
      return;
    }
    setState(() {
      _savingUser = true;
      _userError = null;
    });
    try {
      await ref.read(appProvider).setUsername(u);
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      _say(u.isEmpty ? tr('Usuario quitado') : '${tr('Ya eres')} @$u');
    } on ApiException catch (e) {
      if (mounted) setState(() => _userError = e.message);
    } catch (e) {
      if (mounted) setState(() => _userError = '$e');
    } finally {
      if (mounted) setState(() => _savingUser = false);
    }
  }

  Future<void> _sendCode() async {
    final e = _email.text.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[a-z]{2,}$').hasMatch(e)) {
      setState(() => _emailError = tr('Escribe un correo completo, por ejemplo nombre@gmail.com.'));
      return;
    }
    setState(() {
      _sending = true;
      _emailError = null;
    });
    try {
      await ref.read(appProvider).requestLinkEmail(e);
      if (!mounted) return;
      setState(() => _codeSentTo = e);
    } on ApiException catch (err) {
      if (mounted) setState(() => _emailError = err.message);
    } catch (err) {
      if (mounted) setState(() => _emailError = '$err');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verifyCode() async {
    final to = _codeSentTo;
    if (to == null) return;
    setState(() {
      _sending = true;
      _emailError = null;
    });
    try {
      await ref.read(appProvider).verifyLinkEmail(to, _code.text);
      if (!mounted) return;
      setState(() {
        _codeSentTo = null;
        _email.clear();
        _code.clear();
      });
      _say(tr('Correo añadido'));
    } on ApiException catch (err) {
      if (mounted) setState(() => _emailError = err.message);
    } catch (err) {
      if (mounted) setState(() => _emailError = '$err');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _removeEmail() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('¿Quitar tu correo?')),
        content: Text(tr('Ya no podrás entrar ni recuperar tu cuenta con él.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Quitar'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(appProvider).removeEmail();
    } on ApiException catch (e) {
      if (mounted) _say(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.65), height: 1.35);
    final emailLogin = app.signedInWithEmail;
    final mailReady = app.isDemo || app.emailOnServer;

    Widget section(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
          child: Text(t.toUpperCase(),
              style: TextStyle(fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w800, color: cs.secondary)),
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Usuario y correo'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        section(tr('Tu @usuario')),
        Text(tr('Con tu @usuario te pueden escribir sin saber tu número. Lo ve quien te busca; tu número no.'), style: muted),
        const SizedBox(height: 12),
        TextField(
          controller: _user,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          maxLength: 21,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[@a-zA-Z0-9_.]'))],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _saveUser(),
          decoration: InputDecoration(
            prefixText: '@',
            hintText: 'emmanuel.do',
            errorText: _userError,
            errorMaxLines: 3,
            counterText: '',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: FilledButton(
              onPressed: _savingUser || _typedUser == app.myUsername ? null : _saveUser,
              child: _savingUser
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(app.myUsername.isEmpty ? tr('Guardar usuario') : tr('Cambiar usuario')),
            ),
          ),
          if (app.myUsername.isNotEmpty) ...[
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: tr('Copiar'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '@${app.myUsername}'));
                _say(tr('Copiado'));
              },
              icon: const Icon(Icons.copy_rounded),
            ),
          ],
        ]),

        if (app.myEmail.isNotEmpty || mailReady) section(tr('Tu correo')),
        if (app.myEmail.isNotEmpty) ...[
          Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(app.myEmail, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(emailLogin ? tr('Entras a KLK con este correo') : tr('Para entrar o recuperar tu cuenta')),
              trailing: emailLogin
                  ? null
                  : IconButton(tooltip: tr('Quitar'), onPressed: _removeEmail, icon: const Icon(Icons.close_rounded)),
            ),
          ),
          const SizedBox(height: 8),
          if (!emailLogin)
            Text(tr('Si pierdes tu número, en la pantalla de entrada elige «Con mi correo» y entrarás a esta misma cuenta.'),
                style: muted),
        ] else if (mailReady) ...[
          Text(
              tr('Añade tu correo para entrar a KLK si un día pierdes tu número. Tu correo no se le enseña a nadie.'),
              style: muted),
          const SizedBox(height: 12),
          if (_codeSentTo == null) ...[
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              onSubmitted: (_) => _sendCode(),
              decoration: InputDecoration(
                hintText: 'nombre@gmail.com',
                errorText: _emailError,
                errorMaxLines: 3,
                prefixIcon: const Icon(Icons.alternate_email_rounded),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _sending ? null : _sendCode,
              child: _sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(tr('Enviarme el código')),
            ),
          ] else ...[
            Text('${tr('Escribe el código que enviamos a')} $_codeSentTo. ${tr('Si no lo ves, mira en «Spam».')}',
                style: const TextStyle(fontSize: 14.5)),
            const SizedBox(height: 10),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 22, letterSpacing: 6, fontWeight: FontWeight.w800),
              onSubmitted: (_) => _verifyCode(),
              onChanged: (v) {
                if (v.length == 6) _verifyCode();
              },
              decoration: InputDecoration(
                errorText: _emailError,
                errorMaxLines: 3,
                counterText: '',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            Row(children: [
              TextButton(
                onPressed: _sending ? null : () => setState(() => _codeSentTo = null),
                child: Text(tr('Cambiar correo')),
              ),
              const Spacer(),
              FilledButton(onPressed: _sending ? null : _verifyCode, child: Text(tr('Confirmar'))),
            ]),
          ],
        ],

        section(tr('Cómo entras a KLK')),
        Text(
          emailLogin
              ? '${tr('Con tu correo')} ${prettyPhone(app.session?.phone ?? '')}.'
              : '${tr('Con tu número')} ${prettyPhone(app.session?.phone ?? '')}.',
          style: muted,
        ),
      ]),
    );
  }
}
