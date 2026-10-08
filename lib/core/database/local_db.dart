import 'dart:convert';
import 'dart:io';

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

  /// Ruta del archivo (para la copia de seguridad).
  static Future<String> filePath() async => p.join(await klkDatabasesPath(), _file);

  static Future<LocalDb> open(String key) async {
    final dir = await klkDatabasesPath();
    final db = await openKlkDatabase(
      p.join(dir, _file),
      key: key,
      version: 5,
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await db.execute('ALTER TABLE messages ADD COLUMN media_json TEXT');
        if (oldVersion < 3) await db.execute('ALTER TABLE chats ADD COLUMN avatar_path TEXT');
        if (oldVersion < 4) {
          for (final sql in _v4) {
            await db.execute(sql);
          }
        }
        if (oldVersion < 5) {
          for (final sql in _v5) {
            await db.execute(sql);
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
        for (final sql in [..._v4, ..._v5]) {
          await db.execute(sql);
        }
      },
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    return LocalDb._(db);
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

  /// Mis ubicaciones en tiempo real que quedaron activas (p. ej. al cerrar la app).
  Future<List<Message>> myLiveLocations() async {
    final rows = await _db.query('messages',
        where: "kind = ? AND media_json LIKE '%\"t\":\"live\"%'", whereArgs: [MessageKind.outgoing.index]);
    return rows.map(Message.fromRow).toList();
  }

  Future<void> deleteChat(String chatId) => _db.delete('chats', where: 'id = ?', whereArgs: [chatId]);

  // ---------- v4: estados ----------

  Future<void> addStatus(StatusPost s) =>
      _db.insert('statuses', s.toRow(), conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<List<StatusPost>> statuses(DateTime now) async {
    final since = now.subtract(const Duration(hours: 24)).millisecondsSinceEpoch;
    final rows = await _db.query('statuses', where: 'created_at > ?', whereArgs: [since], orderBy: 'created_at ASC');
    return rows.map(StatusPost.fromRow).toList();
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
