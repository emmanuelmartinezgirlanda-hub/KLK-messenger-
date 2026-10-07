import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/brand/klk_logo.dart';
import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../hidden/hidden_chats_screen.dart';
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
        const _ProfileHeader(),
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
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Chats ocultos'),
          subtitle: Text(app.hiddenChats.isEmpty ? 'Protegidos con tu PIN' : '${app.hiddenChats.length} ocultos · protegidos con tu PIN'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HiddenChatsScreen())),
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
        const Center(child: KlkLogo(height: 120)),
        const SizedBox(height: 12),
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


/// Cabecera de Ajustes: mi foto y mi nombre, editables.
class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final s = app.session;
    final name = app.profile.name;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 12),
      child: Row(children: [
        GestureDetector(
          onTap: () => _changePhoto(context, ref),
          child: Stack(children: [
            ChatAvatar(id: 'me', title: name.isEmpty ? 'Tú' : name, photoPath: app.profile.photoPath, radius: 36),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(color: cs.secondary, shape: BoxShape.circle,
                    border: Border.all(color: cs.surface, width: 2)),
                child: Icon(Icons.photo_camera, size: 14, color: cs.onSecondary),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? 'Ponte un nombre' : name,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                    color: name.isEmpty ? cs.onSurface.withValues(alpha: 0.5) : null)),
            const SizedBox(height: 2),
            Text(s == null ? '' : prettyPhone(s.phone), style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65))),
            Text(app.isDemo ? 'Modo demo · sin servidor' : (app.online ? 'Conectado' : 'Sin conexión'),
                style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
          ]),
        ),
        IconButton(
          tooltip: 'Cambiar nombre',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => _editName(context, ref, name),
        ),
      ]),
    );
  }

  Future<void> _changePhoto(BuildContext context, WidgetRef ref) async {
    final hasPhoto = ref.read(appProvider).profile.photoPath != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Elegir de la galería'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Hacer una foto'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A)),
              title: const Text('Quitar foto', style: TextStyle(color: Color(0xFFFF6B7A))),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
        ]),
      ),
    );
    if (choice == null) return;
    final app = ref.read(appProvider);
    if (choice == 'remove') {
      await app.updateProfile(removePhoto: true);
      return;
    }
    try {
      final x = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 800, // la foto de perfil no necesita más resolución
        imageQuality: 85,
        preferredCameraDevice: CameraDevice.front,
      );
      if (x != null) await app.updateProfile(photoSourcePath: x.path);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('KLK no tiene permiso para tus fotos o la cámara. Actívalo en Ajustes del iPhone → KLK.')));
      }
    }
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, String current) async {
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tu nombre'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Como te verán tus contactos'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name != null) await ref.read(appProvider).updateProfile(name: name);
  }
}
