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
}
