import 'dart:math';

import 'package:uuid/uuid.dart';

import '../../core/database/local_db.dart';
import 'models.dart';

/// Contactos y conversaciones de ejemplo para el modo demo.
Future<void> seedDemo(LocalDb db) async {
  final now = DateTime.now();
  DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));
  const uuid = Uuid();

  Future<void> chat(String id, String title, String phone, bool group,
      List<(bool mine, String sender, String text, int minutesAgo)> msgs,
      {int unread = 0}) async {
    await db.upsertChat(Chat(id: id, title: title, phone: phone, isGroup: group, updatedAt: ago(msgs.last.$4)));
    for (final m in msgs) {
      await db.addMessage(Message(
        id: uuid.v4(),
        chatId: id,
        kind: m.$1 ? MessageKind.outgoing : MessageKind.incoming,
        sender: m.$2,
        body: m.$3,
        status: MessageStatus.read,
        createdAt: ago(m.$4),
      ));
    }
    if (unread > 0) {
      // Los últimos [unread] mensajes recibidos quedan sin leer.
      final list = await db.messages(id);
      final incoming = list.where((m) => !m.isMine).toList().reversed.take(unread);
      for (final m in incoming) {
        await db.setStatus(m.id, MessageStatus.delivered);
      }
      await db.upsertChat((await db.chat(id))!.copyWith(unread: unread));
    }
  }

  await chat('demo-familia', 'La Familia 🇩🇴', '+18095550101', true, [
    (false, 'Tía Mery', 'Buenos días familia 🌞', 95),
    (true, '', '¡Bendición tía!', 90),
    (false, 'Mami', 'Dios te bendiga mi hijo. ¿Y cuándo vienen pa\' Navidad?', 14),
    (false, 'Junior', 'Yo llego el 20 a Las Américas ✈️', 9),
    (false, 'Mami', 'Ya compré lo del moro y el puerco 🐷', 4),
  ], unread: 3);
  await chat('demo-yaniris', 'Yaniris', '+12125550102', false, [
    (true, '', 'Klk, ¿llegaste bien a NY?', 240),
    (false, '', 'Sí manito, llegué ayer. Hace un frío que no te digo 🥶', 230),
    (true, '', 'Jajaja abrígate. ¿Cuándo nos vemos?', 225),
    (false, '', 'Este finde en el Alto Manhattan, ¿tú vienes?', 30),
  ], unread: 1);
  await chat('demo-madrid', 'Dominicanos en Madrid', '+34600000103', true, [
    (false, 'Pedro', 'Gente, el sábado hay bandera y sancocho en Tetuán 🍲', 70),
    (false, 'Lisbeth', '¡Yo voy! Llevo los tostones', 66),
    (true, '', 'Cuenten conmigo 🙌', 60),
  ]);
  await chat('demo-ramon', 'Ramón (el primo)', '+18295550104', false, [
    (false, '', 'Mándame la foto del carro, que la quiero ver', 60 * 50),
    (true, '', 'Ahorita te la mando sin comprimir 📷', 60 * 49),
  ]);
  // Una ubicación de ejemplo: el aeropuerto de Las Américas
  await db.addMessage(Message(
    id: uuid.v4(),
    chatId: 'demo-ramon',
    kind: MessageKind.incoming,
    body: 'Te espero aquí en Las Américas 🛬',
    status: MessageStatus.read,
    createdAt: ago(60 * 48),
    media: const MessageMedia(type: MediaType.location, lat: 18.42966, lng: -69.66892),
  ));

  // Estados de ejemplo (duran 24 h)
  await db.addStatus(StatusPost(
    id: uuid.v4(),
    ownerId: 'demo-yaniris',
    ownerName: 'Yaniris',
    text: 'Llegué a Nueva York 🗽❄️ ¡qué frío, mi gente!',
    color: 0xFF00A6B4,
    createdAt: ago(35),
  ));
  await db.addStatus(StatusPost(
    id: uuid.v4(),
    ownerId: 'demo-ramon',
    ownerName: 'Ramón (el primo)',
    text: 'Domingo de sancocho en casa de la abuela 🍲🇩🇴',
    color: 0xFFCE1126,
    createdAt: ago(130),
  ));
}

const _replies = [
  'Tá to\' 👌',
  'Jajaja diablo, ¿en serio?',
  'Dímelo cantando 😂',
  'Ahí nos vemos entonces',
  'Eso es así mismo',
  'Ok, déjame ver y te digo',
  '¡Qué chévere! 🙌',
  'Dale, tranquilo',
];

String demoReply() => _replies[Random().nextInt(_replies.length)];
