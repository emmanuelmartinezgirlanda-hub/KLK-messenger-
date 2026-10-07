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
  final String? avatarPath; // foto de perfil del contacto (ya descifrada)

  const Chat({
    required this.id,
    required this.title,
    this.phone = '',
    this.identityKey,
    this.isGroup = false,
    this.unread = 0,
    this.lastText = '',
    required this.updatedAt,
    this.avatarPath,
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
        avatarPath: avatarPath,
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
        'avatar_path': avatarPath,
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
        avatarPath: r['avatar_path'] as String?,
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
  final MessageMedia? media;

  const Message({
    required this.id,
    required this.chatId,
    required this.kind,
    this.sender = '',
    required this.body,
    required this.status,
    required this.createdAt,
    this.scheduledFor,
    this.media,
  });

  bool get isMine => kind == MessageKind.outgoing;

  /// Texto corto para la lista de chats.
  String get summary {
    final m = media;
    if (m == null) return body;
    final label = m.label;
    return body.isEmpty ? label : '$label · $body';
  }

  String get preview => switch (kind) {
        MessageKind.outgoing => 'Tú: $summary',
        MessageKind.incoming => sender.isEmpty ? summary : '$sender: $summary',
        MessageKind.system => body,
      };

  Message withStatus(MessageStatus s) => Message(
      id: id, chatId: chatId, kind: kind, sender: sender, body: body,
      status: s, createdAt: createdAt, scheduledFor: scheduledFor, media: media);

  Map<String, Object?> toRow() => {
        'id': id,
        'chat_id': chatId,
        'kind': kind.index,
        'sender': sender,
        'body': body,
        'status': status.name,
        'created_at': createdAt.millisecondsSinceEpoch,
        'scheduled_for': scheduledFor?.millisecondsSinceEpoch,
        'media_json': media == null ? null : jsonEncode(media!.toJson()),
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
        media: r['media_json'] == null
            ? null
            : MessageMedia.fromJson(jsonDecode(r['media_json'] as String) as Map<String, dynamic>),
      );
}

enum MediaType { image, video, audio, file, location }

/// Adjunto de un mensaje: foto, vídeo, nota de voz, documento o ubicación.
class MessageMedia {
  final MediaType type;

  /// Archivo ya descifrado en este móvil (null mientras se descarga).
  final String? localPath;
  final String? mime;
  final String? name;
  final int? size; // bytes
  final int? durationMs; // audio y vídeo
  final double? lat, lng; // ubicación

  // Para descargar y descifrar (los pone el remitente; base64)
  final String? attachmentId, key, nonce, mac;

  const MessageMedia({
    required this.type,
    this.localPath,
    this.mime,
    this.name,
    this.size,
    this.durationMs,
    this.lat,
    this.lng,
    this.attachmentId,
    this.key,
    this.nonce,
    this.mac,
  });

  bool get needsDownload => type != MediaType.location && localPath == null && attachmentId != null;

  String get label => switch (type) {
        MediaType.image => '📷 Foto',
        MediaType.video => '🎥 Vídeo',
        MediaType.audio => '🎤 Nota de voz ${formatDuration(durationMs ?? 0)}',
        MediaType.file => '📄 ${name ?? 'Documento'}',
        MediaType.location => '📍 Ubicación',
      };

  MessageMedia copyWith({String? localPath, String? attachmentId, String? key, String? nonce, String? mac}) =>
      MessageMedia(
        type: type,
        localPath: localPath ?? this.localPath,
        mime: mime,
        name: name,
        size: size,
        durationMs: durationMs,
        lat: lat,
        lng: lng,
        attachmentId: attachmentId ?? this.attachmentId,
        key: key ?? this.key,
        nonce: nonce ?? this.nonce,
        mac: mac ?? this.mac,
      );

  /// Versión que viaja al destinatario: sin la ruta local de este móvil.
  MessageMedia forWire() => MessageMedia(
        type: type, mime: mime, name: name, size: size, durationMs: durationMs,
        lat: lat, lng: lng, attachmentId: attachmentId, key: key, nonce: nonce, mac: mac,
      );

  Map<String, dynamic> toJson() => {
        't': type.name,
        if (localPath != null) 'path': localPath,
        if (mime != null) 'mime': mime,
        if (name != null) 'name': name,
        if (size != null) 'size': size,
        if (durationMs != null) 'dur': durationMs,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (attachmentId != null) 'att': attachmentId,
        if (key != null) 'key': key,
        if (nonce != null) 'n': nonce,
        if (mac != null) 'mac': mac,
      };

  factory MessageMedia.fromJson(Map<String, dynamic> j) => MessageMedia(
        type: MediaType.values.byName(j['t'] as String),
        localPath: j['path'] as String?,
        mime: j['mime'] as String?,
        name: j['name'] as String?,
        size: (j['size'] as num?)?.toInt(),
        durationMs: (j['dur'] as num?)?.toInt(),
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        attachmentId: j['att'] as String?,
        key: j['key'] as String?,
        nonce: j['n'] as String?,
        mac: j['mac'] as String?,
      );
}

/// 75000 ms -> "1:15"
String formatDuration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// 2500000 -> "2,4 MB"
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} MB';
}

/// Contenido que viaja CIFRADO dentro de cada sobre.
/// El servidor no puede distinguir un texto de un "escribiendo..." o un "leído".
class Payload {
  final String kind; // text | typing | recording | read | delivered | profile | call
  final String? id; // id del mensaje de texto
  final String? text;
  final bool? on; // typing
  final List<String>? ids; // read / delivered
  final String? senderPhone; // para que el destinatario sepa quién es
  final Map<String, dynamic>? media; // adjunto (MessageMedia.forWire().toJson())
  final Map<String, dynamic>? call; // señal de llamada (oferta, respuesta, ICE, colgar…)

  const Payload(
      {required this.kind, this.id, this.text, this.on, this.ids, this.senderPhone, this.media, this.call});

  List<int> encode() => utf8.encode(jsonEncode({
        'k': kind,
        if (id != null) 'id': id,
        if (text != null) 'b': text,
        if (on != null) 'on': on,
        if (ids != null) 'ids': ids,
        if (senderPhone != null) 'p': senderPhone,
        if (media != null) 'm': media,
        if (call != null) 'c': call,
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
      media: (j['m'] as Map?)?.cast<String, dynamic>(),
      call: (j['c'] as Map?)?.cast<String, dynamic>(),
    );
  }
}


/// Mi perfil: nombre y foto que ven mis contactos.
class Profile {
  final String name;
  final String? photoPath;
  const Profile({this.name = '', this.photoPath});

  Profile copyWith({String? name, String? photoPath, bool clearPhoto = false}) =>
      Profile(name: name ?? this.name, photoPath: clearPhoto ? null : (photoPath ?? this.photoPath));

  Map<String, dynamic> toJson() => {'name': name, if (photoPath != null) 'photo': photoPath};
  factory Profile.fromJson(Map<String, dynamic> j) =>
      Profile(name: j['name'] as String? ?? '', photoPath: j['photo'] as String?);
}
