import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_screen.dart';
import '../messaging/app_controller.dart';

/// Chats ocultos: protegidos con un PIN propio de KLK.
/// La primera vez se crea el PIN; después se pide para entrar.
class HiddenChatsScreen extends ConsumerStatefulWidget {
  const HiddenChatsScreen({super.key});

  @override
  ConsumerState<HiddenChatsScreen> createState() => _HiddenChatsScreenState();
}

class _HiddenChatsScreenState extends ConsumerState<HiddenChatsScreen> {
  bool? _hasPin;
  bool _unlocked = false;
  String _entry = '';
  String? _firstEntry; // al crear el PIN, primera vez que se escribe
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(appProvider).hasPin.then((v) {
      if (mounted) setState(() => _hasPin = v);
    });
  }

  Future<void> _digit(String d) async {
    if (_entry.length >= 6) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entry += d;
      _error = null;
    });
    if (_entry.length < 4) return;
    final app = ref.read(appProvider);

    if (_hasPin == true) {
      if (_entry.length >= 4 && await app.checkPin(_entry)) {
        setState(() => _unlocked = true);
      } else if (_entry.length == 6) {
        HapticFeedback.heavyImpact();
        setState(() {
          _entry = '';
          _error = 'PIN incorrecto';
        });
      }
    }
  }

  Future<void> _confirmNewPin() async {
    if (_entry.length < 4) return;
    if (_firstEntry == null) {
      setState(() {
        _firstEntry = _entry;
        _entry = '';
      });
      return;
    }
    if (_firstEntry != _entry) {
      setState(() {
        _firstEntry = null;
        _entry = '';
        _error = 'Los PIN no coinciden. Empieza otra vez.';
      });
      return;
    }
    await ref.read(appProvider).setPin(_entry);
    setState(() {
      _hasPin = true;
      _unlocked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_hasPin == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    if (_unlocked) {
      final hidden = ref.watch(appProvider).hiddenChats;
      return Scaffold(
        appBar: AppBar(title: const Text('Chats ocultos')),
        body: hidden.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No tienes chats ocultos.\nMantén pulsado un chat en la lista y toca «Ocultar chat».',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(children: [
                for (final c in hidden)
                  ListTile(
                    leading: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath),
                    title: Text(c.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(c.lastText, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      tooltip: 'Mostrar en la lista',
                      icon: const Icon(Icons.visibility_outlined),
                      onPressed: () => ref.read(appProvider).setHidden(c.id, false),
                    ),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: c.id))),
                  ),
              ]),
      );
    }

    final creating = _hasPin == false;
    final title = creating
        ? (_firstEntry == null ? 'Crea un PIN para tus chats ocultos' : 'Repite el PIN')
        : 'Escribe tu PIN';

    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 12),
          Icon(Icons.lock_outline, size: 48, color: cs.primary),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          if (creating)
            const Padding(
              padding: EdgeInsets.fromLTRB(32, 6, 32, 0),
              child: Text('De 4 a 6 cifras. Es distinto del código de tu iPhone.', textAlign: TextAlign.center),
            ),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < 6; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 7),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _entry.length ? cs.primary : Colors.transparent,
                  border: Border.all(color: i < 4 ? cs.primary : cs.primary.withValues(alpha: 0.4), width: 2),
                ),
              ),
          ]),
          SizedBox(
            height: 28,
            child: _error == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!, style: const TextStyle(color: Color(0xFFFF6B7A))),
                  ),
          ),
          const Spacer(),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['', '0', '<'],
          ])
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (final k in row)
                SizedBox(
                  width: 88,
                  height: 72,
                  child: k.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () {
                            if (k == '<') {
                              setState(() => _entry = _entry.isEmpty ? '' : _entry.substring(0, _entry.length - 1));
                            } else {
                              _digit(k);
                            }
                          },
                          child: k == '<'
                              ? const Icon(Icons.backspace_outlined)
                              : Text(k, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500)),
                        ),
                ),
            ]),
          if (creating)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: FilledButton(
                onPressed: _entry.length >= 4 ? _confirmNewPin : null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                child: Text(_firstEntry == null ? 'Siguiente' : 'Guardar PIN'),
              ),
            )
          else
            const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
