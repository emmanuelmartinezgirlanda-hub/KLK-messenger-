import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/util/phone.dart';
import '../../messaging/models.dart';
import '../../messaging/custom_stickers.dart';
import '../../messaging/stickers.dart';
import 'chat_avatar.dart';

/// Hojas inferiores del chat: stickers, viaje, reenviar, temporales,
/// información del grupo y servicios de dinero.

/// Elige un sticker (mis stickers, o por packs: criollos, pelota, Navidad…).
/// Devuelve el id del sticker del pack, o 'file:<ruta>' si es uno propio.
Future<String?> pickSticker(BuildContext context, {int initialPack = 0}) => showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: DefaultTabController(
            length: stickerPacks.length + 1,
            // La pestaña 0 es "Míos"; los packs van después
            initialIndex: (initialPack + 1).clamp(0, stickerPacks.length).toInt(),
            child: Column(children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  const Tab(text: '⭐ Míos'),
                  for (final p in stickerPacks) Tab(text: '${p.icon} ${p.name}'),
                ],
              ),
              Expanded(
                child: TabBarView(children: [
                  const _MyStickers(),
                  for (final pack in stickerPacks)
                    GridView.count(
                      crossAxisCount: 3,
                      padding: const EdgeInsets.all(12),
                      children: [
                        for (final st in pack.stickers)
                          InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => Navigator.pop(ctx, st.id),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Image.asset(st.asset, semanticLabel: st.label),
                            ),
                          ),
                      ],
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );

/// Pestaña "Míos": crear un sticker desde una foto, usarlo o borrarlo.
class _MyStickers extends StatefulWidget {
  const _MyStickers();

  @override
  State<_MyStickers> createState() => _MyStickersState();
}

class _MyStickersState extends State<_MyStickers> {
  List<String> _paths = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await CustomStickers.list();
    if (mounted) setState(() => _paths = list);
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final path = await CustomStickers.createFromGallery();
      if (path != null) await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo crear el sticker. Revisa el permiso de Fotos en Ajustes → KLK.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar este sticker?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    await CustomStickers.delete(path);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GridView.count(
      crossAxisCount: 3,
      padding: const EdgeInsets.all(12),
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _busy ? null : _create,
          child: Container(
            margin: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cs.outlineVariant, width: 1.5),
            ),
            child: Center(
              child: _busy
                  ? const CircularProgressIndicator()
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add_photo_alternate_outlined, size: 34, color: cs.secondary),
                      const SizedBox(height: 6),
                      const Text('Crear sticker', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5)),
                    ]),
            ),
          ),
        ),
        for (final path in _paths)
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => Navigator.pop(context, 'file:$path'),
            onLongPress: () => _delete(path),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Image.file(File(path), fit: BoxFit.contain, semanticLabel: 'Mi sticker'),
            ),
          ),
      ],
    );
  }
}

/// Índice del pack de cumpleaños (para felicitar).
int get birthdayPackIndex => stickerPacks.indexWhere((p) => p.name == 'Cumpleaños');

/// Crear una encuesta. Devuelve (pregunta, opciones, varias respuestas).
Future<(String, List<String>, bool)?> pickPoll(BuildContext context) {
  final question = TextEditingController();
  final options = [TextEditingController(), TextEditingController()];
  var multi = false;
  return showModalBottomSheet<(String, List<String>, bool)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final filled = options.where((o) => o.text.trim().isNotEmpty).length;
        final ok = question.text.trim().isNotEmpty && filled >= 2;
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(ctx).bottom + 20),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('📊 Nueva encuesta', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              TextField(
                controller: question,
                autofocus: true,
                maxLength: 140,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                    labelText: 'Pregunta', hintText: '¿Quién va al sancocho del sábado?', border: OutlineInputBorder()),
              ),
              for (var i = 0; i < options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: options[i],
                    maxLength: 60,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Opción ${i + 1}',
                      border: const OutlineInputBorder(),
                      counterText: '',
                      suffixIcon: options.length > 2
                          ? IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() => options.removeAt(i)),
                            )
                          : null,
                    ),
                  ),
                ),
              if (options.length < 8)
                TextButton.icon(
                  onPressed: () => setState(() => options.add(TextEditingController())),
                  icon: const Icon(Icons.add),
                  label: const Text('Añadir opción'),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Permitir varias respuestas'),
                value: multi,
                onChanged: (v) => setState(() => multi = v),
              ),
              FilledButton(
                onPressed: ok
                    ? () => Navigator.pop(ctx, (question.text.trim(), [for (final o in options) o.text.trim()], multi))
                    : null,
                child: const Text('Enviar encuesta'),
              ),
            ]),
          ),
        );
      },
    ),
  );
}

/// Cuánto tiempo compartir la ubicación en tiempo real.
Future<Duration?> pickLiveDuration(BuildContext context) => showModalBottomSheet<Duration>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
            title: Text('Ubicación en tiempo real', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            subtitle: Text('Tu gente verá dónde estás mientras KLK esté abierta. '
                'Puedes dejar de compartir cuando quieras. Va cifrada de punta a punta.'),
          ),
          for (final (label, d) in const [
            ('15 minutos', Duration(minutes: 15)),
            ('1 hora', Duration(hours: 1)),
            ('8 horas', Duration(hours: 8)),
          ])
            ListTile(leading: const Icon(Icons.share_location), title: Text(label), onTap: () => Navigator.pop(ctx, d)),
        ]),
      ),
    );

/// Denunciar a un contacto. Devuelve (motivo, incluir mensajes, bloquear).
Future<(String, bool, bool)?> pickReport(BuildContext context, String name) {
  var reason = 'spam';
  var include = true;
  var block = true;
  return showModalBottomSheet<(String, bool, bool)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ListTile(
              title: Text('Denunciar a $name', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              subtitle: const Text('KLK no puede leer tus chats. Solo recibimos lo que tú decidas enviar aquí.'),
            ),
            for (final (id, label) in const [
              ('spam', 'Spam o publicidad'),
              ('estafa', 'Estafa o fraude'),
              ('acoso', 'Acoso o amenazas'),
              ('otro', 'Otro motivo'),
            ])
              ListTile(
                leading: Icon(reason == id ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(label),
                onTap: () => setState(() => reason = id),
              ),
            CheckboxListTile(
              value: include,
              onChanged: (v) => setState(() => include = v ?? false),
              title: const Text('Adjuntar los últimos 5 mensajes que te envió'),
              subtitle: const Text('Ayuda a revisar la denuncia. Nada más sale de tu móvil.'),
            ),
            CheckboxListTile(
              value: block,
              onChanged: (v) => setState(() => block = v ?? false),
              title: const Text('Bloquear también'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
                onPressed: () => Navigator.pop(ctx, (reason, include, block)),
                child: const Text('Enviar denuncia'),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

/// Formulario "Bajando pa' RD". Devuelve el adjunto de viaje.
Future<MessageMedia?> pickTrip(BuildContext context) async {
  final from = TextEditingController();
  final to = TextEditingController(text: 'Santo Domingo');
  DateTime? date;
  return showModalBottomSheet<MessageMedia>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(ctx).bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text("✈️ Bajando pa' RD", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Avisa a tu gente de tu viaje, por si necesitan que lleves o traigas algo.'),
          const SizedBox(height: 16),
          TextField(
            controller: from,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Salgo desde', hintText: 'Madrid, Nueva York, Dublín…',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: to,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Voy a', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.event),
            label: Text(date == null ? 'Elegir fecha de llegada' : DateFormat.yMMMMd('es').format(date!)),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                  context: ctx, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
              if (d != null) setState(() => date = d);
            },
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: date == null
                ? null
                : () => Navigator.pop(
                      ctx,
                      MessageMedia(
                        type: MediaType.trip,
                        tripDate: date,
                        tripFrom: from.text.trim(),
                        tripTo: to.text.trim().isEmpty ? 'RD' : to.text.trim(),
                      ),
                    ),
            child: const Text('Avisar en el chat'),
          ),
        ]),
      ),
    ),
  );
}

/// Elige a qué chats reenviar. Devuelve sus ids.
Future<List<String>?> pickForwardTargets(BuildContext context, List<Chat> chats) {
  final selected = <String>{};
  return showModalBottomSheet<List<String>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.7,
          child: Column(children: [
            const Text('Reenviar a…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            Expanded(
              child: ListView(children: [
                for (final c in chats)
                  CheckboxListTile(
                    value: selected.contains(c.id),
                    onChanged: (v) => setState(() => v == true ? selected.add(c.id) : selected.remove(c.id)),
                    secondary: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath, radius: 20),
                    title: Text(c.title),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, selected.toList()),
                icon: const Icon(Icons.send),
                label: Text(selected.isEmpty ? 'Elige al menos un chat' : 'Reenviar a ${selected.length}'),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

/// Duración de los mensajes temporales. Devuelve segundos (0 = desactivar) o null si se cancela.
Future<int?> pickDisappearing(BuildContext context, int? current) => showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
            title: Text('Mensajes temporales', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            subtitle: Text('Los mensajes nuevos de este chat se borrarán solos para todos pasado este tiempo.'),
          ),
          for (final (label, sec) in const [
            ('Desactivados', 0),
            ('24 horas', 86400),
            ('7 días', 604800),
            ('90 días', 7776000),
          ])
            ListTile(
              leading: Icon((current ?? 0) == sec ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(label),
              onTap: () => Navigator.pop(ctx, sec),
            ),
        ]),
      ),
    );

/// Información del grupo: miembros.
Future<void> showGroupInfo(BuildContext context, Chat chat) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: Column(children: [
            ChatAvatar(id: chat.id, title: chat.title, radius: 36),
            const SizedBox(height: 8),
            Text(chat.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text('${chat.members.length + 1} participantes'),
            const Divider(height: 24),
            Expanded(
              child: ListView(children: [
                const ListTile(leading: CircleAvatar(child: Text('TÚ')), title: Text('Tú')),
                for (final m in chat.members)
                  ListTile(
                    leading: ChatAvatar(id: m.id, title: m.name.isEmpty ? m.phone : m.name, radius: 20),
                    title: Text(m.name.isEmpty ? prettyPhone(m.phone) : m.name),
                    subtitle: m.phone.isEmpty ? null : Text(prettyPhone(m.phone)),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );

/// Remesas y recargas: se integrarán con proveedores autorizados.
Future<void> showMoneyInfo(BuildContext context, {required bool recharge}) => showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(recharge ? Icons.phone_iphone : Icons.payments_outlined, size: 48, color: const Color(0xFF1F7A4D)),
            const SizedBox(height: 12),
            Text(recharge ? 'Recargas a RD' : 'Enviar dinero a RD',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              recharge
                  ? 'Pronto podrás recargar el móvil de tu gente en RD (Claro, Altice, Viva) desde su chat.'
                  : 'Pronto podrás enviar remesas a tu familia desde el chat, con empresas de envío autorizadas.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Estamos trabajando con proveedores regulados para que tu dinero viaje seguro. '
              'Aún no se puede enviar dinero desde KLK.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Entendido')),
          ]),
        ),
      ),
    );
