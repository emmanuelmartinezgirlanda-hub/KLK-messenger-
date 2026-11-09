import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/backup/backup_codec.dart';
import '../messaging/app_controller.dart';
import '../../core/l10n/l10n.dart';

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
  ({int every, DateTime? last})? _auto;
  bool _autoLoaded = false;
  bool _autoFileExists = false;

  @override
  void initState() {
    super.initState();
    _loadAuto();
  }

  Future<void> _loadAuto() async {
    final a = await ref.read(appProvider).autoBackupSettings();
    final exists = await (await AppController.autoBackupFile()).exists();
    if (mounted) {
      setState(() {
        _auto = a;
        _autoLoaded = true;
        _autoFileExists = exists;
      });
    }
  }

  Future<void> _toggleAuto(bool on) async {
    final app = ref.read(appProvider);
    if (!on) {
      await app.setAutoBackup(password: null);
      await _loadAuto();
      return;
    }
    final password = await _askPassword(create: true);
    if (password == null) return;
    await app.setAutoBackup(password: password, every: 1);
    setState(() {
      _busy = true;
      _status = 'Haciendo la primera copia automática…';
    });
    final ok = await app.maybeAutoBackup(force: true);
    if (mounted) {
      setState(() {
        _busy = false;
        _status = ok ? '¡Listo! KLK hará una copia sola cada día.' : 'Se activó; la primera copia se hará al volver a abrir KLK.';
      });
    }
    await _loadAuto();
  }

  Future<void> _backupNow() async {
    setState(() {
      _busy = true;
      _status = 'Haciendo la copia…';
    });
    final ok = await ref.read(appProvider).maybeAutoBackup(force: true);
    if (mounted) {
      setState(() {
        _busy = false;
        _status = ok ? 'Copia hecha ✓' : 'No se pudo hacer la copia ahora.';
      });
    }
    await _loadAuto();
  }

  Future<void> _shareAuto() async {
    final f = await AppController.autoBackupFile();
    if (!await f.exists() || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await Share.shareXFiles(
      [XFile(f.path, mimeType: 'application/octet-stream')],
      subject: 'Copia de seguridad de KLK',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    );
  }

  Widget _autoCard(ColorScheme cs) {
    final a = _auto;
    final last = a?.last;
    String when(DateTime d) {
      final diff = DateTime.now().difference(d);
      if (diff.inMinutes < 2) return 'ahora mismo';
      if (diff.inHours < 1) return 'hace ${diff.inMinutes} min';
      if (diff.inDays < 1) return 'hace ${diff.inHours} h';
      return 'hace ${diff.inDays} día${diff.inDays == 1 ? '' : 's'}';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          SwitchListTile(
            value: a != null,
            onChanged: _busy || !_autoLoaded ? null : _toggleAuto,
            secondary: const Icon(Icons.autorenew),
            title: Text(tr('Copia automática'), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(a == null
                ? tr('KLK guarda tus chats cifrados solo, sin que tengas que acordarte.')
                : last == null
                    ? tr('Activada · aún sin copia')
                    : '${tr('Última copia')}: ${when(last)}'),
          ),
          if (a != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<int>(
                segments: [
                  ButtonSegment(value: 1, label: Text(tr('Cada día'))),
                  ButtonSegment(value: 7, label: Text(tr('Cada semana'))),
                ],
                selected: {a.every},
                onSelectionChanged: (v) async {
                  await ref.read(appProvider).setAutoBackupEvery(v.first);
                  await _loadAuto();
                },
              ),
            ),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton.icon(
                  onPressed: _busy ? null : _backupNow, icon: const Icon(Icons.backup_outlined), label: Text(tr('Hacer ahora'))),
              if (_autoFileExists)
                TextButton.icon(
                    onPressed: _busy ? null : _shareAuto, icon: const Icon(Icons.ios_share), label: Text(tr('Guardar fuera'))),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                Platform.isIOS
                    ? tr('Se guarda en Archivos → En mi iPhone → KLK y entra en la copia de iCloud de tu iPhone. Para llevarla a otro móvil, toca «Guardar fuera» y ponla en iCloud Drive o Google Drive.')
                    : tr('Se guarda dentro de KLK. Para no perderla si cambias de móvil, toca «Guardar fuera» y ponla en Google Drive.'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ]),
      ),
    );
  }

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
          title: Text(create ? tr('Elige una contraseña') : tr('Contraseña de la copia')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (create)
              Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(tr('Apúntala en un sitio seguro: si la olvidas, nadie podrá abrir la copia. Ni siquiera KLK.')),
              ),
            TextField(
              controller: a,
              autofocus: true,
              obscureText: hide,
              decoration: InputDecoration(
                labelText: tr('Contraseña'),
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
                decoration: InputDecoration(labelText: tr('Repítela')),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancelar'))),
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
              child: Text(create ? tr('Crear copia') : tr('Restaurar')),
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
        title: Text(tr('¿Restaurar una copia?')),
        content: Text(tr('Los chats de la copia sustituirán a los que hay ahora en este móvil.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Elegir archivo'))),
        ],
      ),
    );
    if (ok != true) return;
    String? path;
    if (_autoFileExists && mounted) {
      final useAuto = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('¿Qué copia?')),
          content: Text(tr('Puedes usar la copia automática de este móvil o elegir un archivo.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Elegir archivo'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('La automática'))),
          ],
        ),
      );
      if (useAuto == null) return;
      if (useAuto) path = (await AppController.autoBackupFile()).path;
    }
    if (path == null) {
      final picked = await FilePicker.platform.pickFiles();
      path = picked?.files.single.path;
    }
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
      _snack(tr('Copia restaurada'));
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
      appBar: AppBar(title: Text(tr('Copia de seguridad'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Icon(Icons.cloud_done_outlined, size: 56, color: cs.secondary),
        const SizedBox(height: 12),
        Text(tr('Guarda tus chats cifrados'), textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'KLK crea un archivo cifrado con tu contraseña. Guárdalo en Archivos o en iCloud Drive y, '
          'si cambias de iPhone, lo restauras aquí. Incluye chats, mensajes y hasta 50 MB de fotos, '
          'vídeos y audios (los más recientes).',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.75)),
        ),
        const SizedBox(height: 20),
        _autoCard(cs),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.lock_outline),
          label: Text(tr('Crear copia cifrada')),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _restore,
          icon: const Icon(Icons.restore),
          label: Text(tr('Restaurar una copia')),
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
