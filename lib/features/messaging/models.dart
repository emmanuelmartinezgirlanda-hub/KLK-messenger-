import 'dart:convert';

enum MessageKind { outgoing, incoming, system }

/// El orden importa: un estado solo puede avanzar hacia la derecha.
enum MessageStatus { failed, scheduled, sending, sent, delivered, read }

class Chat {
  final String id; // accountId del contacto (o id local en demo)
  final String title;
  final String phone;
  final String? identityKey; // base64, clave pública del contacto (TOFU)
  final bool isGroup;
  final int unread;
  final String lastText;
  final DateTime updatedAt;

  const Chat({
    required this.id,
    required this.title,
    this.phone = '',
    this.identityKey,
    this.isGroup = false,
    this.unread = 0,
    this.lastText = '',
    required this.updatedAt,
  });

  Chat copyWith({String? title, String? identityKey, int? unread, String? lastText, DateTime? updatedAt}) => Chat(
        id: id,
        title: title ?? this.title,
        phone: phone,
        identityKey: identityKey ?? this.identityKey,
        isGroup: isGroup,
        unread: unread ?? this.unread,
        lastText: lastText ?? this.lastText,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'phone': phone,
        'identity_key': identityKey,
        'is_group': isGroup ? 1 : 0,
        'unread': unread,
        'last_text': lastText,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  factory Chat.fromRow(Map<String, Object?> r) => Chat(
        id: r['id'] as String,
        title: r['title'] as String,
        phone: r['phone'] as String? ?? '',
        identityKey: r['identity_key'] as String?,
        isGroup: (r['is_group'] as int? ?? 0) == 1,
        unread: r['unread'] as int? ?? 0,
        lastText: r['last_text'] as String? ?? '',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );
}

class Message {
  final String id;
  final String chatId;
  final MessageKind kind;
  final String sender; // nombre a mostrar en grupos
  final String body;
  final MessageStatus status;
  final DateTime createdAt;
  final DateTime? scheduledFor;

  const Message({
    required this.id,
    required this.chatId,
    required this.kind,
    this.sender = '',
    required this.body,
    required this.status,
    required this.createdAt,
    this.scheduledFor,
  });

  bool get isMine => kind == MessageKind.outgoing;

  String get preview => switch (kind) {
        MessageKind.outgoing => 'Tú: $body',
        MessageKind.incoming => sender.isEmpty ? body : '$sender: $body',
        MessageKind.system => body,
      };

  Message withStatus(MessageStatus s) => Message(
      id: id, chatId: chatId, kind: kind, sender: sender, body: body,
      status: s, createdAt: createdAt, scheduledFor: scheduledFor);

  Map<String, Object?> toRow() => {
        'id': id,
        'chat_id': chatId,
        'kind': kind.index,
        'sender': sender,
        'body': body,
        'status': status.name,
        'created_at': createdAt.millisecondsSinceEpoch,
        'scheduled_for': scheduledFor?.millisecondsSinceEpoch,
      };

  factory Message.fromRow(Map<String, Object?> r) => Message(
        id: r['id'] as String,
        chatId: r['chat_id'] as String,
        kind: MessageKind.values[r['kind'] as int],
        sender: r['sender'] as String? ?? '',
        body: r['body'] as String,
        status: MessageStatus.values.byName(r['status'] as String),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        scheduledFor: r['scheduled_for'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['scheduled_for'] as int),
      );
}

/// Contenido que viaja CIFRADO dentro de cada sobre.
/// El servidor no puede distinguir un texto de un "escribiendo..." o un "leído".
class Payload {
  final String kind; // text | typing | read | delivered
  final String? id; // id del mensaje de texto
  final String? text;
  final bool? on; // typing
  final List<String>? ids; // read / delivered
  final String? senderPhone; // para que el destinatario sepa quién es

  const Payload({required this.kind, this.id, this.text, this.on, this.ids, this.senderPhone});

  List<int> encode() => utf8.encode(jsonEncode({
        'k': kind,
        if (id != null) 'id': id,
        if (text != null) 'b': text,
        if (on != null) 'on': on,
        if (ids != null) 'ids': ids,
        if (senderPhone != null) 'p': senderPhone,
      }));

  factory Payload.decode(List<int> bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return Payload(
      kind: j['k'] as String,
      id: j['id'] as String?,
      text: j['b'] as String?,
      on: j['on'] as bool?,
      ids: (j['ids'] as List?)?.cast<String>(),
      senderPhone: j['p'] as String?,
    );
  }
}
