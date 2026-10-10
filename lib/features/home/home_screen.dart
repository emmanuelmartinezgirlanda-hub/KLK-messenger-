import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notify/alerts.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_list_view.dart';
import '../chat/presentation/chat_screen.dart';
import '../chat/presentation/new_chat_sheet.dart';
import '../communities/communities_view.dart';
import '../groups/create_group_screen.dart';
import '../hidden/hidden_chats_screen.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import '../settings/settings_view.dart';
import '../status/status_views.dart';
import '../theming/presentation/theme_picker_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  static const _titles = ['KLK messenger', 'Estados', 'Comunidades', 'Ajustes'];

  @override
  void initState() {
    super.initState();
    // Aviso dentro de la app cuando llega un mensaje a otro chat
    ref.read(appProvider).onNotify = _notify;
    // Al tocar una notificación se abre ese chat
    Alerts.instance.attach((chatId) {
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
    });
  }

  void _notify(Chat chat, Message m) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 4),
      content: Row(children: [
        ChatAvatar(id: chat.id, title: chat.title, photoPath: chat.avatarPath, radius: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(chat.title, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(m.isMine ? m.summary : (m.sender.isEmpty ? m.summary : '${m.sender}: ${m.summary}'),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
      action: SnackBarAction(
        label: 'Ver',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id))),
      ),
    ));
  }

  void _menu(String action) {
    final nav = Navigator.of(context);
    switch (action) {
      case 'group':
        nav.push(MaterialPageRoute(builder: (_) => const CreateGroupScreen()));
      case 'hidden':
        nav.push(MaterialPageRoute(builder: (_) => const HiddenChatsScreen()));
      case 'themes':
        nav.push(MaterialPageRoute(builder: (_) => const ThemePickerScreen()));
      case 'settings':
        setState(() => _tab = 3);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;

    if (app.banned) return const _BannedScreen();

    final unreadChats = app.visibleChats.where((c) => c.unread > 0).length;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        toolbarHeight: 60,
        title: Row(children: [
          Flexible(
            child: _tab == 0
                ? Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: 'KLK',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 25, color: light ? cs.primary : cs.onSurface, letterSpacing: 0.4),
                      ),
                      TextSpan(
                        text: ' messenger',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18, color: cs.secondary),
                      ),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                  )
                : Text(_titles[_tab], style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 24)),
          ),
          const SizedBox(width: 8),
          if (app.isDemo)
            const _Pill(text: 'Demo')
          else if (!app.online)
            const _Pill(text: 'Conectando…'),
        ]),
        actions: [
          IconButton(
            tooltip: 'Cámara',
            icon: const Icon(Icons.photo_camera_outlined),
            onPressed: () => showStatusComposer(context),
          ),
          PopupMenuButton<String>(
            tooltip: 'Más opciones',
            icon: const Icon(Icons.more_vert),
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'group', child: Text('Nuevo grupo')),
              PopupMenuItem(value: 'hidden', child: Text('Chats ocultos')),
              PopupMenuItem(value: 'themes', child: Text('Temas y fondos')),
              PopupMenuItem(value: 'settings', child: Text('Ajustes')),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [ChatListView(), StatusesView(), CommunitiesView(), SettingsView()],
      ),
      floatingActionButton: switch (_tab) {
        0 => FloatingActionButton(
            tooltip: 'Nuevo chat',
            onPressed: () => showNewChatSheet(context),
            child: const Icon(Icons.add_comment_rounded),
          ),
        1 => FloatingActionButton(
            tooltip: 'Nuevo estado',
            onPressed: () => showStatusComposer(context),
            child: const Icon(Icons.photo_camera_rounded),
          ),
        _ => null,
      },
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.onSurface.withValues(alpha: 0.08)))),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            NavigationDestination(
              icon: Badge(
                isLabelVisible: unreadChats > 0,
                backgroundColor: cs.secondary,
                label: Text('$unreadChats'),
                child: const Icon(Icons.chat_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: unreadChats > 0,
                backgroundColor: cs.secondary,
                label: Text('$unreadChats'),
                child: const Icon(Icons.chat),
              ),
              label: 'Chats',
            ),
            const NavigationDestination(
                icon: Icon(Icons.donut_large_outlined), selectedIcon: Icon(Icons.donut_large), label: 'Estados'),
            const NavigationDestination(
                icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Comunidades'),
            const NavigationDestination(
                icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ajustes'),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
      );
}

/// Pantalla que ve una cuenta bloqueada por el dueño de KLK.
class _BannedScreen extends ConsumerWidget {
  const _BannedScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.gpp_bad_outlined, size: 72, color: cs.secondary),
            const SizedBox(height: 20),
            const Text('Tu cuenta está bloqueada',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
              'KLK bloqueó esta cuenta por incumplir las normas (spam, acoso o estafas). '
              'Si crees que es un error, escríbenos a soporte.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7), fontSize: 15.5),
            ),
            const SizedBox(height: 28),
            OutlinedButton(
              onPressed: () => ref.read(appProvider).panic(),
              child: const Text('Borrar los datos de este móvil'),
            ),
          ]),
        ),
      ),
    );
  }
}
