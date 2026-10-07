import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../features/messaging/models.dart';

/// Base de datos local cifrada con SQLCipher (AES-256).
/// La clave la proporciona SecureStore (Keychain/Keystore).
class LocalDb {
  LocalDb._(this._db);
  final Database _db;

  static const _file = 'klk.db';

  static Future<LocalDb> open(String key) async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, _file),
      password: key,
      version: 3,
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await db.execute('ALTER TABLE messages ADD COLUMN media_json TEXT');
        if (oldVersion < 3) await db.execute('ALTER TABLE chats ADD COLUMN avatar_path TEXT');
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
      },
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    return LocalDb._(db);
  }

  /// Borra el archivo de la base de datos (botón de pánico).
  static Future<void> destroy() async {
    final path = p.join(await getDatabasesPath(), _file);
    await deleteDatabase(path);
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
}
