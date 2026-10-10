import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/presentation/chat_screen.dart';
import '../messaging/app_controller.dart';
import 'community.dart';

/// Comunidades por país: la lista y el número de miembros son REALES (del servidor).
/// Te puedes unir a la de tu país, a otras o a todas. Cada comunidad tiene su chat.
class CommunitiesView extends ConsumerStatefulWidget {
  const CommunitiesView({super.key});

  @override
  ConsumerState<CommunitiesView> createState() => _CommunitiesViewState();
}

class _CommunitiesViewState extends ConsumerState<CommunitiesView> {
  final Set<String> _busy = {};
  bool _joiningAll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(appProvider).loadCommunities());
  }

  void _say(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggle(Community c) async {
    final app = ref.read(appProvider);
    if (c.joined) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('¿Salir de ${c.title}?'),
          content: const Text('Se borrará el chat de la comunidad de este móvil.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salir')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy.add(c.id));
    try {
      await app.setCommunityJoined(c, !c.joined);
      if (!c.joined) _say('Te uniste a ${c.title}');
    } catch (e) {
      _say('No se pudo: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(c.id));
    }
  }

  Future<void> _joinAll() async {
    setState(() => _joiningAll = true);
    try {
      await ref.read(appProvider).joinAllCommunities();
      _say('Te uniste a todas las comunidades');
    } catch (e) {
      _say('No se pudo: $e');
    } finally {
      if (mounted) setState(() => _joiningAll = false);
    }
  }

  void _open(Community c) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: c.chatId)));

  Widget _tile(Community c, {bool mine = false}) {
    final cs = Theme.of(context).colorScheme;
    final busy = _busy.contains(c.id);
    final count = c.members == 0
        ? 'Aún no hay nadie · sé el primero'
        : (c.members == 1 ? '1 miembro' : '${c.members} miembros');
    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
        child: Text(c.flag, style: const TextStyle(fontSize: 26)),
      ),
      title: Text(c.id == 'DO' ? 'República Dominicana' : 'Dominicanos en ${c.name}',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(mine ? 'Tu país · $count' : count),
      onTap: c.joined ? () => _open(c) : null,
      trailing: busy
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
          : c.joined
              ? OutlinedButton(onPressed: () => _toggle(c), child: const Text('Salir'))
              : FilledButton(onPressed: () => _toggle(c), child: const Text('Unirme')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final myCountry = countryOfPhone(app.session?.phone ?? '');
    final list = app.communities;
    final mine = list.where((c) => c.id == myCountry).toList();
    final joined = list.where((c) => c.joined && c.id != myCountry).toList();
    final others = list.where((c) => !c.joined && c.id != myCountry).toList();
    final pending = list.where((c) => !c.joined).length;

    Widget label(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Text(text,
              style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: cs.secondary)),
        );

    return RefreshIndicator(
      onRefresh: app.loadCommunities,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          label('TU GENTE POR PAÍS'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              app.isDemo
                  ? 'Modo demo: las comunidades de verdad funcionan con el servidor de KLK.'
                  : 'Únete a la comunidad de tu país, a otras o a todas. En los chats de comunidad tu número no se muestra.',
              style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          if (app.communitiesLoading && list.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          if (app.communitiesError != null && list.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Text('No se pudieron cargar las comunidades.\n${app.communitiesError}', textAlign: TextAlign.center),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: app.loadCommunities, child: const Text('Reintentar')),
              ]),
            ),
          if (list.isNotEmpty && pending > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: FilledButton.tonalIcon(
                icon: _joiningAll
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.public),
                label: const Text('Unirme a todas'),
                onPressed: _joiningAll ? null : _joinAll,
              ),
            ),
          if (mine.isNotEmpty) ...[label('TU PAÍS'), for (final c in mine) _tile(c, mine: true)],
          if (joined.isNotEmpty) ...[label('MIS COMUNIDADES'), for (final c in joined) _tile(c)],
          if (others.isNotEmpty) ...[label('OTROS PAÍSES'), for (final c in others) _tile(c)],
          const SizedBox(height: 12),
          const _NewsSection(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}


/// Pelota y noticias de RD: accesos directos a las webs oficiales.
/// (Los resultados en vivo dentro de KLK necesitan un proveedor de datos deportivos.)
class _NewsSection extends StatelessWidget {
  const _NewsSection();

  static const _links = [
    ('⚾', 'Pelota invernal (LIDOM)', 'Calendario, resultados y posiciones', 'https://www.lidom.com'),
    ('⚾', 'Dominicanos en Grandes Ligas', 'MLB en español', 'https://www.mlb.com/es'),
    ('📰', 'Diario Libre', 'Noticias de RD', 'https://www.diariolibre.com'),
    ('📰', 'Listín Diario', 'Noticias de RD', 'https://listindiario.com'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(children: [
        const ListTile(
          title: Text('Pelota y noticias de RD', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('Se abren en tu navegador. Los resultados en vivo dentro de KLK llegarán más adelante.'),
        ),
        for (final (icon, title, sub, url) in _links)
          ListTile(
            leading: CircleAvatar(backgroundColor: cs.surfaceContainerHighest, child: Text(icon)),
            title: Text(title),
            subtitle: Text(sub),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          ),
      ]),
    );
  }
}
