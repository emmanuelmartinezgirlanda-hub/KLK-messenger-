import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';
import '../privacy/presentation/privacy_screen.dart';
import '../theming/presentation/theme_picker_screen.dart';
import '../theming/presentation/theme_provider.dart';

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final theme = ref.watch(themeProvider);
    final cs = Theme.of(context).colorScheme;
    final s = app.session;

    return ListView(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          leading: CircleAvatar(
            radius: 28,
            backgroundColor: cs.primary,
            child: const Text('TÚ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          title: Text(s == null ? '' : prettyPhone(s.phone),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          subtitle: Text(app.isDemo ? 'Modo demo · sin servidor' : (app.online ? 'Conectado' : 'Sin conexión')),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Privacidad'),
          subtitle: const Text('Última conexión, lecturas, escribiendo…'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Temas'),
          subtitle: Text('${theme.name} · colores, burbujas y fuente'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemePickerScreen())),
        ),
        if (s != null && !s.isDemo)
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Servidor'),
            subtitle: Text(s.server),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF6B7A)),
          title: const Text('Botón de pánico', style: TextStyle(color: Color(0xFFFF6B7A))),
          subtitle: const Text('Borra todos los chats y claves de este móvil'),
          onTap: () => _confirmPanic(context, ref),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text('KLK 0.1.0 · Tu gente, donde tú estés.',
              style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _confirmPanic(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar todo?'),
        content: const Text(
            'Se borrarán todos tus chats y claves de este móvil. No se puede deshacer y tendrás que registrarte otra vez.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar todo'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(appProvider).panic();
  }
}
