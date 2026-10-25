import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../features/messaging/models.dart';
import 'db_platform.dart';

/// Base de datos local cifrada con SQLCipher (AES-256).
/// La clave la proporciona SecureStore (Keychain/Keystore).
class LocalDb {
  LocalDb._(this._db);
  final Database _db;

  static const _file = 'klk.db';

  /// Versión 4: respuestas, reacciones, borrado, temporales, ocultos, grupos y estados.
  static const _v4 = [
    'ALTER TABLE chats ADD COLUMN disappear_sec INTEGER',
    'ALTER TABLE chats ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE chats ADD COLUMN members_json TEXT',
    'ALTER TABLE messages ADD COLUMN reply_id TEXT',
    'ALTER TABLE messages ADD COLUMN reply_preview TEXT',
    'ALTER TABLE messages ADD COLUMN reactions_json TEXT',
    'ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE messages ADD COLUMN expires_at INTEGER',
    '''CREATE TABLE statuses (
         id TEXT PRIMARY KEY,
         owner_id TEXT NOT NULL,
         owner_name TEXT NOT NULL DEFAULT '',
         text TEXT NOT NULL DEFAULT '',
         color INTEGER NOT NULL DEFAULT 0,
         media_path TEXT,
         created_at INTEGER NOT NULL,
         allow_save INTEGER NOT NULL DEFAULT 0,
         viewed INTEGER NOT NULL DEFAULT 0
       )''',
  ];

  /// Versión 5: cumpleaños, mensajes fijados y contactos bloqueados.
  static const _v5 = [
    'ALTER TABLE chats ADD COLUMN birthday TEXT',
    'ALTER TABLE chats ADD COLUMN pinned_id TEXT',
    'ALTER TABLE chats ADD COLUMN blocked INTEGER NOT NULL DEFAULT 0',
  ];

  /// Versión 6: editar, destacar, silenciar, archivar y vista previa de enlaces.
  static const _v6 = [
    'ALTER TABLE messages ADD COLUMN edited_at INTEGER',
    'ALTER TABLE messages ADD COLUMN starred INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE messages ADD COLUMN link_json TEXT',
    'ALTER TABLE chats ADD COLUMN muted_until INTEGER',
    'ALTER TABLE chats ADD COLUMN archived INTEGER NOT NULL DEFAULT 0',
  ];

  /// Versión 7: claves y sesiones del cifrado Signal.
  static const _v7 = [
    'CREATE TABLE IF NOT EXISTS signal_kv (k TEXT PRIMARY KEY, v BLOB NOT NULL)',
  ];
  // Quién escribió cada mensaje de grupo (para denunciar o bloquear a esa persona).
  static const _v8 = [
    'ALTER TABLE messages ADD COLUMN sender_id TEXT',
  ];

  /// Ruta del archivo (para la copia de seguridad).
  static Future<String> filePath() async => p.join(await klkDatabasesPath(), _file);

  static Future<LocalDb> open(String key) async {
    final dir = await klkDatabasesPath();
    final db = await openKlkDatabase(
      p.join(dir, _file),
      key: key,
      version: 8,
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _migrate(db, 'ALTER TABLE messages ADD COLUMN media_json TEXT');
        if (oldVersion < 3) await _migrate(db, 'ALTER TABLE chats ADD COLUMN avatar_path TEXT');
        if (oldVersion < 4) {
          for (final sql in _v4) {
            await _migrate(db, sql);
          }
        }
        if (oldVersion < 5) {
          for (final sql in _v5) {
            await _migrate(db, sql);
          }
        }
        if (oldVersion < 6) {
          for (final sql in _v6) {
            await _migrate(db, sql);
          }
        }
        if (oldVersion < 7) {
          for (final sql in _v7) {
            await _migrate(db, sql);
          }
        }
        if (oldVersion < 8) {
          for (final sql in _v8) {
            await _migrate(db, sql);
          }
        }
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE chats (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            phone TEXT NOT NULL DEFAULT '',
            identity_key TEXT,
            is_group INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0,
            last_text TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL,
            avatar_path TEXT
          )''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            kind INTEGER NOT NULL,
            sender TEXT NOT NULL DEFAULT '',
            body TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            scheduled_for INTEGER,
            media_json TEXT
          )''');
        await db.execute('CREATE INDEX messages_chat_idx ON messages(chat_id, created_at)');
        for (final sql in [..._v4, ..._v5, ..._v6, ..._v7, ..._v8]) {
          await db.execute(sql);
        }
      },
      // Si alguien instaló una versión más vieja encima de una nueva, la base de
      // datos queda con un número de versión más bajo que sus columnas: no pasa nada.
      onDowngrade: (db, _, __) async {},
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    return LocalDb._(db);
  }

  /// Aplica un cambio de la base de datos. Si ya estaba hecho (columna o tabla que
  /// ya existe, p. ej. tras instalar una versión vieja encima de una nueva), se salta.
  static Future<void> _migrate(Database db, String sql) async {
    try {
      await db.execute(sql);
    } on DatabaseException catch (e) {
      final m = e.toString().toLowerCase();
      if (m.contains('duplicate column') || m.contains('already exists')) return;
      rethrow;
    }
  }

  /// Borra el archivo de la base de datos (botón de pánico).
  static Future<void> destroy() async {
    final path = p.join(await klkDatabasesPath(), _file);
    await deleteKlkDatabase(path);
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  Future<void> close() => _db.close();

  // ---------- Chats ----------

  Future<List<Chat>> chats() async {
    final rows = await _db.query('chats', orderBy: 'updated_at DESC');
    return rows.map(Chat.fromRow).toList();
  }

  Future<Chat?> chat(String id) async {
    final rows = await _db.query('chats', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Chat.fromRow(rows.first);
  }

  /// Crea o actualiza un chat. No usa REPLACE: en SQLite eso borra la fila
  /// y, por la clave foránea en cascada, también todos sus mensajes.
  Future<void> upsertChat(Chat c) async {
    final row = c.toRow();
    final updated = await _db.update('chats', row, where: 'id = ?', whereArgs: [c.id]);
    if (updated == 0) await _db.insert('chats', row);
  }

  Future<void> setIdentity(String chatId, String identityB64) =>
      _db.update('chats', {'identity_key': identityB64}, where: 'id = ?', whereArgs: [chatId]);

  Future<void> setAvatar(String chatId, String? path) =>
      _db.update('chats', {'avatar_path': path}, where: 'id = ?', whereArgs: [chatId]);

  Future<void> setTitle(String chatId, String title) =>
      _db.update('chats', {'title': title}, where: 'id = ?', whereArgs: [chatId]);

  Future<void> clearUnread(String chatId) =>
      _db.update('chats', {'unread': 0}, where: 'id = ?', whereArgs: [chatId]);

  // ---------- Mensajes ----------

  Future<List<Message>> messages(String chatId, {int limit = 500}) async {
    final rows = await _db.query('messages',
        where: 'chat_id = ?', whereArgs: [chatId], orderBy: 'created_at ASC', limit: limit);
    return rows.map(Message.fromRow).toList();
  }

  Future<bool> hasMessage(String id) async {
    final r = await _db.query('messages', columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isNotEmpty;
  }

  /// Inserta un mensaje y actualiza la vista previa del chat.
  Future<void> addMessage(Message m, {bool countUnread = false}) async {
    await _db.transaction((tx) async {
      await tx.insert('messages', m.toRow(), conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.rawUpdate(
        'UPDATE chats SET last_text = ?, updated_at = ?, unread = unread + ? WHERE id = ?',
        [m.preview, m.createdAt.millisecondsSinceEpoch, countUnread ? 1 : 0, m.chatId],
      );
    });
  }

  Future<Message?> message(String id) async {
    final r = await _db.query('messages', where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : Message.fromRow(r.first);
  }

  /// Actualiza el adjunto de un mensaje (p. ej. cuando termina de descargarse).
  Future<void> setMedia(String messageId, MessageMedia media) => _db.update(
      'messages', {'media_json': jsonEncode(media.toJson())}, where: 'id = ?', whereArgs: [messageId]);

  /// Mensajes recibidos cuyo adjunto aún no se ha descargado.
  Future<List<Message>> pendingDownloads() async {
    final rows = await _db.query('messages',
        where: 'kind = ? AND media_json IS NOT NULL', whereArgs: [MessageKind.incoming.index]);
    return rows.map(Message.fromRow).where((m) => m.media?.needsDownload ?? false).toList();
  }

  Future<void> deleteMessage(String id) => _db.delete('messages', where: 'id = ?', whereArgs: [id]);

  /// Al abrir KLK: los adjuntos que se quedaron "enviando" (la app se cerró a
  /// mitad de la subida) pasan a "no enviado" para que no se queden con el reloj.
  Future<void> failInterruptedUploads() => _db.rawUpdate(
      "UPDATE messages SET status = ? WHERE status = ? AND media_json IS NOT NULL",
      [MessageStatus.failed.name, MessageStatus.sending.name]);

  Future<void> setStatus(String messageId, MessageStatus status) => _db.update(
      'messages', {'status': status.name}, where: 'id = ?', whereArgs: [messageId]);

  /// Avanza el estado sin retroceder (p. ej. no pasar de "leído" a "entregado").
  Future<void> advanceStatus(List<String> ids, MessageStatus status) async {
    if (ids.isEmpty) return;
    final lower = MessageStatus.values.where((s) => s.index < status.index).map((s) => "'${s.name}'").join(',');
    if (lower.isEmpty) return;
    final marks = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
        "UPDATE messages SET status = ? WHERE id IN ($marks) AND status IN ($lower)", [status.name, ...ids]);
  }

  /// Ids de mensajes recibidos aún sin confirmar como leídos.
  Future<List<String>> unreadIncoming(String chatId) async {
    final rows = await _db.query('messages',
        columns: ['id'],
        where: 'chat_id = ? AND kind = ? AND status != ?',
        whereArgs: [chatId, MessageKind.incoming.index, MessageStatus.read.name]);
    return rows.map((r) => r['id'] as String).toList();
  }

  /// Marca como enviados los mensajes programados cuya hora ya pasó.
  Future<void> settleScheduled(DateTime now) => _db.rawUpdate(
      "UPDATE messages SET status = 'sent' WHERE status = 'scheduled' AND scheduled_for <= ?",
      [now.millisecondsSinceEpoch]);

  // ---------- v4: mensajes ----------

  /// Reescribe un mensaje entero (reacciones, borrado, adjunto abierto…).
  Future<void> updateMessage(Message m) =>
      _db.update('messages', m.toRow(), where: 'id = ?', whereArgs: [m.id]);

  /// Borra los mensajes temporales caducados. Devuelve los adjuntos a borrar del disco.
  Future<List<String>> purgeExpired(DateTime now) async {
    final rows = await _db.query('messages',
        columns: ['media_json'],
        where: 'expires_at IS NOT NULL AND expires_at <= ? AND media_json IS NOT NULL',
        whereArgs: [now.millisecondsSinceEpoch]);
    final files = <String>[];
    for (final r in rows) {
      final path = (jsonDecode(r['media_json'] as String) as Map)['path'] as String?;
      if (path != null) files.add(path);
    }
    await _db.delete('messages', where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now.millisecondsSinceEpoch]);
    return files;
  }

  // ---------- v4: chats ----------

  Future<void> setHidden(String chatId, bool hidden) =>
      _db.update('chats', {'hidden': hidden ? 1 : 0}, where: 'id = ?', whereArgs: [chatId]);

  Future<void> setDisappear(String chatId, int? seconds) =>
      _db.update('chats', {'disappear_sec': seconds}, where: 'id = ?', whereArgs: [chatId]);

  // ---------- v5 ----------

  Future<void> setBirthday(String chatId, String? birthday) =>
      _db.update('chats', {'birthday': birthday}, where: 'id = ?', whereArgs: [chatId]);

  Future<void> setPinned(String chatId, String? messageId) =>
      _db.update('chats', {'pinned_id': messageId}, where: 'id = ?', whereArgs: [chatId]);

  Future<void> setBlocked(String chatId, bool blocked) =>
      _db.update('chats', {'blocked': blocked ? 1 : 0}, where: 'id = ?', whereArgs: [chatId]);

  // ---------- v7: claves de Signal ----------

  Future<Uint8List?> kvGet(String k) async {
    final r = await _db.query('signal_kv', columns: ['v'], where: 'k = ?', whereArgs: [k], limit: 1);
    if (r.isEmpty) return null;
    final v = r.first['v'];
    return v is Uint8List ? v : Uint8List.fromList((v as List).cast<int>());
  }

  Future<void> kvPut(String k, List<int> v) =>
      _db.insert('signal_kv', {'k': k, 'v': Uint8List.fromList(v)}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> kvDelete(String k) => _db.delete('signal_kv', where: 'k = ?', whereArgs: [k]);

  Future<List<String>> kvKeys(String prefix) async {
    final r = await _db.query('signal_kv',
        columns: ['k'], where: "k LIKE ? ESCAPE '\\'", whereArgs: ['${prefix.replaceAll('%', r'\%').replaceAll('_', r'\_')}%']);
    return [for (final row in r) row['k'] as String];
  }

  // ---------- v6 ----------

  Future<void> setStarred(String messageId, bool starred) =>
      _db.update('messages', {'starred': starred ? 1 : 0}, where: 'id = ?', whereArgs: [messageId]);

  /// Mensajes destacados de todos los chats (los más nuevos primero).
  Future<List<Message>> starredMessages() async {
    final rows = await _db.query('messages', where: 'starred = 1 AND deleted = 0', orderBy: 'created_at DESC');
    return rows.map(Message.fromRow).toList();
  }

  Future<void> setMuted(String chatId, DateTime? until) => _db.update(
      'chats', {'muted_until': until?.millisecondsSinceEpoch}, where: 'id = ?', whereArgs: [chatId]);

  Future<void> setArchived(String chatId, bool archived) =>
      _db.update('chats', {'archived': archived ? 1 : 0}, where: 'id = ?', whereArgs: [chatId]);

  /// Cambia el texto de un mensaje (editado) y, si es el último, la vista previa del chat.
  Future<void> editMessage(String messageId, String body, DateTime at, {String? linkJson}) =>
      _db.update('messages', {'body': body, 'edited_at': at.millisecondsSinceEpoch, 'link_json': linkJson},
          where: 'id = ?', whereArgs: [messageId]);

  /// Todos los sanes guardados en el móvil (para contar los míos y los recordatorios).
  Future<List<Message>> sanMessages() async {
    final rows = await _db.query('messages', where: "media_json LIKE '%\"t\":\"san\"%'");
    return rows.map(Message.fromRow).toList();
  }

  /// Mensajes de un chat con un tipo de adjunto (p. ej. los pedidos y citas de un negocio).
  Future<List<Message>> messagesOfType(String chatId, MediaType type) async {
    final rows = await _db.query('messages',
        where: "chat_id = ? AND media_json LIKE ?", whereArgs: [chatId, '%"t":"${type.name}"%']);
    return rows.map(Message.fromRow).toList();
  }

  /// Mis ubicaciones en tiempo real que quedaron activas (p. ej. al cerrar la app).
  Future<List<Message>> myLiveLocations() async {
    final rows = await _db.query('messages',
        where: "kind = ? AND media_json LIKE '%\"t\":\"live\"%'", whereArgs: [MessageKind.outgoing.index]);
    return rows.map(Message.fromRow).toList();
  }

  Future<void> deleteChat(String chatId) => _db.delete('chats', where: 'id = ?', whereArgs: [chatId]);

  /// Vacía el chat: borra todos sus mensajes pero el chat (y el contacto) se quedan.
  Future<void> clearChat(String chatId) async {
    await _db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
    await _db.update('chats', {'last_text': '', 'unread': 0}, where: 'id = ?', whereArgs: [chatId]);
  }

  /// Borra el chat y todos sus mensajes (al eliminar un contacto).
  Future<void> deleteChatWithMessages(String chatId) async {
    await _db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
    await _db.delete('chats', where: 'id = ?', whereArgs: [chatId]);
  }

  // ---------- v4: estados ----------

  Future<void> addStatus(StatusPost s) =>
      _db.insert('statuses', s.toRow(), conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<List<StatusPost>> statuses(DateTime now) async {
    final since = now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    final rows = await _db.query('statuses', where: 'created_at > ?', whereArgs: [since], orderBy: 'created_at ASC');
    return rows.map(StatusPost.fromRow).toList();
  }

  /// Borra un estado. Si se da [ownerId], solo si es de esa persona.
  /// Devuelve su foto o vídeo para borrarlo del disco.
  Future<String?> deleteStatus(String id, {String? ownerId}) async {
    final where = ownerId == null ? 'id = ?' : 'id = ? AND owner_id = ?';
    final args = ownerId == null ? [id] : [id, ownerId];
    final rows = await _db.query('statuses', columns: ['media_path'], where: where, whereArgs: args);
    if (rows.isEmpty) return null;
    await _db.delete('statuses', where: where, whereArgs: args);
    return rows.first['media_path'] as String?;
  }

  Future<void> markStatusViewed(String id) =>
      _db.update('statuses', {'viewed': 1}, where: 'id = ?', whereArgs: [id]);

  /// Borra los estados de más de 24 h. Devuelve sus fotos para borrarlas del disco.
  Future<List<String>> purgeStatuses(DateTime now) async {
    final before = now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    final rows = await _db.query('statuses', columns: ['media_path'], where: 'created_at <= ?', whereArgs: [before]);
    await _db.delete('statuses', where: 'created_at <= ?', whereArgs: [before]);
    return [for (final r in rows) if (r['media_path'] != null) r['media_path'] as String];
  }
}
