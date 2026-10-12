import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/l10n.dart';
import '../../core/util/phone.dart';
import '../chat/presentation/chat_avatar.dart';
import '../chat/presentation/media_bubbles.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'contact_actions.dart';

/// Lo que la pantalla de info le pide al chat que haga al cerrarse
/// (llamar, buscar, silenciar…). Son los mismos valores que el menú ⋮.
typedef ContactInfoAction = String;

/// Foto de perfil a pantalla completa, con zoom.
class AvatarViewer extends StatelessWidget {
  final String id;
  final String title;
  final String? photoPath;
  const AvatarViewer({super.key, required this.id, required this.title, this.photoPath});

  static Future<void> open(BuildContext context, {required String id, required String title, String? photoPath}) =>
      Navigator.of(context).push(PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => AvatarViewer(id: id, title: title, photoPath: photoPath),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
      ));

  @override
  Widget build(BuildContext context) {
    final path = photoPath;
    final has = path != null && File(path).existsSync();
    final size = MediaQuery.sizeOf(context).width;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Center(
        child: Hero(
          tag: 'avatar-$id',
          child: has
              ? InteractiveViewer(maxScale: 5, child: Image.file(File(path), width: size, fit: BoxFit.contain))
              : SizedBox(
                  width: size,
                  height: size,
                  child: ColoredBox(
                    color: avatarColor(id),
                    child: Center(
                      child: Text(title.isEmpty ? '?' : title.characters.first.toUpperCase(),
                          style: TextStyle(color: Colors.white, fontSize: size * 0.4, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Foto tocable: se abre en grande (como en WhatsApp).
class TappableAvatar extends StatelessWidget {
  final String id;
  final String title;
  final String? photoPath;
  final double radius;
  const TappableAvatar({super.key, required this.id, required this.title, this.photoPath, required this.radius});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => AvatarViewer.open(context, id: id, title: title, photoPath: photoPath),
        child: Hero(
          tag: 'avatar-$id',
          child: ChatAvatar(id: id, title: title, photoPath: photoPath, radius: radius),
        ),
      );
}

/// Ventanita al tocar la foto de un chat en la lista: foto grande y accesos rápidos.
/// Devuelve 'chat', 'call', 'video' o 'info'.
Future<String?> showAvatarQuickView(BuildContext context, Chat chat) => showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final path = chat.avatarPath;
        final has = path != null && File(path).existsSync();
        final canCall = !chat.isGroup && !chat.isNotes && !chat.blocked;
        Widget act(IconData icon, String label, String value) => Expanded(
              child: InkWell(
                onTap: () => Navigator.pop(ctx, value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, color: cs.primary),
                    const SizedBox(height: 4),
                    Text(label, style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.75))),
                  ]),
                ),
              ),
            );
        return Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.symmetric(horizontal: 56),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(
              onTap: () {
                Navigator.pop(ctx);
                AvatarViewer.open(context, id: chat.id, title: chat.title, photoPath: chat.avatarPath);
              },
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(fit: StackFit.expand, children: [
                  Hero(
                    tag: 'avatar-${chat.id}',
                    child: has
                        ? Image.file(File(path), fit: BoxFit.cover)
                        : ColoredBox(
                            color: avatarColor(chat.id),
                            child: Center(
                              child: Text(chat.title.isEmpty ? '?' : chat.title.characters.first.toUpperCase(),
                                  style: const TextStyle(color: Colors.white, fontSize: 96, fontWeight: FontWeight.w800)),
                            ),
                          ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 64,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x99000000), Color(0x00000000)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    top: 12,
                    child: Text(chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
            ),
            Row(children: [
              act(Icons.chat_bubble_outline_rounded, tr('Chat'), 'chat'),
              if (canCall) act(Icons.call_outlined, tr('Llamar'), 'call'),
              if (canCall) act(Icons.videocam_outlined, tr('Vídeo'), 'video'),
              if (!chat.isNotes) act(Icons.info_outline_rounded, tr('Info'), 'info'),
            ]),
          ]),
        );
      },
    );

/// Info del contacto, como en WhatsApp: foto grande, accesos rápidos,
/// archivos compartidos, ajustes del chat y opciones de bloqueo.
/// Al cerrarse devuelve la acción que el chat debe hacer (o null).
class ContactInfoScreen extends ConsumerWidget {
  final String chatId;
  const ContactInfoScreen({super.key, required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final chat = app.chatById(chatId);
    final cs = Theme.of(context).colorScheme;
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text(tr('Este contacto ya no existe'))));
    }
    final now = DateTime.now();
    final seen = presenceLabel(app.presence[chatId], now);
    final zone = zoneForPhone(chat.phone);
    final messages = app.messagesFor(chatId).where((m) => !m.deleted).toList();
    final media = messages.reversed
        .where((m) =>
            (m.media?.type == MediaType.image || m.media?.type == MediaType.video) &&
            !(m.media?.viewOnce ?? false) &&
            m.media?.localPath != null &&
            File(m.media!.localPath!).existsSync())
        .toList();
    final docs = messages.where((m) => m.media?.type == MediaType.file).length;
    final links = messages.where((m) => m.link != null || m.body.contains('http')).length;
    final starred = messages.where((m) => m.starred).length;
    final groups = app.chats.where((c) => c.isGroup && c.members.any((m) => m.id == chatId)).toList();
    final blocked = chat.blocked;
    final muted = cs.onSurface.withValues(alpha: 0.62);

    Widget section(List<Widget> children, {String? title}) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
                  child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: muted)),
                ),
              ...children,
            ]),
          ),
        );

    Widget row(IconData icon, String title, {String? subtitle, String? trailing, Color? color, VoidCallback? onTap}) =>
        ListTile(
          leading: Icon(icon, color: color ?? cs.onSurface.withValues(alpha: 0.75)),
          title: Text(title, style: TextStyle(color: color, fontWeight: color != null ? FontWeight.w600 : null)),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: trailing == null
              ? (onTap == null || color != null ? null : Icon(Icons.chevron_right_rounded, color: muted))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(trailing, style: TextStyle(color: muted)),
                  Icon(Icons.chevron_right_rounded, color: muted),
                ]),
          onTap: onTap,
        );

    Widget quick(IconData icon, String label, String action) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Material(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.pop(context, action),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(children: [
                    Icon(icon, color: cs.primary),
                    const SizedBox(height: 6),
                    Text(label, style: TextStyle(fontSize: 12.5, color: cs.primary, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),
        );

    String? birthday;
    final bd = chat.birthday;
    if (bd != null && bd.length == 5) {
      final m = int.tryParse(bd.substring(0, 2));
      final d = int.tryParse(bd.substring(3));
      if (m != null && d != null && m >= 1 && m <= 12) {
        birthday = DateFormat.MMMMd(currentLanguageCode()).format(DateTime(2000, m, d));
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Info. del contacto')),
        actions: [
          if (!chat.isNotes)
            IconButton(
              tooltip: isUnsavedContact(chat) ? tr('Añadir a contactos') : tr('Editar contacto'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => editContactName(context, ref.read(appProvider), chat),
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        const SizedBox(height: 8),
        Center(child: TappableAvatar(id: chat.id, title: chat.title, photoPath: chat.avatarPath, radius: 66)),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(chat.title,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        ),
        if (chat.phone.isNotEmpty && chat.title != prettyPhone(chat.phone))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(prettyPhone(chat.phone),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: muted)),
          ),
        if (seen != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(seen,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13.5,
                    color: seen == tr('en línea') ? cs.secondary : muted,
                    fontWeight: seen == tr('en línea') ? FontWeight.w600 : null)),
          ),
        const SizedBox(height: 18),
        if (!chat.isNotes)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
            child: Row(children: [
              if (!blocked) quick(Icons.call_outlined, tr('Llamar'), 'call'),
              if (!blocked) quick(Icons.videocam_outlined, tr('Vídeo'), 'video'),
              quick(Icons.search_rounded, tr('Buscar'), 'search'),
              quick(chat.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined,
                  chat.muted ? tr('Activar') : tr('Silenciar'), chat.muted ? 'unmute' : 'mute'),
            ]),
          ),
        if (zone != null || birthday != null)
          section([
            if (zone != null)
              row(Icons.schedule_rounded, '${tr('Hora local')}: ${DateFormat.jm(currentLanguageCode()).format(nowIn(zone.zone))}',
                  subtitle: zone.place),
            if (birthday != null) row(Icons.cake_outlined, '${tr('Cumpleaños')}: $birthday'),
          ]),
        section([
          ListTile(
            title: Text(tr('Archivos, enlaces y documentos'), style: const TextStyle(fontWeight: FontWeight.w600)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${media.length + docs + links}', style: TextStyle(color: muted)),
              Icon(Icons.chevron_right_rounded, color: muted),
            ]),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SharedMediaScreen(chatId: chatId))),
          ),
          if (media.isNotEmpty)
            SizedBox(
              height: 96,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                scrollDirection: Axis.horizontal,
                itemCount: media.length > 12 ? 12 : media.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) => _MediaThumb(message: media[i], size: 84),
              ),
            ),
        ]),
        section([
          row(Icons.star_outline_rounded, tr('Mensajes destacados'),
              trailing: starred == 0 ? tr('Ninguno') : '$starred', onTap: () => Navigator.pop(context, 'starred')),
          if (!chat.isNotes) ...[
            row(chat.muted ? Icons.notifications_off_outlined : Icons.notifications_none_rounded, tr('Notificaciones'),
                trailing: chat.muted ? tr('Silenciado') : tr('Activadas'),
                onTap: () => Navigator.pop(context, chat.muted ? 'unmute' : 'mute')),
            row(Icons.timer_outlined, tr('Mensajes temporales'),
                trailing: disappearLabel(chat.disappearSec), onTap: () => Navigator.pop(context, 'timer')),
          ],
          row(Icons.wallpaper_outlined, tr('Fondo de pantalla'), onTap: () => Navigator.pop(context, 'wallpaper')),
          if (!chat.isNotes)
            row(Icons.lock_outline_rounded, tr('Cifrado'),
                subtitle: tr('Mensajes y llamadas cifrados de punta a punta. Toca para ver el código de seguridad.'),
                onTap: () => Navigator.pop(context, 'safety')),
        ]),
        if (groups.isNotEmpty)
          section([
            for (final g in groups)
              ListTile(
                leading: ChatAvatar(id: g.id, title: g.title, photoPath: g.avatarPath, radius: 20),
                title: Text(g.title),
                subtitle: Text('${g.members.length + 1} ${tr('miembros')}'),
              ),
          ], title: '${groups.length} ${groups.length == 1 ? tr('grupo en común') : tr('grupos en común')}'),
        section([
          row(chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
              chat.archived ? tr('Desarchivar chat') : tr('Archivar chat'), onTap: () => Navigator.pop(context, 'archive')),
          row(chat.hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              chat.hidden ? tr('Mostrar en la lista') : tr('Ocultar chat'), onTap: () => Navigator.pop(context, 'hide')),
        ]),
        if (!chat.isNotes)
          section([
            row(Icons.block_rounded, blocked ? '${tr('Desbloquear a')} ${chat.title}' : '${tr('Bloquear a')} ${chat.title}',
                color: const Color(0xFFE5484D), onTap: () => Navigator.pop(context, 'block')),
            row(Icons.thumb_down_outlined, '${tr('Denunciar a')} ${chat.title}',
                color: const Color(0xFFE5484D), onTap: () => Navigator.pop(context, 'report')),
            row(Icons.delete_outline_rounded, tr('Eliminar contacto'),
                color: const Color(0xFFE5484D), onTap: () => Navigator.pop(context, 'delete')),
          ]),
      ]),
    );
  }
}

class _MediaThumb extends StatelessWidget {
  final Message message;
  final double size;
  const _MediaThumb({required this.message, required this.size});

  @override
  Widget build(BuildContext context) {
    final media = message.media!;
    final path = media.localPath!;
    final video = media.type == MediaType.video;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => video ? VideoViewer(path: path) : ImageViewer(path: path))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: size,
          height: size,
          child: video
              ? const ColoredBox(
                  color: Colors.black87,
                  child: Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 34)),
                )
              : Hero(tag: path, child: Image.file(File(path), fit: BoxFit.cover, cacheWidth: (size * 3).round())),
        ),
      ),
    );
  }
}

/// Todo lo compartido en el chat: fotos y vídeos, documentos y enlaces.
class SharedMediaScreen extends ConsumerWidget {
  final String chatId;
  const SharedMediaScreen({super.key, required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final msgs = app.messagesFor(chatId).where((m) => !m.deleted).toList().reversed.toList();
    final media = msgs
        .where((m) =>
            (m.media?.type == MediaType.image || m.media?.type == MediaType.video) &&
            !(m.media?.viewOnce ?? false) &&
            m.media?.localPath != null &&
            File(m.media!.localPath!).existsSync())
        .toList();
    final docs = msgs.where((m) => m.media?.type == MediaType.file).toList();
    final linkRe = RegExp(r'https?://\S+');
    final links = [
      for (final m in msgs)
        for (final l in linkRe.allMatches(m.body)) (m, l.group(0)!),
    ];
    Widget empty(String t) => Center(
        child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)))));
    final df = DateFormat.yMMMd(currentLanguageCode());
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(app.chatById(chatId)?.title ?? ''),
          bottom: TabBar(tabs: [
            Tab(text: tr('Multimedia')),
            Tab(text: tr('Documentos')),
            Tab(text: tr('Enlaces')),
          ]),
        ),
        body: TabBarView(children: [
          media.isEmpty
              ? empty(tr('Aquí saldrán las fotos y vídeos que os enviéis.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                  itemCount: media.length,
                  itemBuilder: (_, i) => LayoutBuilder(
                      builder: (_, c) => _MediaThumb(message: media[i], size: c.maxWidth)),
                ),
          docs.isEmpty
              ? empty(tr('Aquí saldrán los documentos que os enviéis.'))
              : ListView(children: [
                  for (final m in docs)
                    ListTile(
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(m.media?.name ?? tr('Documento'), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(df.format(m.createdAt)),
                    ),
                ]),
          links.isEmpty
              ? empty(tr('Aquí saldrán los enlaces que os enviéis.'))
              : ListView(children: [
                  for (final (m, url) in links)
                    ListTile(
                      leading: const Icon(Icons.link_rounded),
                      title: SelectableText(url, maxLines: 2),
                      subtitle: Text(df.format(m.createdAt)),
                    ),
                ]),
        ]),
      ),
    );
  }
}
