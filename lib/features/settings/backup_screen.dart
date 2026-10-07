import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/backup/backup_codec.dart';
import '../messaging/app_controller.dart';

/// Copia de seguridad cifrada con contraseña: crear y restaurar.
///
/// El archivo se guarda donde elija el usuario (Archivos, iCloud Drive,
/// Google Drive…). Sin la contraseña no se puede abrir: ni KLK puede.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  String? _status;

  void _set(String status) {
    if (mounted) setState(() => _status = status);
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<String?> _askPassword({required bool create}) {
    final a = TextEditingController();
    final b = TextEditingController();
    var hide = true;
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(create ? 'Elige una contraseña' : 'Contraseña de la copia'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (create)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Apúntala en un sitio seguro: si la olvidas, nadie podrá abrir la copia. Ni siquiera KLK.'),
              ),
            TextField(
              controller: a,
              autofocus: true,
              obscureText: hide,
              decoration: InputDecoration(
                labelText: 'Contraseña',
                errorText: error,
                suffixIcon: IconButton(
                  icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => hide = !hide),
                ),
              ),
            ),
            if (create)
              TextField(
                controller: b,
                obscureText: hide,
                decoration: const InputDecoration(labelText: 'Repítela'),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                if (create && a.text.length < BackupCodec.minPasswordLength) {
                  setState(() => error = 'Al menos ${BackupCodec.minPasswordLength} caracteres');
                  return;
                }
                if (create && a.text != b.text) {
                  setState(() => error = 'No coinciden');
                  return;
                }
                Navigator.pop(ctx, a.text);
              },
              child: Text(create ? 'Crear copia' : 'Restaurar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _create() async {
    final password = await _askPassword(create: true);
    if (password == null) return;
    setState(() {
      _busy = true;
      _status = 'Cifrando tus chats… puede tardar un poco';
    });
    try {
      final r = await ref.read(appProvider).exportBackup(password);
      _set('Copia lista: ${r.media} archivos incluidos'
          '${r.skipped > 0 ? ' (${r.skipped} no cupieron; se guardan los más recientes hasta 50 MB)' : ''}.');
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(r.file.path, mimeType: 'application/octet-stream')],
        subject: 'Copia de seguridad de KLK',
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      );
    } on BackupException catch (e) {
      _set(e.message);
    } catch (e) {
      _set('No se pudo crear la copia: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Restaurar una copia?'),
        content: const Text('Los chats de la copia sustituirán a los que hay ahora en este móvil.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Elegir archivo')),
        ],
      ),
    );
    if (ok != true) return;
    final picked = await FilePicker.platform.pickFiles();
    final path = picked?.files.single.path;
    if (path == null) return;
    final password = await _askPassword(create: false);
    if (password == null) return;
    setState(() {
      _busy = true;
      _status = 'Descifrando la copia…';
    });
    try {
      await ref.read(appProvider).importBackup(path, password);
      _set('¡Listo! Tus chats están de vuelta.');
      _snack('Copia restaurada');
    } on BackupException catch (e) {
      _set(e.message);
    } catch (e) {
      _set('No se pudo restaurar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Copia de seguridad')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Icon(Icons.cloud_done_outlined, size: 56, color: cs.secondary),
        const SizedBox(height: 12),
        const Text('Guarda tus chats cifrados', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'KLK crea un archivo cifrado con tu contraseña. Guárdalo en Archivos o en iCloud Drive y, '
          'si cambias de iPhone, lo restauras aquí. Incluye chats, mensajes y hasta 50 MB de fotos, '
          'vídeos y audios (los más recientes).',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.75)),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.lock_outline),
          label: const Text('Crear copia cifrada'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _restore,
          icon: const Icon(Icons.restore),
          label: const Text('Restaurar una copia'),
        ),
        const SizedBox(height: 20),
        if (_busy) const Center(child: CircularProgressIndicator()),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_status!, textAlign: TextAlign.center),
          ),
        const SizedBox(height: 24),
        Text(
          'Las claves de cifrado de tus conversaciones no se copian: en el móvil nuevo KLK crea unas nuevas '
          'y tus contactos verán un aviso de que tu clave cambió. Es lo normal y más seguro.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.55)),
        ),
      ]),
    );
  }
}
