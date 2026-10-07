import 'package:flutter_test/flutter_test.dart';
import 'package:klk/core/crypto/crypto_engine.dart';
import 'package:klk/core/util/phone.dart';
import 'package:klk/features/messaging/models.dart';
import 'package:klk/features/privacy/domain/privacy_settings.dart';
import 'package:klk/features/theming/domain/klk_theme.dart';

void main() {
  test('KlkTheme se serializa y deserializa sin pérdidas', () {
    const t = KlkTheme.nocheCaribe;
    expect(KlkTheme.decode(t.encode()).toJson(), t.toJson());
  });

  test('Reciprocidad: ocultar mis lecturas oculta las de los demás', () {
    expect(const PrivacySettings(hideReadReceipts: true).canSeeOthersReadReceipts, isFalse);
  });

  test('PrivacySettings ida y vuelta por JSON', () {
    const s = PrivacySettings(lastSeen: Audience.nadie, hideTyping: true);
    expect(PrivacySettings.decode(s.encode()).toJson(), s.toJson());
  });

  test('Números E.164', () {
    expect(toE164(countries.first, '809-555-1234'), '+18095551234');
    expect(isValidE164('+18095551234'), isTrue);
    expect(isValidE164('8095551234'), isFalse);
    expect(prettyPhone('+18095551234'), '+1 809 555 1234');
    expect(zoneForPhone('+18295551234')?.zone, 'America/Santo_Domingo');
    expect(zoneForPhone('+34612345678')?.place, 'España');
  });

  test('Payload ida y vuelta', () {
    const p = Payload(kind: 'text', id: 'abc', text: '¡Klk! 🇩🇴', senderPhone: '+18095551234');
    final back = Payload.decode(p.encode());
    expect(back.kind, 'text');
    expect(back.text, '¡Klk! 🇩🇴');
    expect(back.senderPhone, '+18095551234');
  });

  test('Cifrado: Ana cifra para Beto, Beto descifra y sabe que fue Ana', () async {
    final ana = await ProvisionalCrypto.fromSeed(List.generate(32, (i) => i));
    final beto = await ProvisionalCrypto.fromSeed(List.generate(32, (i) => 100 + i));
    final carla = await ProvisionalCrypto.fromSeed(List.generate(32, (i) => 200 - i));

    expect(ana.identityPublic.length, 33);
    expect(ana.identityPublic.first, 0x05);

    final msg = const Payload(kind: 'text', id: '1', text: 'Nos vemos en el Malecón').encode();
    final sealed = await ana.encrypt(msg, beto.identityPublic);

    final opened = await beto.decrypt(sealed);
    expect(Payload.decode(opened.plaintext).text, 'Nos vemos en el Malecón');
    expect(opened.senderIdentity, ana.identityPublic);

    // Carla no puede abrirlo.
    await expectLater(carla.decrypt(sealed), throwsA(anything));
  });

  test('Adjuntos: ida y vuelta por JSON y sin ruta local al enviar', () {
    const m = MessageMedia(
      type: MediaType.audio,
      localPath: '/privado/nota.m4a',
      mime: 'audio/mp4',
      durationMs: 75000,
      attachmentId: 'abc',
      key: 'k',
      nonce: 'n',
      mac: 'm',
    );
    final wire = m.forWire().toJson();
    expect(wire.containsKey('path'), isFalse);
    final back = MessageMedia.fromJson(wire);
    expect(back.type, MediaType.audio);
    expect(back.needsDownload, isTrue);
    expect(back.label, '🎤 Nota de voz 1:15');
    expect(formatBytes(2500000), '2,4 MB');
  });

  test('Ubicación en un mensaje', () {
    const loc = MessageMedia(type: MediaType.location, lat: 18.4297, lng: -69.6689);
    final msg = Message(
      id: '1', chatId: 'c', kind: MessageKind.incoming, body: '',
      status: MessageStatus.read, createdAt: DateTime(2026), media: loc,
    );
    final back = Message.fromRow(msg.toRow());
    expect(back.media!.lat, 18.4297);
    expect(back.preview, '📍 Ubicación');
    expect(loc.needsDownload, isFalse);
  });

  test('Perfil y foto del contacto se guardan', () {
    const me = Profile(name: 'Emmanuel', photoPath: '/fotos/yo.jpg');
    final back = Profile.fromJson(me.toJson());
    expect(back.name, 'Emmanuel');
    expect(back.copyWith(clearPhoto: true).photoPath, isNull);

    final chat = Chat(id: 'c', title: 'Yaniris', updatedAt: DateTime(2026), avatarPath: '/fotos/y.jpg');
    expect(Chat.fromRow(chat.toRow()).avatarPath, '/fotos/y.jpg');
    expect(chat.copyWith(unread: 2).avatarPath, '/fotos/y.jpg');
  });

  test('Números de la agenda a E.164', () {
    expect(normalizePhone('(809) 555-1234', '+34'), '+18095551234'); // dominicano en agenda española
    expect(normalizePhone('612 34 56 78', '+34'), '+34612345678');
    expect(normalizePhone('0034 612 34 56 78', '+1'), '+34612345678');
    expect(normalizePhone('+1 (212) 555-1234', '+34'), '+12125551234');
    expect(normalizePhone('212-555-1234', '+1'), '+12125551234');
    expect(normalizePhone('123', '+1'), isNull);
    expect(dialCodeOf('+353851234567'), '+353');
    expect(dialCodeOf('+18095551234'), '+1');
  });

  test('Mensaje con respuesta, reacciones, borrado y caducidad se guarda entero', () {
    final m = Message(
      id: 'm1', chatId: 'g-1', kind: MessageKind.incoming, sender: 'Pedro', body: 'Klk',
      status: MessageStatus.delivered, createdAt: DateTime(2026, 10, 7, 12),
      replyToId: 'm0', replyPreview: 'Tú: ¿Vienes el sábado?',
      reactions: const {'me': '👍', 'abc': '🇩🇴'},
      expiresAt: DateTime(2026, 10, 8, 12),
    );
    final back = Message.fromRow(m.toRow());
    expect(back.replyPreview, 'Tú: ¿Vienes el sábado?');
    expect(back.reactions['abc'], '🇩🇴');
    expect(back.expiresAt, DateTime(2026, 10, 8, 12));
    final borrado = back.copyWith(deleted: true);
    expect(borrado.summary, '🚫 Mensaje eliminado');
  });

  test('Grupo: miembros por JSON y señales nuevas en el payload', () {
    final chat = Chat(
      id: 'g-1', title: 'La Familia', isGroup: true, updatedAt: DateTime(2026),
      members: const [GroupMember(id: 'a', phone: '+18095550101', name: 'Mami', identityKey: 'k')],
      disappearSec: 86400,
    );
    final back = Chat.fromRow(chat.toRow());
    expect(back.members.single.name, 'Mami');
    expect(back.members.single.identityKey, 'k');
    expect(back.disappearSec, 86400);
    expect(disappearLabel(back.disappearSec), '24 horas');
    expect(disappearLabel(null), 'Desactivados');

    const p = Payload(kind: 'reaction', target: 'm1', emoji: '❤️', group: {'id': 'g-1', 'n': 'La Familia'});
    final d = Payload.decode(p.encode());
    expect(d.target, 'm1');
    expect(d.emoji, '❤️');
    expect(d.group?['n'], 'La Familia');
  });

  test('Sticker, viaje y ver una vez', () {
    const sticker = MessageMedia(type: MediaType.sticker, name: 'klk');
    expect(sticker.needsDownload, isFalse);
    expect(sticker.label, '🎨 Sticker');

    final trip = MessageMedia(type: MediaType.trip, tripDate: DateTime(2026, 12, 20), tripFrom: 'Madrid', tripTo: 'Santiago');
    final t = MessageMedia.fromJson(trip.forWire().toJson());
    expect(t.tripFrom, 'Madrid');
    expect(t.tripDate, DateTime(2026, 12, 20));
    expect(t.label, '✈️ Viaje a Santiago');

    const once = MessageMedia(type: MediaType.image, viewOnce: true, attachmentId: 'a', key: 'k', nonce: 'n', mac: 'm');
    expect(once.needsDownload, isTrue);
    expect(once.copyWith(opened: true, clearPath: true).needsDownload, isFalse);
    expect(once.label, '📷 Foto · ver una vez');
  });

  test('Estado de 24 horas', () {
    final s = StatusPost(id: 's', ownerId: 'me', ownerName: 'Yo', text: 'Klk', createdAt: DateTime(2026, 10, 7, 9));
    final back = StatusPost.fromRow(s.toRow());
    expect(back.isMine, isTrue);
    expect(back.expiresAt, DateTime(2026, 10, 8, 9));
  });
}
