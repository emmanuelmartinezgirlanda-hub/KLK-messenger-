import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_screen.dart';
import '../messaging/app_controller.dart';
import 'device_contacts.dart';

enum _Check { idle, checking, onKlk, notOnKlk, invalid, error }

/// "Nuevo contacto": nombre + número, comprobando al momento si usa KLK.
class NewContactScreen extends ConsumerStatefulWidget {
  /// Texto que el usuario buscaba (si es un número, se rellena solo).
  final String? initialQuery;
  const NewContactScreen({super.key, this.initialQuery});

  @override
  ConsumerState<NewContactScreen> createState() => _NewContactScreenState();
}

class _NewContactScreenState extends ConsumerState<NewContactScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  Country _country = countries.first;
  _Check _check = _Check.idle;
  String? _accountId;
  Timer? _debounce;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Preselecciona mi país
    final dial = ref.read(appProvider).myDialCode;
    _country = countries.firstWhere((c) => c.dialCode == dial, orElse: () => countries.first);
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      if (RegExp(r'^[\d\s()+-]+$').hasMatch(q)) {
        _phone.text = q;
        WidgetsBinding.instance.addPostFrameCallback((_) => _onPhoneChanged(q));
      } else {
        _first.text = q;
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _first.dispose();
    _last.dispose();
    _phone.dispose();
    super.dispose();
  }

  String get _name => '${_first.text.trim()} ${_last.text.trim()}'.trim();

  String? get _e164 {
    final raw = _phone.text.trim();
    if (raw.startsWith('+') || raw.startsWith('00')) return normalizePhone(raw, _country.dialCode);
    final e = toE164(_country, raw);
    return isValidE164(e) ? e : null;
  }

  void _onPhoneChanged(String _) {
    _debounce?.cancel();
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) {
      setState(() => _check = _Check.idle);
      return;
    }
    setState(() => _check = _Check.checking);
    _debounce = Timer(const Duration(milliseconds: 600), _verify);
  }

  Future<void> _verify() async {
    final e = _e164;
    if (e == null) {
      setState(() => _check = _Check.invalid);
      return;
    }
    try {
      final found = await ref.read(appProvider).discover([e]);
      if (!mounted || e != _e164) return; // el número cambió mientras tanto
      setState(() {
        _accountId = found[e];
        _check = _accountId != null ? _Check.onKlk : _Check.notOnKlk;
      });
    } catch (_) {
      if (mounted) setState(() => _check = _Check.error);
    }
  }

  Future<void> _save() async {
    final e = _e164;
    if (e == null || _check != _Check.onKlk) return;
    setState(() => _saving = true);
    try {
      final id = await ref.read(appProvider).startChatWithPhone(e, _name, knownAccountId: _accountId);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)),
        (r) => r.isFirst,
      );
    } catch (err) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canSave = _check == _Check.onKlk && _first.text.trim().isNotEmpty && !_saving;

    InputDecoration deco(String label, {IconData? icon, String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon == null ? null : Icon(icon),
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Nuevo contacto', style: TextStyle(fontWeight: FontWeight.w700))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Center(
              child: ChatAvatar(
                id: _phone.text.isEmpty ? 'nuevo' : _phone.text,
                title: _name.isEmpty ? '+' : _name,
                radius: 48,
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _first,
              autofocus: widget.initialQuery == null,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: deco('Nombre', icon: Icons.person_outline),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _last,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: deco('Apellido (opcional)', icon: Icons.badge_outlined),
            ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<Country>(
                    value: _country,
                    items: [
                      for (final c in countries)
                        DropdownMenuItem(value: c, child: Text('${c.flag} ${c.dialCode}')),
                    ],
                    selectedItemBuilder: (_) => [
                      for (final c in countries) Center(child: Text('${c.flag} ${c.dialCode}')),
                    ],
                    onChanged: (c) {
                      setState(() => _country = c ?? _country);
                      _onPhoneChanged(_phone.text);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  onChanged: _onPhoneChanged,
                  decoration: deco('Número', hint: _country.example),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            _StatusChip(check: _check, onInvite: () {
              final e = _e164;
              if (e != null) DeviceContacts.invite(e);
            }),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: canSave ? _save : null,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chat_bubble_outline),
              label: const Text('Guardar y escribir', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            if (_check == _Check.onKlk && _first.text.trim().isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Escribe un nombre para guardarlo',
                    textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final _Check check;
  final VoidCallback onInvite;
  const _StatusChip({required this.check, required this.onInvite});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const green = Color(0xFF2E9E5B);
    const red = Color(0xFFFF6B7A);

    Widget chip(Widget icon, String text, Color color, {Widget? trailing}) => AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            icon,
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
            if (trailing != null) trailing,
          ]),
        );

    return switch (check) {
      _Check.idle => Text('Escribe el número con o sin prefijo. Te diremos al momento si usa KLK.',
          style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
      _Check.checking => chip(
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
          'Comprobando…',
          cs.primary),
      _Check.onKlk => chip(const Icon(Icons.verified, color: green), 'Está en KLK. ¡Ya puedes escribirle!', green),
      _Check.notOnKlk => chip(
          Icon(Icons.info_outline, color: cs.secondary),
          'Todavía no usa KLK',
          cs.secondary,
          trailing: TextButton(onPressed: onInvite, child: const Text('Invitar')),
        ),
      _Check.invalid => chip(const Icon(Icons.error_outline, color: red), 'Ese número no parece completo', red),
      _Check.error => chip(const Icon(Icons.wifi_off, color: red), 'Sin conexión para comprobarlo', red),
    };
  }
}
