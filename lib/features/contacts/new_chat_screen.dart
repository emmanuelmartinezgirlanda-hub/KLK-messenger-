import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_screen.dart';
import '../groups/create_group_screen.dart';
import '../messaging/app_controller.dart';
import 'device_contacts.dart';
import 'new_contact_screen.dart';

/// "Nuevo chat": buscador, accesos rápidos, contactos que usan KLK e invitar al resto.
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _search = TextEditingController();
  List<PhoneContact> _contacts = [];
  bool _loading = true;
  bool _permission = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final app = ref.read(appProvider);
    try {
      List<PhoneContact> list;
      if (app.isDemo) {
        list = DeviceContacts.demo;
      } else {
        _permission = await DeviceContacts.requestPermission();
        if (!_permission) {
          setState(() => _loading = false);
          return;
        }
        list = await DeviceContacts.load(app.myDialCode);
      }
      final found = await app.discover(list.map((c) => c.phone).toList());
      _contacts = [for (final c in list) c.withAccount(found[c.phone])];
    } catch (e) {
      _error = 'No se pudo comprobar quién usa KLK. Revisa tu conexión.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(PhoneContact c) async {
    final app = ref.read(appProvider);
    try {
      final id = await app.startChatWithPhone(c.phone, c.name, knownAccountId: c.accountId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _soon(String what) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('$what llega en la próxima versión de KLK')));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = _search.text.trim().toLowerCase();
    bool match(PhoneContact c) =>
        q.isEmpty || c.name.toLowerCase().contains(q) || c.phone.contains(q.replaceAll(RegExp(r'\D'), ''));
    final onKlk = _contacts.where((c) => c.onKlk && match(c)).toList();
    final invite = _contacts.where((c) => !c.onKlk && match(c)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Nuevo chat', style: TextStyle(fontWeight: FontWeight.w700)),
          if (!_loading && _permission)
            Text('${_contacts.where((c) => c.onKlk).length} contactos en KLK',
                style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
        ]),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Buscar nombre o número',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: q.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_search.clear),
                      ),
                filled: true,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
              ),
            ),
          ),
          if (q.isEmpty) ...[
            _Action(
              icon: Icons.person_add_alt_1,
              color: cs.primary,
              title: 'Nuevo contacto',
              subtitle: 'Añade a alguien por su número',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewContactScreen())),
            ),
            _Action(
              icon: Icons.group_add,
              color: const Color(0xFF6A2C91),
              title: 'Nuevo grupo',
              subtitle: 'Con tus contactos de KLK',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateGroupScreen())),
            ),
            _Action(
              icon: Icons.location_city,
              color: const Color(0xFF1F7A4D),
              title: 'Comunidades por ciudad',
              subtitle: 'Dominicanos en Madrid, NY, Dublín…',
              onTap: () => _soon('Unirse a comunidades'),
            ),
          ],
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!_permission)
            _PermissionCard(onRetry: _load)
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Text(_error!, textAlign: TextAlign.center),
                TextButton(onPressed: _load, child: const Text('Reintentar')),
              ]),
            )
          else ...[
            if (onKlk.isNotEmpty) _Header('EN KLK · ${onKlk.length}'),
            for (final c in onKlk)
              ListTile(
                leading: Stack(clipBehavior: Clip.none, children: [
                  ChatAvatar(id: c.phone, title: c.name, radius: 24),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(color: cs.surface, shape: BoxShape.circle),
                      child: Icon(Icons.verified, size: 16, color: cs.secondary),
                    ),
                  ),
                ]),
                title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(prettyPhone(c.phone)),
                trailing: Icon(Icons.chat_bubble_outline, color: cs.primary),
                onTap: () => _open(c),
              ),
            if (invite.isNotEmpty) _Header('INVITAR A KLK · ${invite.length}'),
            for (final c in invite)
              ListTile(
                leading: ChatAvatar(id: c.phone, title: c.name, radius: 24),
                title: Text(c.name),
                subtitle: Text(prettyPhone(c.phone)),
                trailing: OutlinedButton(
                  onPressed: () => DeviceContacts.invite(c.phone),
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Invitar'),
                ),
              ),
            if (q.isNotEmpty && onKlk.isEmpty && invite.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  Text('No hay nadie llamado "${_search.text}" en tu agenda.', textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => NewContactScreen(initialQuery: _search.text))),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Añadir como contacto nuevo'),
                  ),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, subtitle;
  final VoidCallback onTap;
  const _Action({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: CircleAvatar(radius: 24, backgroundColor: color, child: Icon(icon, color: Colors.white)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        onTap: onTap,
      );
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.secondary)),
      );
}

class _PermissionCard extends StatelessWidget {
  final VoidCallback onRetry;
  const _PermissionCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(18)),
      child: Column(children: [
        Icon(Icons.contacts, size: 44, color: cs.primary),
        const SizedBox(height: 12),
        const Text('Encuentra a tu gente en KLK',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(
          'Permite el acceso a tus contactos para ver quién ya usa KLK. '
          'Tu agenda se queda en tu móvil.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: 14),
        FilledButton(onPressed: onRetry, child: const Text('Permitir acceso')),
        const SizedBox(height: 4),
        Text('Si no aparece el aviso: Ajustes del iPhone → KLK → Contactos',
            style: TextStyle(fontSize: 11.5, color: cs.onSurface.withValues(alpha: 0.5)), textAlign: TextAlign.center),
      ]),
    );
  }
}
