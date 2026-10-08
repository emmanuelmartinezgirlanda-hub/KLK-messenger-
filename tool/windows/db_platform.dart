// Versión de Windows de lib/core/database/db_platform.dart.
// La copia el flujo .github/workflows/windows.yml antes de compilar.
// Usa SQLCipher por FFI (paquete sqlite3 con `source: sqlcipher`), así la base
// de datos va cifrada igual que en el móvil.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> klkDatabasesPath() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'db'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir.path;
}

Future<Database> openKlkDatabase(
  String path, {
  required String key,
  required int version,
  required OnDatabaseCreateFn onCreate,
  required OnDatabaseVersionChangeFn onUpgrade,
  required OnDatabaseConfigureFn onConfigure,
}) {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      onConfigure: (db) async {
        // La clave tiene que ser lo primero que se ejecuta.
        await db.execute("PRAGMA key = '${key.replaceAll("'", "''")}'");
        await onConfigure(db);
      },
    ),
  );
}

Future<void> deleteKlkDatabase(String path) => databaseFactoryFfi.deleteDatabase(path);
