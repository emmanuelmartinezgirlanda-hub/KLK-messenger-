import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/l10n/l10n.dart';
import '../../core/media/media_store.dart';
import '../../core/security/secure_store.dart';
import '../chat/presentation/chat_avatar.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';

/// Listas de difusión: un mensaje a muchos contactos a la vez. Cada uno lo
/// recibe en su chat contigo, como un mensaje normal (no ven a los demás).
/// Las listas se guardan solo en este móvil.
class BroadcastList {
  BroadcastList({required this.id, required this.name, required this.members});
  final String id;
  String name;
  List<String> members; // ids de chats individuales

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'members': members};
  factory BroadcastList.fromJson(Map<String, dynamic> j) => BroadcastList(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        members: (j['members'] as List? ?? const []).cast<String>(),
      );
}

const _key = 'klk.broadcast.lists';

Future<List<BroadcastList>> loadBroadcastLists(SecureStore store) async {
  try {
    final raw = await store.read(_key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((e) => BroadcastList.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  } catch (_) {
    return [];
  }
}

Future<void> saveBroadcastLists(SecureStore store, List<BroadcastList> lists) =>
    store.write(_key, jsonEncode(lists.map((l) => l.toJson()).toList()));

/// Pantalla con mis listas de difusión.
class BroadcastListsScreen extends ConsumerStatefulWidget {
  const BroadcastListsScreen({super.key});

  @override
  ConsumerState<BroadcastListsScreen> createState() => _BroadcastListsScreenState();
}

class _BroadcastListsScreenState extends ConsumerState<BroadcastListsScreen> {
  List<BroadcastList> _lists = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await loadBroadcastLists(ref.read(secureStoreProvider));
    if (mounted) {
      setState(() {
        _lists = l;
        _loaded = true;
      });
    }
  }

  Future<void> _save() => saveBroadcastLists(ref.read(secureStoreProvider), _lists);

  Future<void> _edit([BroadcastList? list]) async {
    final result = await Navigator.of(context).push<BroadcastList>(
        MaterialPageRoute(builder: (_) => _EditBroadcastScreen(list: list)));
    if (result == null) return;
    setState(() {
      final i = _lists.indexWhere((l) => l.id == result.id);
      if (i >= 0) {
        _lists[i] = result;
      } else {
        _lists.add(result);
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Listas de difusión'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: Text(tr('Nueva lista')),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _lists.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.campaign_outlined, size: 60, color: cs.primary),
                      const SizedBox(height: 12),
                      Text(tr('Manda un mensaje a muchos a la vez'),
                          textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      Text(
                          tr('Cada persona lo recibe en su chat contigo, como un mensaje normal. No ven a quién más se lo mandaste.'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    ]),
                  ),
                )
              : ListView(children: [
                  for (final l in _lists)
                    ListTile(
                      leading: CircleAvatar(
                          backgroundColor: cs.primaryContainer, child: Icon(Icons.campaign, color: cs.onPrimaryContainer)),
                      title: Text(l.name),
                      subtitle: Text('${l.members.length} ${tr('personas')}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') await _edit(l);
                          if (v == 'delete') {
                            setState(() => _lists.remove(l));
                            await _save();
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'edit', child: Text(tr('Editar'))),
                          PopupMenuItem(value: 'delete', child: Text(tr('Borrar lista'))),
                        ],
                      ),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => BroadcastSendScreen(list: l))),
                    ),
                ]),
    );
  }
}

class _EditBroadcastScreen extends ConsumerStatefulWidget {
  const _EditBroadcastScreen({this.list});
  final BroadcastList? list;

  @override
  ConsumerState<_EditBroadcastScreen> createState() => _EditBroadcastScreenState();
}

class _EditBroadcastScreenState extends ConsumerState<_EditBroadcastScreen> {
  late final _name = TextEditingController(text: widget.list?.name ?? '');
  late final Set<String> _sel = {...?widget.list?.members};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final contacts = app.contactChats.where((c) => app.isDemo || c.identityKey != null).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final ok = _name.text.trim().isNotEmpty && _sel.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.list == null ? tr('Nueva lista') : tr('Editar lista')),
        actions: [
          TextButton(
            onPressed: ok
                ? () => Navigator.of(context).pop(BroadcastList(
                      id: widget.list?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
                      name: _name.text.trim(),
                      members: _sel.toList(),
                    ))
                : null,
            child: Text(tr('Guardar')),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: tr('Nombre de la lista'),
              hintText: tr('Clientes, Familia, Iglesia…'),
            ),
          ),
        ),
        Expanded(
          child: ListView(children: [
            for (final c in contacts)
              CheckboxListTile(
                value: _sel.contains(c.id),
                onChanged: (v) => setState(() => v == true ? _sel.add(c.id) : _sel.remove(c.id)),
                secondary: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath, radius: 20),
                title: Text(c.title),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Escribir y mandar a toda la lista.
class BroadcastSendScreen extends ConsumerStatefulWidget {
  const BroadcastSendScreen({super.key, required this.list});
  final BroadcastList list;

  @override
  ConsumerState<BroadcastSendScreen> createState() => _BroadcastSendScreenState();
}

class _BroadcastSendScreenState extends ConsumerState<BroadcastSendScreen> {
  final _text = TextEditingController();
  String? _photo;
  bool _sending = false;
  int _sent = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x != null) setState(() => _photo = x.path);
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty && _photo == null) return;
    final app = ref.read(appProvider);
    setState(() {
      _sending = true;
      _sent = 0;
    });
    final members = widget.list.members.where((id) => app.chatById(id) != null).toList();
    for (final id in members) {
      try {
        if (_photo != null) {
          final local = await MediaStore.importFile(_photo!);
          await app.sendMedia(
              id, MessageMedia(type: MediaType.image, localPath: local, mime: MediaStore.mimeFor(local)),
              caption: text);
        } else {
          await app.sendText(id, text);
        }
      } catch (_) {}
      if (mounted) setState(() => _sent++);
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _text.clear();
      _photo = null;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${tr('Enviado a')} ${members.length} ${tr('personas')} ✓')));
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final names = widget.list.members.map((id) => app.chatById(id)?.title).whereType<String>().toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.list.name),
          Text('${names.length} ${tr('personas')}', style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
        ]),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text(tr('Lo recibirán:'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(names.join(', '), style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 16),
              if (_photo != null)
                Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(File(_photo!), height: 220, width: double.infinity, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: IconButton.filledTonal(
                        onPressed: () => setState(() => _photo = null), icon: const Icon(Icons.close)),
                  ),
                ]),
              if (_sending) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: names.isEmpty ? null : _sent / names.length),
                const SizedBox(height: 6),
                Text('${tr('Enviando')} $_sent / ${names.length}…', textAlign: TextAlign.center),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(children: [
              IconButton(onPressed: _sending ? null : _pickPhoto, icon: const Icon(Icons.photo_outlined)),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 5,
                  decoration: InputDecoration(hintText: tr('Mensaje para todos')),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
            ]),
          ),
        ]),
      ),
    );
  }
}
