import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/util/phone.dart';
import '../../messaging/models.dart';
import '../../messaging/stickers.dart';
import 'chat_avatar.dart';

/// Hojas inferiores del chat: stickers, viaje, reenviar, temporales,
/// información del grupo y servicios de dinero.

/// Elige un sticker criollo. Devuelve su id.
Future<String?> pickSticker(BuildContext context) => showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.55,
          child: Column(children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Stickers criollos 🇩🇴', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final s in klkStickers)
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Navigator.pop(ctx, s.id),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Image.asset(s.asset, semanticLabel: s.label),
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );

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
