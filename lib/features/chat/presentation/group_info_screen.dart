import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/network/api_client.dart';
import '../../../core/util/phone.dart';
import '../../communities/community.dart';
import '../../contacts/contact_info_screen.dart';
import '../../messaging/app_controller.dart';
import '../../messaging/models.dart';
import 'chat_avatar.dart';
import 'chat_screen.dart';

/// Info del grupo, como en WhatsApp: foto, nombre, cuántos son y la lista
/// de participantes. Al tocar a alguien: mensaje, llamada, vídeo o su info.
class GroupInfoScreen extends ConsumerStatefulWidget {
  final String chatId;
  const GroupInfoScreen({super.key, required this.chatId});

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  String _q = '';
  bool _searching = false;

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  /// Nombre que yo le tengo guardado (si ya hablamos), si no el del grupo.
  String _nameOf(GroupMember m, Chat? direct) {
    if (direct != null && direct.title.isNotEmpty) return direct.title;
    if (m.name.isNotEmpty) return m.name;
    if (m.phone.isEmpty) return tr('Miembro de la comunidad');
    return prettyPhone(m.phone);
  }

  Future<void> _open(GroupMember m, String? action) async {
    final app = ref.read(appProvider);
    try {
      final id = app.chatById(m.id) != null
          ? m.id
          : await app.startChatWithPhone(m.phone, _nameOf(m, null),
              knownAccountId: m.id.startsWith('demo') ? null : m.id);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: id, startAction: action)));
    } on ApiException catch (e) {
      _snack(e.message);
    } catch (_) {
      _snack(tr('No se pudo abrir el chat'));
    }
  }

  Future<void> _memberSheet(GroupMember m, Chat? direct) async {
    final name = _nameOf(m, direct);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ChatAvatar(id: m.id, title: name, photoPath: direct?.avatarPath, radius: 34),
          const SizedBox(height: 8),
          Text(name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          if (m.phone.isNotEmpty && name != prettyPhone(m.phone))
            Text(prettyPhone(m.phone), style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline_rounded),
            title: Text('${tr('Enviar mensaje a')} $name'),
            onTap: () => Navigator.pop(ctx, 'chat'),
          ),
          ListTile(
            leading: const Icon(Icons.call_outlined),
            title: Text('${tr('Llamar a')} $name'),
            onTap: () => Navigator.pop(ctx, 'call'),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: Text('${tr('Videollamada a')} $name'),
            onTap: () => Navigator.pop(ctx, 'video'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: Text('${tr('Ver info de')} $name'),
            onTap: () => Navigator.pop(ctx, 'info'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    await _open(m, action == 'chat' ? null : action);
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final chat = app.chatById(widget.chatId);
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.62);
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text(tr('Este grupo ya no existe'))));
    }
    final now = DateTime.now();
    final community = isCommunityChat(chat.id);
    final media = app
        .messagesFor(chat.id)
        .where((m) =>
            !m.deleted &&
            (m.media?.type == MediaType.image || m.media?.type == MediaType.video) &&
            !(m.media?.viewOnce ?? false) &&
            m.media?.localPath != null &&
            File(m.media!.localPath!).existsSync())
        .toList()
        .reversed
        .toList();
    final q = _q.trim().toLowerCase();
    final members = [...chat.members]..sort((a, b) {
        // Primero los que tengo guardados, luego por nombre.
        final da = app.chatById(a.id), db = app.chatById(b.id);
        if ((da == null) != (db == null)) return da == null ? 1 : -1;
        return _nameOf(a, da).toLowerCase().compareTo(_nameOf(b, db).toLowerCase());
      });
    final shown = members.where((m) {
      if (q.isEmpty) return true;
      final d = app.chatById(m.id);
      return _nameOf(m, d).toLowerCase().contains(q) || m.phone.contains(q.replaceAll(' ', ''));
    }).toList();

    return Scaffold(
      appBar: AppBar(title: Text(tr('Info. del grupo'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        const SizedBox(height: 8),
        Center(child: TappableAvatar(id: chat.id, title: chat.title, photoPath: chat.avatarPath, radius: 60)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(chat.title,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 4),
        Text('${community ? tr('Comunidad') : tr('Grupo')} · ${chat.members.length + 1} ${community ? tr('miembros') : tr('participantes')}',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: muted)),
        if (community)
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
            child: Text(tr('Lo que escribas aquí lo ven todos los miembros. Los números de teléfono no se muestran.'),
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: muted)),
          ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(tr('Fotos, vídeos y archivos'), style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${media.length}', style: TextStyle(color: muted)),
                  Icon(Icons.chevron_right_rounded, color: muted),
                ]),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => SharedMediaScreen(chatId: chat.id))),
              ),
              if (media.isNotEmpty)
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    scrollDirection: Axis.horizontal,
                    itemCount: media.length > 15 ? 15 : media.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => MediaThumb(message: media[i], size: 84),
                  ),
                ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                child: Row(children: [
                  Expanded(
                    child: Text('${chat.members.length + 1} ${community ? tr('miembros') : tr('participantes')}',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: muted)),
                  ),
                  IconButton(
                    tooltip: tr('Buscar'),
                    icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded, color: muted),
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      _q = '';
                    }),
                  ),
                ]),
              ),
              if (_searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: tr('Buscar participante'),
                      prefixIcon: const Icon(Icons.search_rounded),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
              if (q.isEmpty)
                ListTile(
                  leading: CircleAvatar(backgroundColor: cs.primary, foregroundColor: cs.onPrimary, child: Text(tr('TÚ'))),
                  title: Text(tr('Tú'), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              for (final m in shown) _memberTile(m, app, now, cs, muted),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(tr('Nadie con ese nombre'), style: TextStyle(color: muted)),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _memberTile(GroupMember m, AppController app, DateTime now, ColorScheme cs, Color muted) {
    final direct = app.chatById(m.id);
    final name = _nameOf(m, direct);
    final seen = presenceLabel(app.presence[m.id], now);
    final online = seen == tr('en línea');
    // Si no lo tengo guardado, enseño su número (como WhatsApp).
    final about = app.aboutOf(m.id)?.text;
    final sub = about ?? seen ?? (direct == null && name != prettyPhone(m.phone) ? prettyPhone(m.phone) : null);
    return ListTile(
      leading: Stack(clipBehavior: Clip.none, children: [
        ChatAvatar(id: m.id, title: name, photoPath: direct?.avatarPath, radius: 21),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: const Color(0xFF25C26E),
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
              ),
            ),
          ),
      ]),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: sub == null || sub.isEmpty
          ? null
          : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: online && about == null ? cs.secondary : muted)),
      trailing: direct == null && !isCommunityChat(widget.chatId) ? Text(tr('~ no guardado'), style: TextStyle(fontSize: 11.5, color: muted)) : null,
      onTap: () => _memberSheet(m, direct),
    );
  }
}
