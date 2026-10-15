import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/brand/klk_logo.dart';
import '../../core/config.dart';
import '../../core/network/api_client.dart';
import '../../core/l10n/l10n.dart';
import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../contacts/my_qr_screen.dart';
import '../hidden/hidden_chats_screen.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import '../privacy/presentation/privacy_screen.dart';
import '../theming/presentation/theme_picker_screen.dart';
import '../theming/presentation/theme_provider.dart';
import '../theming/wallpapers.dart';
import '../../core/security/secure_store.dart';
import '../home/tabs_provider.dart';
import 'backup_screen.dart';
import 'notifications_screen.dart';
import 'translator_settings_screen.dart';
import '../../core/translate/translator.dart';

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  static Future<void> _pickLanguage(BuildContext context, WidgetRef ref) async {
    final current = ref.read(languageProvider);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget option(String? code, String title, {String? subtitle}) {
          final selected = current == code;
          return ListTile(
            title: Text(title, style: TextStyle(fontWeight: selected ? FontWeight.w700 : null)),
            subtitle: subtitle == null ? null : Text(subtitle),
            trailing: selected ? Icon(Icons.check_circle_rounded, color: Theme.of(ctx).colorScheme.primary) : null,
            onTap: () => Navigator.pop(ctx, code ?? 'auto'),
          );
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(tr('Idioma de la app'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              option(null, tr('Automático'),
                  subtitle: '${tr('El mismo que tu móvil')} · ${supportedLanguages[deviceLanguage()]}'),
              for (final e in supportedLanguages.entries) option(e.key, e.value),
            ]),
          ),
        );
      },
    );
    if (picked == null) return;
    await ref.read(languageProvider.notifier).choose(picked == 'auto' ? null : picked);
  }

  static String _tabsLabel(HiddenTabs t) {
    final off = [if (t.status) 'Estados', if (t.communities) 'Comunidades'];
    return off.isEmpty ? 'Todas visibles' : 'Ocultas: ${off.join(' y ')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final theme = ref.watch(themeProvider);
    final cs = Theme.of(context).colorScheme;
    final s = app.session;

    return ListView(
      children: [
        const _ProfileHeader(),
        if (app.isDemo)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            color: cs.primary.withValues(alpha: 0.10),
            elevation: 0,
            child: ListTile(
              leading: Icon(Icons.login_rounded, color: cs.primary),
              title: Text(tr('Usar KLK de verdad'), style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(tr('Sal del modo demo y entra con tu número de móvil')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _leaveDemo(context, ref),
            ),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.language_rounded),
          title: Text(tr('Idioma de la app')),
          subtitle: Text(ref.watch(languageProvider) == null
              ? '${tr('Automático')} · ${supportedLanguages[deviceLanguage()]}'
              : supportedLanguages[ref.watch(languageProvider)]!),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickLanguage(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: Text(tr('Notificaciones')),
          subtitle: Text(tr('Sonido, avisos y vibración')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.translate),
          title: Text(tr('Traductor')),
          subtitle: Text(ref.watch(translatorProvider).auto
              ? 'Automático · a ${ref.watch(translatorProvider).myLanguageName.toLowerCase()}'
              : 'Traduce mensajes en otros idiomas'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TranslatorSettingsScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: Text(tr('Privacidad')),
          subtitle: Text(tr('Última conexión, lecturas, escribiendo…')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: Text(tr('Temas')),
          subtitle: Text('${theme.name} · colores, burbujas y fuente'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemePickerScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.wallpaper_outlined),
          title: Text(tr('Fondo de los chats')),
          subtitle: Text('${wallpaperName(ref.watch(wallpaperProvider))} · ilustraciones, colores o tu foto'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showWallpaperPicker(context),
        ),
        ListTile(
          leading: const Icon(Icons.view_week_outlined),
          title: Text(tr('Pestañas')),
          subtitle: Text(_tabsLabel(ref.watch(hiddenTabsProvider))),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => Consumer(builder: (ctx, ref, _) {
              final t = ref.watch(hiddenTabsProvider);
              final n = ref.read(hiddenTabsProvider.notifier);
              return AlertDialog(
                title: Text(tr('Pestañas que ves abajo')),
                contentPadding: const EdgeInsets.only(top: 12),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  SwitchListTile(
                    title: Text(tr('Estados')),
                    value: !t.status,
                    onChanged: (v) => n.set(HiddenTabs(status: !v, communities: t.communities)),
                  ),
                  SwitchListTile(
                    title: Text(tr('Comunidades')),
                    value: !t.communities,
                    onChanged: (v) => n.set(HiddenTabs(status: t.status, communities: !v)),
                  ),
                ]),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Listo')))],
              );
            }),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: Text(tr('Chats ocultos')),
          subtitle: Text(app.hiddenChats.isEmpty ? tr('Protegidos con tu PIN') : '${app.hiddenChats.length} ocultos · protegidos con tu PIN'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HiddenChatsScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_upload_outlined),
          title: Text(tr('Copia de seguridad')),
          subtitle: Text(tr('Cifrada con tu contraseña · Archivos o iCloud')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BackupScreen())),
        ),
        if (s != null && !s.isDemo)
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(tr('Servidor')),
            subtitle: Text(s.server),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: Text(tr('Ayuda')),
          subtitle: Text(tr('Preguntas frecuentes y contacto')),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openWeb(s?.server, '/soporte'),
        ),
        ListTile(
          leading: const Icon(Icons.policy_outlined),
          title: Text(tr('Política de privacidad')),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openWeb(s?.server, '/privacidad'),
        ),
        if (s != null && !s.isDemo)
          ListTile(
            leading: const Icon(Icons.person_remove_outlined, color: Color(0xFFFF6B7A)),
            title: Text(tr('Eliminar mi cuenta'), style: const TextStyle(color: Color(0xFFFF6B7A))),
            subtitle: Text(tr('Borra tu cuenta del servidor y todo lo de este móvil')),
            onTap: () => _confirmDeleteAccount(context, ref),
          ),
        ListTile(
          leading: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF6B7A)),
          title: Text(tr('Botón de pánico'), style: TextStyle(color: Color(0xFFFF6B7A))),
          subtitle: Text(tr('Borra todos los chats y claves de este móvil')),
          onTap: () => _confirmPanic(context, ref),
        ),
        const SizedBox(height: 24),
        const Center(child: KlkLogo(height: 120)),
        const SizedBox(height: 12),
        Center(
          child: Text(tr('KLK messenger 1.0.0 · Tu gente, donde tú estés.'),
              style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _leaveDemo(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('¿Salir del modo demo?')),
        content: Text(tr('Se borran los chats de ejemplo y vuelves a la pantalla de inicio para entrar con tu número.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Salir'))),
        ],
      ),
    );
    if (ok == true) await ref.read(appProvider).panic();
  }

  static Future<void> _openWeb(String? server, String path) async {
    final base = (server == null || server.isEmpty) ? KlkConfig.officialServer : server;
    final uri = Uri.parse(base).replace(path: path);
    if (!await launchUrl(uri, mode: LaunchMode.inAppBrowserView).catchError((_) => false)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    }
  }

  Future<void> _confirmDeleteAccount(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.person_remove_outlined, color: Color(0xFFCE1126), size: 36),
        title: Text(tr('¿Eliminar tu cuenta?')),
        content: Text(tr('Se borrará tu cuenta de KLK: tu número dejará de aparecer, tus mensajes pendientes, '
            'comunidades y recargas se borran del servidor, y todos tus chats se borran de este móvil. '
            'No se puede deshacer.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Eliminar cuenta')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final app = ref.read(appProvider);
    try {
      await app.deleteAccountOnServer();
    } catch (e) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(
          content: Text(e is ApiException ? e.message : tr('No se pudo eliminar la cuenta. Revisa tu conexión.'))));
      return;
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await app.panic();
  }

  Future<void> _confirmPanic(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('¿Borrar todo?')),
        content: Text(
            tr('Se borrarán todos tus chats y claves de este móvil. No se puede deshacer y tendrás que registrarte otra vez.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Borrar todo')),
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
            ChatAvatar(id: 'me', title: name.isEmpty ? tr('Tú') : name, photoPath: app.profile.photoPath, radius: 36),
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
            Text(name.isEmpty ? tr('Ponte un nombre') : name,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                    color: name.isEmpty ? cs.onSurface.withValues(alpha: 0.5) : null)),
            const SizedBox(height: 2),
            Text(s == null ? '' : prettyPhone(s.phone), style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65))),
            Text(app.isDemo ? tr('Modo demo · sin servidor') : (app.online ? tr('Conectado') : tr('Sin conexión')),
                style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
            InkWell(
              onTap: () => _editBirthday(context, ref),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  !isValidBirthday(app.profile.birthday)
                      ? '🎂 Añade tu cumpleaños'
                      : '🎂 ${_birthdayLabel(app.profile.birthday!)}',
                  style: TextStyle(fontSize: 13, color: cs.secondary, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ]),
        ),
        IconButton(
          tooltip: tr('Mi código QR'),
          icon: Icon(Icons.qr_code_2, color: cs.primary),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyQrScreen())),
        ),
        IconButton(
          tooltip: tr('Cambiar nombre'),
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
            title: Text(tr('Elegir de la galería')),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(tr('Hacer una foto')),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A)),
              title: Text(tr('Quitar foto'), style: TextStyle(color: Color(0xFFFF6B7A))),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('KLK no tiene permiso para tus fotos o la cámara. Actívalo en Ajustes del iPhone → KLK.'))));
      }
    }
  }

  static String _birthdayLabel(String mmdd) {
    final parts = mmdd.split('-');
    return DateFormat.MMMMd('es').format(DateTime(2000, int.parse(parts[0]), int.parse(parts[1])));
  }

  static const _birthYearKey = 'klk.birthYear';

  /// Eliges la fecha completa (desde 1900), pero a tus contactos solo les llega el día y el mes.
  Future<void> _editBirthday(BuildContext context, WidgetRef ref) async {
    final app = ref.read(appProvider);
    final store = ref.read(secureStoreProvider);
    final current = app.profile.birthday;
    final now = DateTime.now();
    int? savedYear;
    try {
      savedYear = int.tryParse(await store.read(_birthYearKey) ?? '');
    } catch (_) {}
    var initial = DateTime(2000, now.month, now.day);
    if (isValidBirthday(current)) {
      final m = int.parse(current!.split('-')[0]), d = int.parse(current.split('-')[1]);
      final y = (savedYear != null && savedYear >= 1900 && savedYear <= now.year) ? savedYear : 2000;
      final candidate = DateTime(y, m, d);
      // 29 de febrero en un año no bisiesto: usa el 2000
      initial = candidate.month == m ? candidate : DateTime(2000, m, d);
    }
    if (initial.isAfter(now)) initial = DateTime(2000, initial.month, initial.day);
    if (!context.mounted) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900, 1, 1),
      lastDate: now,
      helpText: 'Tu fecha de nacimiento (tu edad no se comparte)',
      initialEntryMode: DatePickerEntryMode.calendar,
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked == null) {
      if (current != null && context.mounted) {
        final remove = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('¿Quitar tu cumpleaños?')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('No'))),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Quitar'))),
            ],
          ),
        );
        if (remove == true) {
          await app.updateProfile(removeBirthday: true);
          try {
            await store.write(_birthYearKey, '');
          } catch (_) {}
        }
      }
      return;
    }
    final mmdd = '${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    await app.updateProfile(birthday: mmdd);
    try {
      await store.write(_birthYearKey, picked.year.toString());
    } catch (_) {}
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, String current) async {
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Tu nombre')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: tr('Como te verán tus contactos')),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('Guardar'))),
        ],
      ),
    );
    if (name != null) await ref.read(appProvider).updateProfile(name: name);
  }
}
