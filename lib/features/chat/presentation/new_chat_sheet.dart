import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/phone.dart';
import '../../messaging/app_controller.dart';
import 'chat_screen.dart';

Future<void> showNewChatSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _NewChatSheet(),
    );

class _NewChatSheet extends ConsumerStatefulWidget {
  const _NewChatSheet();

  @override
  ConsumerState<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<_NewChatSheet> {
  Country _country = countries.first;
  final _phone = TextEditingController();
  final _name = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final e164 = toE164(_country, _phone.text);
    if (!isValidE164(e164)) {
      setState(() => _error = 'Número incompleto. Ejemplo: ${_country.example}');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref.read(appProvider).startChatWithPhone(e164, _name.text);
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Nuevo chat', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nombre (opcional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            DropdownButton<Country>(
              value: _country,
              underline: const SizedBox.shrink(),
              items: [
                for (final c in countries) DropdownMenuItem(value: c, child: Text('${c.flag} ${c.dialCode}')),
              ],
              onChanged: (c) => setState(() => _country = c ?? _country),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _phone,
                autofocus: true,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                    labelText: 'Número', hintText: _country.example, border: const OutlineInputBorder()),
                onSubmitted: (_) => _start(),
              ),
            ),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Color(0xFFFF6B7A))),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _start,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Escribirle'),
          ),
        ],
      ),
    );
  }
}
