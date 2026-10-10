import 'dart:convert';

/// Las rutas guardadas son absolutas, pero en iOS la carpeta de la app puede
/// cambiar (actualizaciones, restaurar una copia en otro iPhone). MediaStore
/// instala aquí un traductor que las lleva a la carpeta actual.
String? Function(String?) resolveMediaPath = (p) => p;

enum MessageKind { outgoing, incoming, system }

/// El orden importa: un estado solo puede avanzar hacia la derecha.
enum MessageStatus { failed, scheduled, sending, sent, delivered, read }

/// Miembro de un grupo.
class GroupMember {
  final String id; // accountId (o id de demo)
  final String phone;
  final String name;
  final String? identityKey; // base64; se pide al servidor si falta

  const GroupMember({required this.id, required this.phone, required this.name, this.identityKey});

  GroupMember withIdentity(String key) => GroupMember(id: id, phone: phone, name: name, identityKey: key);

  Map<String, dynamic> toJson({bool withKey = true}) => {
        'id': id,
        'p': phone,
        'n': name,
        if (withKey && identityKey != null) 'k': identityKey,
      };

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        id: j['id'] as String,
        phone: j['p'] as String? ?? '',
        name: j['n'] as String? ?? '',
        identityKey: j['k'] as String?,
      );
}

class Chat {
  final String id; // accountId del contacto, id del grupo o id local en demo
  final String title;
  final String phone;
  final String? identityKey; // base64, clave pública del contacto (TOFU)
  final bool isGroup;
  final int unread;
  final String lastText;
  final DateTime updatedAt;
  final String? avatarPath; // foto de perfil del contacto (ya descifrada)
  final int? disappearSec; // mensajes temporales (null = desactivado)
  final bool hidden; // chat oculto tras el PIN
  final List<GroupMember> members; // solo grupos (sin incluirme a mí)
  final String? birthday; // "MM-DD" que compartió el contacto
  final String? pinnedId; // mensaje fijado arriba del chat
  final bool blocked; // contacto bloqueado: no recibo nada suyo

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
    this.disappearSec,
    this.hidden = false,
    this.members = const [],
    this.birthday,
    this.pinnedId,
    this.blocked = false,
  });

  /// ¿Cumple años hoy?
  bool birthdayOn(DateTime day) =>
      birthday != null &&
      birthday == '${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  Chat copyWith({
    String? title,
    String? identityKey,
    int? unread,
    String? lastText,
    DateTime? updatedAt,
    int? disappearSec,
    bool clearDisappear = false,
    bool? hidden,
    List<GroupMember>? members,
    bool? blocked,
  }) =>
      Chat(
        id: id,
        title: title ?? this.title,
        phone: phone,
        identityKey: identityKey ?? this.identityKey,
        isGroup: isGroup,
        unread: unread ?? this.unread,
        lastText: lastText ?? this.lastText,
        updatedAt: updatedAt ?? this.updatedAt,
        avatarPath: avatarPath,
        disappearSec: clearDisappear ? null : (disappearSec ?? this.disappearSec),
        hidden: hidden ?? this.hidden,
        members: members ?? this.members,
        birthday: birthday,
        pinnedId: pinnedId,
        blocked: blocked ?? this.blocked,
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
        'disappear_sec': disappearSec,
        'hidden': hidden ? 1 : 0,
        'members_json': members.isEmpty ? null : jsonEncode(members.map((m) => m.toJson()).toList()),
        'birthday': birthday,
        'pinned_id': pinnedId,
        'blocked': blocked ? 1 : 0,
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
        avatarPath: resolveMediaPath(r['avatar_path'] as String?),
        disappearSec: r['disappear_sec'] as int?,
        hidden: (r['hidden'] as int? ?? 0) == 1,
        members: r['members_json'] == null
            ? const []
            : (jsonDecode(r['members_json'] as String) as List)
                .map((e) => GroupMember.fromJson((e as Map).cast<String, dynamic>()))
                .toList(),
        birthday: r['birthday'] as String?,
        pinnedId: r['pinned_id'] as String?,
        blocked: (r['blocked'] as int? ?? 0) == 1,
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
  final String? replyToId; // respuesta a otro mensaje
  final String? replyPreview; // "Mami: Ya compré lo del moro…"
  final Map<String, String> reactions; // quién -> emoji ("me" = yo)
  final bool deleted; // "Este mensaje se eliminó"
  final DateTime? expiresAt; // mensajes temporales

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
    this.replyToId,
    this.replyPreview,
    this.reactions = const {},
    this.deleted = false,
    this.expiresAt,
  });

  bool get isMine => kind == MessageKind.outgoing;

  /// Texto corto para la lista de chats.
  String get summary {
    if (deleted) return '🚫 Mensaje eliminado';
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

  Message copyWith({
    MessageStatus? status,
    MessageMedia? media,
    Map<String, String>? reactions,
    bool? deleted,
    String? body,
  }) =>
      Message(
        id: id,
        chatId: chatId,
        kind: kind,
        sender: sender,
        body: body ?? this.body,
        status: status ?? this.status,
        createdAt: createdAt,
        scheduledFor: scheduledFor,
        media: media ?? this.media,
        replyToId: replyToId,
        replyPreview: replyPreview,
        reactions: reactions ?? this.reactions,
        deleted: deleted ?? this.deleted,
        expiresAt: expiresAt,
      );

  Message withStatus(MessageStatus s) => copyWith(status: s);

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
        'reply_id': replyToId,
        'reply_preview': replyPreview,
        'reactions_json': reactions.isEmpty ? null : jsonEncode(reactions),
        'deleted': deleted ? 1 : 0,
        'expires_at': expiresAt?.millisecondsSinceEpoch,
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
        replyToId: r['reply_id'] as String?,
        replyPreview: r['reply_preview'] as String?,
        reactions: r['reactions_json'] == null
            ? const {}
            : (jsonDecode(r['reactions_json'] as String) as Map).map((k, v) => MapEntry(k as String, v as String)),
        deleted: (r['deleted'] as int? ?? 0) == 1,
        expiresAt: r['expires_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['expires_at'] as int),
      );
}

enum MediaType { image, video, audio, file, location, sticker, trip, poll, live }

/// Adjunto de un mensaje: foto, vídeo, nota de voz, documento, ubicación,
/// sticker, aviso de viaje ("Bajando pa' RD"), encuesta o ubicación en tiempo real.
class MessageMedia {
  final MediaType type;

  /// Archivo ya descifrado en este móvil (null mientras se descarga).
  final String? localPath;
  final String? mime;
  final String? name; // nombre de archivo, o del sticker
  final int? size; // bytes
  final int? durationMs; // audio y vídeo
  final double? lat, lng; // ubicación

  // Para descargar y descifrar (los pone el remitente; base64)
  final String? attachmentId, key, nonce, mac;

  final bool viewOnce; // foto o vídeo de "ver una vez"
  final bool opened; // ya se vio (y se borró)

  // Viaje
  final DateTime? tripDate;
  final String? tripFrom, tripTo;

  // Encuesta
  final String? pollQuestion;
  final List<String> pollOptions;
  final bool pollMulti; // se puede elegir más de una
  final Map<String, List<int>> votes; // quién -> opciones ("me" = yo). Solo local.

  // Ubicación en tiempo real
  final DateTime? liveUntil;
  final bool liveEnded; // se dejó de compartir antes de tiempo
  final DateTime? liveUpdatedAt; // última posición recibida. Solo local.

  // Nota de voz pasada a texto (en el propio móvil). Solo local.
  final String? transcript;

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
    this.viewOnce = false,
    this.opened = false,
    this.tripDate,
    this.tripFrom,
    this.tripTo,
    this.pollQuestion,
    this.pollOptions = const [],
    this.pollMulti = false,
    this.votes = const {},
    this.liveUntil,
    this.liveEnded = false,
    this.liveUpdatedAt,
    this.transcript,
  });

  bool get hasFile => const [MediaType.image, MediaType.video, MediaType.audio, MediaType.file].contains(type);

  /// ¿Sigue compartiéndose la ubicación en tiempo real?
  bool liveActive(DateTime now) => type == MediaType.live && !liveEnded && (liveUntil?.isAfter(now) ?? false);

  /// Votos por opción.
  List<int> get pollCounts {
    final c = List<int>.filled(pollOptions.length, 0);
    for (final v in votes.values) {
      for (final i in v) {
        if (i >= 0 && i < c.length) c[i]++;
      }
    }
    return c;
  }

  bool get needsDownload => hasFile && !opened && localPath == null && attachmentId != null;

  String get label {
    if (viewOnce) return type == MediaType.video ? '🎥 Vídeo · ver una vez' : '📷 Foto · ver una vez';
    return switch (type) {
      MediaType.image => '📷 Foto',
      MediaType.video => '🎥 Vídeo',
      MediaType.audio => '🎤 Nota de voz ${formatDuration(durationMs ?? 0)}',
      MediaType.file => '📄 ${name ?? 'Documento'}',
      MediaType.location => '📍 Ubicación',
      MediaType.sticker => '🎨 Sticker',
      MediaType.trip => '✈️ Viaje a ${tripTo ?? 'RD'}',
      MediaType.poll => '📊 ${pollQuestion ?? 'Encuesta'}',
      MediaType.live => '📍 Ubicación en tiempo real',
    };
  }

  MessageMedia copyWith({
    String? localPath,
    bool clearPath = false,
    String? attachmentId,
    String? key,
    String? nonce,
    String? mac,
    bool? opened,
    double? lat,
    double? lng,
    Map<String, List<int>>? votes,
    bool? liveEnded,
    DateTime? liveUpdatedAt,
    String? transcript,
  }) =>
      MessageMedia(
        type: type,
        localPath: clearPath ? null : (localPath ?? this.localPath),
        mime: mime,
        name: name,
        size: size,
        durationMs: durationMs,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        attachmentId: attachmentId ?? this.attachmentId,
        key: key ?? this.key,
        nonce: nonce ?? this.nonce,
        mac: mac ?? this.mac,
        viewOnce: viewOnce,
        opened: opened ?? this.opened,
        tripDate: tripDate,
        tripFrom: tripFrom,
        tripTo: tripTo,
        pollQuestion: pollQuestion,
        pollOptions: pollOptions,
        pollMulti: pollMulti,
        votes: votes ?? this.votes,
        liveUntil: liveUntil,
        liveEnded: liveEnded ?? this.liveEnded,
        liveUpdatedAt: liveUpdatedAt ?? this.liveUpdatedAt,
        transcript: transcript ?? this.transcript,
      );

  /// Versión que viaja al destinatario: sin la ruta local de este móvil.
  MessageMedia forWire() => MessageMedia(
        type: type,
        mime: mime,
        name: name,
        size: size,
        durationMs: durationMs,
        lat: lat,
        lng: lng,
        attachmentId: attachmentId,
        key: key,
        nonce: nonce,
        mac: mac,
        viewOnce: viewOnce,
        tripDate: tripDate,
        tripFrom: tripFrom,
        tripTo: tripTo,
        pollQuestion: pollQuestion,
        pollOptions: pollOptions,
        pollMulti: pollMulti,
        liveUntil: liveUntil,
        liveEnded: liveEnded,
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
        if (viewOnce) 'once': true,
        if (opened) 'opened': true,
        if (tripDate != null) 'td': tripDate!.toIso8601String(),
        if (tripFrom != null) 'tf': tripFrom,
        if (tripTo != null) 'tt': tripTo,
        if (pollQuestion != null) 'pq': pollQuestion,
        if (pollOptions.isNotEmpty) 'po': pollOptions,
        if (pollMulti) 'pm': true,
        if (votes.isNotEmpty) 'pv': votes,
        if (liveUntil != null) 'lu': liveUntil!.toUtc().toIso8601String(),
        if (liveEnded) 'le': true,
        if (liveUpdatedAt != null) 'lup': liveUpdatedAt!.toUtc().toIso8601String(),
        if (transcript != null) 'tr': transcript,
      };

  factory MessageMedia.fromJson(Map<String, dynamic> j) => MessageMedia(
        type: MediaType.values.byName(j['t'] as String),
        localPath: resolveMediaPath(j['path'] as String?),
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
        viewOnce: j['once'] == true,
        opened: j['opened'] == true,
        tripDate: j['td'] == null ? null : DateTime.tryParse(j['td'] as String),
        tripFrom: j['tf'] as String?,
        tripTo: j['tt'] as String?,
        pollQuestion: j['pq'] as String?,
        pollOptions: (j['po'] as List?)?.map((e) => e.toString()).take(12).toList() ?? const [],
        pollMulti: j['pm'] == true,
        votes: (j['pv'] as Map?)?.map((k, v) => MapEntry(
                  k as String,
                  [for (final i in (v as List)) (i as num).toInt()],
                )) ??
            const {},
        liveUntil: j['lu'] == null ? null : DateTime.tryParse(j['lu'] as String)?.toLocal(),
        liveEnded: j['le'] == true,
        liveUpdatedAt: j['lup'] == null ? null : DateTime.tryParse(j['lup'] as String)?.toLocal(),
        transcript: j['tr'] as String?,
      );
}

/// Estado de 24 horas (texto sobre color o foto).
class StatusPost {
  final String id;
  final String ownerId; // 'me' o accountId del contacto
  final String ownerName;
  final String text;
  final int color; // ARGB del fondo (estados de texto)
  final String? mediaPath; // foto ya descifrada
  final DateTime createdAt;
  final bool allowSave; // el autor permite guardarlo
  final bool viewed;

  const StatusPost({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    this.text = '',
    this.color = 0xFF002D62,
    this.mediaPath,
    required this.createdAt,
    this.allowSave = false,
    this.viewed = false,
  });

  bool get isMine => ownerId == 'me';
  bool get isVideo {
    final m = mediaPath?.toLowerCase() ?? '';
    return m.endsWith('.mp4') || m.endsWith('.mov') || m.endsWith('.m4v');
  }
  DateTime get expiresAt => createdAt.add(const Duration(hours: 24));

  Map<String, Object?> toRow() => {
        'id': id,
        'owner_id': ownerId,
        'owner_name': ownerName,
        'text': text,
        'color': color,
        'media_path': mediaPath,
        'created_at': createdAt.millisecondsSinceEpoch,
        'allow_save': allowSave ? 1 : 0,
        'viewed': viewed ? 1 : 0,
      };

  factory StatusPost.fromRow(Map<String, Object?> r) => StatusPost(
        id: r['id'] as String,
        ownerId: r['owner_id'] as String,
        ownerName: r['owner_name'] as String? ?? '',
        text: r['text'] as String? ?? '',
        color: r['color'] as int? ?? 0xFF002D62,
        mediaPath: resolveMediaPath(r['media_path'] as String?),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        allowSave: (r['allow_save'] as int? ?? 0) == 1,
        viewed: (r['viewed'] as int? ?? 0) == 1,
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

/// Duración legible de los mensajes temporales.
String disappearLabel(int? sec) => switch (sec) {
      null => 'Desactivados',
      86400 => '24 horas',
      604800 => '7 días',
      7776000 => '90 días',
      _ => '${((sec ?? 0) / 3600).round()} horas',
    };

/// Contenido que viaja CIFRADO dentro de cada sobre.
/// El servidor no puede distinguir un texto de un "escribiendo...", un "leído",
/// una reacción o un borrado.
class Payload {
  /// text | typing | recording | read | delivered | profile | call
  /// | reaction | delete | timer | group | status
  /// | vote | pin | loc | shot
  final String kind;
  final String? id; // id del mensaje
  final String? text;
  final bool? on; // typing / recording
  final List<String>? ids; // read / delivered
  final String? senderPhone; // para que el destinatario sepa quién es
  final Map<String, dynamic>? media; // adjunto (MessageMedia.forWire().toJson())
  final Map<String, dynamic>? call; // señal de llamada
  final Map<String, dynamic>? reply; // {id, p: vista previa}
  final int? exp; // segundos de vida (mensajes temporales) / duración del temporizador
  final Map<String, dynamic>? group; // {id, n: nombre, m: [miembros]}
  final String? emoji; // reacción ('' = quitar)
  final String? target; // mensaje al que se reacciona o que se borra
  final Map<String, dynamic>? status; // estado de 24 h
  final List<int>? options; // vote: opciones elegidas
  final Map<String, dynamic>? loc; // loc: {lat, lng} o {end: true}
  final String? birthday; // profile: "MM-DD"

  const Payload({
    required this.kind,
    this.id,
    this.text,
    this.on,
    this.ids,
    this.senderPhone,
    this.media,
    this.call,
    this.reply,
    this.exp,
    this.group,
    this.emoji,
    this.target,
    this.status,
    this.options,
    this.loc,
    this.birthday,
  });

  List<int> encode() => utf8.encode(jsonEncode({
        'k': kind,
        if (id != null) 'id': id,
        if (text != null) 'b': text,
        if (on != null) 'on': on,
        if (ids != null) 'ids': ids,
        if (senderPhone != null) 'p': senderPhone,
        if (media != null) 'm': media,
        if (call != null) 'c': call,
        if (reply != null) 'r': reply,
        if (exp != null) 'x': exp,
        if (group != null) 'g': group,
        if (emoji != null) 'e': emoji,
        if (target != null) 'tg': target,
        if (status != null) 's': status,
        if (options != null) 'o': options,
        if (loc != null) 'l': loc,
        if (birthday != null) 'bd': birthday,
      }));

  factory Payload.decode(List<int> bytes) {
    final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    Map<String, dynamic>? map(String k) => (j[k] as Map?)?.cast<String, dynamic>();
    return Payload(
      kind: j['k'] as String,
      id: j['id'] as String?,
      text: j['b'] as String?,
      on: j['on'] as bool?,
      ids: (j['ids'] as List?)?.cast<String>(),
      senderPhone: j['p'] as String?,
      media: map('m'),
      call: map('c'),
      reply: map('r'),
      exp: (j['x'] as num?)?.toInt(),
      group: map('g'),
      emoji: j['e'] as String?,
      target: j['tg'] as String?,
      status: map('s'),
      options: (j['o'] as List?)?.map((e) => (e as num).toInt()).toList(),
      loc: map('l'),
      birthday: j['bd'] as String?,
    );
  }
}

/// Mi perfil: nombre y foto que ven mis contactos.
class Profile {
  final String name;
  final String? photoPath;
  final String? birthday; // "MM-DD" (sin año: nadie necesita saber tu edad)
  const Profile({this.name = '', this.photoPath, this.birthday});

  Profile copyWith({String? name, String? photoPath, bool clearPhoto = false, String? birthday, bool clearBirthday = false}) =>
      Profile(
        name: name ?? this.name,
        photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
        birthday: clearBirthday ? null : (birthday ?? this.birthday),
      );

  Map<String, dynamic> toJson() =>
      {'name': name, if (photoPath != null) 'photo': photoPath, if (birthday != null) 'bd': birthday};
  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        name: j['name'] as String? ?? '',
        photoPath: resolveMediaPath(j['photo'] as String?),
        birthday: j['bd'] as String?,
      );
}

/// "MM-DD" válido (p. ej. "02-29" sí, "13-01" no).
bool isValidBirthday(String? s) {
  if (s == null) return false;
  final m = RegExp(r'^(\d{2})-(\d{2})$').firstMatch(s);
  if (m == null) return false;
  final month = int.parse(m.group(1)!), day = int.parse(m.group(2)!);
  if (month < 1 || month > 12 || day < 1) return false;
  const days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= days[month - 1];
}

/// Quita tildes y pasa a minúsculas para buscar ("Jonrón" == "jonron").
String foldForSearch(String s) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
  const to = 'aaaaaeeeeiiiiooooouuuuncaaaaaeeeeiiiiooooouuuunc';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = from.indexOf(ch);
    b.write(i < 0 ? ch : to[i]);
  }
  return b.toString().toLowerCase();
}


/// Aviso de KLK para todos los usuarios (lo escribe el dueño desde su panel).
class KlkAnnouncement {
  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  const KlkAnnouncement({required this.id, required this.title, required this.body, required this.createdAt});

  factory KlkAnnouncement.fromJson(Map<String, dynamic> j) => KlkAnnouncement(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      );
}
