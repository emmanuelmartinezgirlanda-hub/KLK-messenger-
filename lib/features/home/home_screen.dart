import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/features.dart';
import '../../core/notify/alerts.dart';
import '../../core/ui/native_glass.dart';
import '../calls/calls_view.dart';
import '../chat/presentation/archived_screen.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/chat_list_view.dart';
import '../chat/presentation/chat_screen.dart';
import '../chat/presentation/new_chat_sheet.dart';
import '../chat/presentation/starred_screen.dart';
import '../communities/communities_view.dart';
import '../contacts/my_qr_screen.dart';
import '../groups/create_group_screen.dart';
import '../hidden/hidden_chats_screen.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import '../settings/settings_view.dart';
import '../status/status_views.dart';
import '../theming/presentation/theme_picker_screen.dart';
import '../topup/recharge_sheet.dart';
import 'tabs_provider.dart';
import '../../core/l10n/l10n.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 0;

  List<String> get _titles => ['KLK messenger', tr('Estados'), tr('Comunidades'), tr('Tú'), tr('Llamadas')];

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
        label: tr('Ver'),
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
      case 'qr':
        nav.push(MaterialPageRoute(builder: (_) => const MyQrScreen()));
      case 'scan':
        nav.push(MaterialPageRoute(builder: (_) => const QrScannerScreen()));
      case 'starred':
        nav.push(MaterialPageRoute(builder: (_) => const StarredScreen()));
      case 'archived':
        nav.push(MaterialPageRoute(builder: (_) => const ArchivedScreen()));
      case 'notes':
        ref.read(appProvider).openNotes().then((id) {
          if (mounted) nav.push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)));
        });
      case 'recharge':
        showRechargeSheet(context);
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
    // Pestañas visibles (0 Chats, 1 Estados, 2 Comunidades, 3 Tú/Ajustes, 4 Llamadas)
    final hidden = ref.watch(hiddenTabsProvider);
    final visible = [0, if (!hidden.status) 1, 4, if (!hidden.communities) 2, 3];
    if (!visible.contains(_tab)) _tab = 0;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        toolbarHeight: 60,
        title: Row(children: [
          Flexible(
            child: _tab == 0
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    Image.asset('assets/brand/klk_header.png', height: 38, semanticLabel: tr('KLK')),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tr('messenger'),
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 21, color: light ? cs.primary : cs.onSurface),
                      ),
                    ),
                  ])
                : Text(_titles[_tab], style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 24)),
          ),
          const SizedBox(width: 8),
          if (app.isDemo)
            _Pill(text: tr('Demo'))
          else if (!app.online)
            _Pill(text: tr('Conectando…')),
        ]),
        actions: [
          if (_tab == 0) ...[
            // Como en WhatsApp: cámara en círculo gris y "+" en círculo rojo
            _RoundAction(
              tooltip: tr('Cámara'),
              icon: Icons.photo_camera_rounded,
              background: light ? const Color(0xFFE9EAEE) : const Color(0xFF2B2D31),
              foreground: light ? const Color(0xFF1C1D21) : Colors.white,
              onTap: () => showStatusComposer(context),
            ),
            const SizedBox(width: 10),
            _RoundAction(
              tooltip: tr('Nuevo chat'),
              icon: Icons.add_rounded,
              background: const Color(0xFFE5243B),
              foreground: Colors.white,
              onTap: () => showNewChatSheet(context),
            ),
            const SizedBox(width: 2),
          ] else
            IconButton(
              tooltip: tr('Cámara'),
              icon: const Icon(Icons.photo_camera_outlined),
              onPressed: () => showStatusComposer(context),
            ),
          PopupMenuButton<String>(
            tooltip: tr('Más opciones'),
            icon: const Icon(Icons.more_vert),
            onSelected: _menu,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'group', child: Text(tr('Nuevo grupo'))),
              PopupMenuItem(value: 'qr', child: Text(tr('Mi código QR'))),
              PopupMenuItem(value: 'scan', child: Text(tr('Escanear código QR'))),
              PopupMenuItem(value: 'notes', child: Text(tr('Notas para mí'))),
              if (kMoneyFeatures) PopupMenuItem(value: 'recharge', child: Text(tr('Recargar un móvil de RD'))),
              PopupMenuItem(value: 'starred', child: Text(tr('Mensajes destacados'))),
              PopupMenuItem(value: 'archived', child: Text(tr('Archivados'))),
              PopupMenuItem(value: 'hidden', child: Text(tr('Chats ocultos'))),
              PopupMenuItem(value: 'themes', child: Text(tr('Temas y fondos'))),
              PopupMenuItem(value: 'settings', child: Text(tr('Ajustes'))),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [ChatListView(), StatusesView(), CommunitiesView(), SettingsView(), CallsView()],
      ),
      floatingActionButton: switch (_tab) {
        1 => FloatingActionButton(
            tooltip: tr('Nuevo estado'),
            onPressed: () => showStatusComposer(context),
            child: const Icon(Icons.photo_camera_rounded),
          ),
        _ => null,
      },
      // Barra de abajo flotante y transparente (como la de WhatsApp):
      // el contenido pasa por detrás y se ve borroso.
      extendBody: true,
      bottomNavigationBar: _GlassNavBar(
        selected: _tab,
        onSelect: (t) {
          if (t == 4) app.markCallsSeen();
          setState(() => _tab = t);
        },
        items: [
          for (final k in const [1, 4, 2, 0, 3])
            if (visible.contains(k))
              switch (k) {
                0 => _NavItem(k, tr('Chats'), Icons.chat_outlined, Icons.chat, badge: unreadChats),
                1 => _NavItem(k, tr('Estados'), Icons.donut_large_outlined, Icons.donut_large),
                2 => _NavItem(k, tr('Comunidades'), Icons.groups_outlined, Icons.groups),
                4 => _NavItem(k, tr('Llamadas'), Icons.call_outlined, Icons.call, badge: app.newMissedCalls),
                _ => _NavItem(k, tr('Tú'), Icons.person_outline, Icons.person,
                    avatar: ChatAvatar(
                      id: 'me',
                      title: app.profile.name.isEmpty ? tr('Tú') : app.profile.name,
                      photoPath: app.profile.photoPath,
                      radius: 13,
                    )),
              },
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
            Text(tr('Tu cuenta está bloqueada'),
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
              child: Text(tr('Borrar los datos de este móvil')),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Botón redondo de la cabecera (cámara y "+").
class _RoundAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  const _RoundAction({
    required this.tooltip,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(width: 42, height: 42, child: Icon(icon, color: foreground, size: 25)),
          ),
        ),
      );
}

class _NavItem {
  final int tab;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final int badge;
  final Widget? avatar;
  const _NavItem(this.tab, this.label, this.icon, this.selectedIcon, {this.badge = 0, this.avatar});
}

/// Barra de pestañas flotante tipo "cristal": píldora translúcida con desenfoque.
class _GlassNavBar extends StatelessWidget {
  final int selected;
  final List<_NavItem> items;
  final ValueChanged<int> onSelect;
  const _GlassNavBar({required this.selected, required this.items, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final glass = dark ? const Color(0xFF222832).withValues(alpha: 0.62) : Colors.white.withValues(alpha: 0.72);
    final edge = dark ? Colors.white.withValues(alpha: 0.14) : Colors.black.withValues(alpha: 0.08);
    final idle = dark ? const Color(0xFFC3CAD5) : const Color(0xFF4A5260);
    final active = dark ? Colors.white : const Color(0xFF111418);
    final pill = dark ? Colors.white.withValues(alpha: 0.13) : Colors.black.withValues(alpha: 0.07);

    final row = Row(children: [
      for (final it in items)
        Expanded(
          child: _NavButton(
            item: it,
            isSelected: it.tab == selected,
            idle: idle,
            active: active,
            pill: pill,
            badgeColor: cs.secondary,
            onTap: () {
              if (it.tab != selected) HapticFeedback.selectionClick();
              onSelect(it.tab);
            },
          ),
        ),
    ]);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(34),
            boxShadow: [
              if (!nativeGlassAvailable)
                BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.45 : 0.14), blurRadius: 30, offset: const Offset(0, 12)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(34),
            // iPhone con iOS 26: el cristal de verdad de Apple. Si no, desenfoque propio.
            child: nativeGlassAvailable
                ? Stack(children: [
                    Positioned.fill(child: NativeGlass(radius: 34, dark: dark)),
                    _bar(edge, Colors.transparent, row),
                  ])
                : BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: _bar(edge, glass, row),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _bar(Color edge, Color fill, Widget row) => Container(
        height: 66,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: edge),
        ),
        child: row,
      );
}

class _NavButton extends StatelessWidget {
  final _NavItem item;
  final bool isSelected;
  final Color idle;
  final Color active;
  final Color pill;
  final Color badgeColor;
  final VoidCallback onTap;
  const _NavButton({
    required this.item,
    required this.isSelected,
    required this.idle,
    required this.active,
    required this.pill,
    required this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? active : idle;
    Widget icon = item.avatar != null
        ? AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: isSelected ? active : Colors.transparent, width: 1.5),
            ),
            child: item.avatar,
          )
        : Icon(isSelected ? item.selectedIcon : item.icon, color: color, size: 24);
    if (item.badge > 0) {
      icon = Badge(backgroundColor: badgeColor, label: Text('${item.badge}'), child: icon);
    }
    return Semantics(
      selected: isSelected,
      button: true,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 6),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: isSelected ? pill : Colors.transparent,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedScale(
                scale: isSelected ? 1.08 : 1,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutBack,
                child: SizedBox(height: 28, child: Center(child: icon)),
              ),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  fontSize: 10.5,
                  color: color,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
