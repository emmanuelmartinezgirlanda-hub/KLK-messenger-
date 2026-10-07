import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_screen.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';

/// Crear grupo: elegir participantes entre mis chats y ponerle nombre.
class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _name = TextEditingController();
  final Set<String> _selected = {};
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create(List<Chat> contacts) async {
    final name = _name.text.trim();
    if (name.isEmpty || _selected.isEmpty) return;
    setState(() => _saving = true);
    final members = contacts.where((c) => _selected.contains(c.id)).toList();
    final id = await ref.read(appProvider).createGroup(name, members);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)),
      (r) => r.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    // En modo real solo puedo añadir a quien tiene KLK (tengo su clave)
    final contacts = app.contactChats.where((c) => app.isDemo || c.identityKey != null).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final canCreate = _name.text.trim().isNotEmpty && _selected.isNotEmpty && !_saving;

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Nuevo grupo', style: TextStyle(fontWeight: FontWeight.w700)),
          Text('${_selected.length} de ${contacts.length} seleccionados',
              style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
        ]),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            CircleAvatar(radius: 26, backgroundColor: cs.primary, child: const Icon(Icons.groups, color: Colors.white)),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _name,
                maxLength: 50,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Nombre del grupo', counterText: ''),
              ),
            ),
          ]),
        ),
        if (_selected.isNotEmpty)
          SizedBox(
            height: 84,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final c in contacts.where((c) => _selected.contains(c.id)))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(children: [
                      Stack(clipBehavior: Clip.none, children: [
                        ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath, radius: 24),
                        Positioned(
                          right: -4,
                          top: -4,
                          child: GestureDetector(
                            onTap: () => setState(() => _selected.remove(c.id)),
                            child: CircleAvatar(radius: 10, backgroundColor: cs.surfaceContainerHighest,
                                child: const Icon(Icons.close, size: 13)),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: 60,
                        child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5)),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: contacts.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('Primero escribe a alguien en KLK para poder añadirle a un grupo.',
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView(children: [
                  for (final c in contacts)
                    CheckboxListTile(
                      value: _selected.contains(c.id),
                      onChanged: (v) => setState(() => v == true ? _selected.add(c.id) : _selected.remove(c.id)),
                      secondary: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath, radius: 22),
                      title: Text(c.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: c.phone.isEmpty ? null : Text(prettyPhone(c.phone)),
                    ),
                ]),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: canCreate ? () => _create(contacts) : null,
        backgroundColor: canCreate ? cs.secondary : cs.surfaceContainerHighest,
        foregroundColor: canCreate ? cs.onSecondary : cs.onSurface.withValues(alpha: 0.4),
        icon: _saving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.check),
        label: const Text('Crear grupo'),
      ),
    );
  }
}
