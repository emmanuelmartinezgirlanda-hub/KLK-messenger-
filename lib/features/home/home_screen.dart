import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/brand/klk_brand.dart';
import '../../core/brand/klk_logo.dart';
import '../chat/presentation/chat_list_view.dart';
import '../chat/presentation/new_chat_sheet.dart';
import '../communities/communities_view.dart';
import '../messaging/app_controller.dart';
import '../settings/settings_view.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(children: [
          const KlkEmblem(size: 34),
          const SizedBox(width: 10),
          Text(KlkBrand.name,
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 26, color: cs.primary, letterSpacing: 0.5)),
          const SizedBox(width: 10),
          if (app.isDemo)
            const _Pill(text: 'Modo demo')
          else if (!app.online)
            const _Pill(text: 'Conectando…'),
        ]),
      ),
      body: IndexedStack(
        index: _tab,
        children: const [ChatListView(), CommunitiesView(), SettingsView()],
      ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              backgroundColor: cs.secondary,
              foregroundColor: cs.onSecondary,
              tooltip: 'Nuevo chat',
              onPressed: () => showNewChatSheet(context),
              child: const Icon(Icons.add_comment_outlined),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Chats'),
          NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Comunidades'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ajustes'),
        ],
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
