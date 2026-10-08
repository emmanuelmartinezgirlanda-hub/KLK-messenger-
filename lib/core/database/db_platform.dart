// Apertura de la base de datos cifrada en iPhone y Android (SQLCipher).
//
// En la versión de Windows, el flujo de GitHub Actions sustituye este archivo
// por tool/windows/db_platform.dart, que usa SQLCipher por FFI.
import 'package:sqflite_sqlcipher/sqflite.dart';

Future<String> klkDatabasesPath() => getDatabasesPath();

Future<Database> openKlkDatabase(
  String path, {
  required String key,
  required int version,
  required OnDatabaseCreateFn onCreate,
  required OnDatabaseVersionChangeFn onUpgrade,
  required OnDatabaseConfigureFn onConfigure,
}) =>
    openDatabase(
      path,
      password: key,
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      onConfigure: onConfigure,
    );

Future<void> deleteKlkDatabase(String path) => deleteDatabase(path);
