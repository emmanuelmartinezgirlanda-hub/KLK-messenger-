import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../core/l10n/l10n.dart';
import '../../core/media/media_store.dart';
import '../chat/presentation/chat_avatar.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'whatsapp_parser.dart';

/// Trae una conversación de WhatsApp a KLK.
///
/// En WhatsApp: abre el chat → toca el nombre → «Exportar chat» (con o sin
/// archivos) → «Guardar en Archivos». Aquí eliges ese archivo (.zip o .txt),
/// dices cuál de los nombres eres tú y en qué chat de KLK va. Los mensajes se
/// quedan solo en tu móvil: no se le envían a nadie.
class WhatsAppImportScreen extends ConsumerStatefulWidget {
  const WhatsAppImportScreen({super.key, this.chatId});
  final String? chatId;

  @override
  ConsumerState<WhatsAppImportScreen> createState() => _WhatsAppImportScreenState();
}

class _WhatsAppImportScreenState extends ConsumerState<WhatsAppImportScreen> {
  WaChat? _chat;
  Map<String, ArchiveFile> _files = {};
  String? _me;
  String? _target;
  bool _busy = false;
  double _progress = 0;
  String? _error;
  int? _done;

  @override
  void initState() {
    super.initState();
    _target = widget.chatId;
  }

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.any);
      final path = r?.files.single.path;
      if (path == null) {
        setState(() => _busy = false);
        return;
      }
      String? text;
      final files = <String, ArchiveFile>{};
      if (path.toLowerCase().endsWith('.zip')) {
        final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
        for (final f in archive.files) {
          if (!f.isFile) continue;
          final name = p.basename(f.name);
          if (name.toLowerCase().endsWith('.txt') && (text == null || name.contains('chat'))) {
            text = _decodeText(f.content as List<int>);
          } else {
            files[name] = f;
          }
        }
      } else {
        text = _decodeText(await File(path).readAsBytes());
      }
      if (text == null) throw const FormatException('No encontré el chat dentro del archivo.');
      final chat = parseWhatsApp(text);
      if (chat.messages.isEmpty) {
        throw const FormatException('Este archivo no parece un chat exportado de WhatsApp.');
      }
      final people = chat.participants;
      setState(() {
        _chat = chat;
        _files = files;
        // Quien exporta suele ser «Tú/You/Yo» o el nombre que menos aparece en un chat de dos.
        _me = people.firstWhere((n) => const {'tú', 'tu', 'yo', 'you', 'me'}.contains(n.toLowerCase()),
            orElse: () => people.length == 2 ? people.last : people.first);
        _target ??= _guessTarget(people);
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is FormatException ? e.message : tr('No se pudo leer el archivo.');
      });
    }
  }

  String _decodeText(List<int> bytes) {
    try {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  String? _guessTarget(List<String> people) {
    final chats = ref.read(appProvider).chats.where((c) => !c.isNotes).toList();
    for (final n in people) {
      final low = n.toLowerCase();
      for (final c in chats) {
        if (c.title.toLowerCase() == low) return c.id;
      }
    }
    return null;
  }

  Future<void> _import() async {
    final chat = _chat;
    final me = _me;
    final target = _target;
    if (chat == null || me == null || target == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
    });
    final out = <Message>[];
    final total = chat.messages.length;
    for (var i = 0; i < total; i++) {
      final m = chat.messages[i];
      MessageMedia? media;
      var body = m.body;
      final att = m.attachment;
      if (att != null) {
        final f = _files[att];
        if (f != null) {
          final ext = p.extension(att).toLowerCase();
          final dest = await MediaStore.newPath(ext);
          await File(dest).writeAsBytes(f.content as List<int>, flush: false);
          media = MessageMedia(
            type: _typeFor(ext),
            localPath: dest,
            mime: MediaStore.mimeFor(dest),
            name: att,
            size: f.size,
          );
        } else if (body.isEmpty) {
          body = '📎 $att';
        }
      }
      final mine = m.sender == me;
      out.add(Message(
        id: 'wa-$target-${m.at.millisecondsSinceEpoch}-$i',
        chatId: target,
        kind: mine ? MessageKind.outgoing : MessageKind.incoming,
        sender: mine ? '' : m.sender,
        body: body,
        status: MessageStatus.read,
        createdAt: m.at,
        media: media,
      ));
      if (i % 50 == 0 && mounted) setState(() => _progress = i / total);
    }
    final note = '📥 ${tr('Chat importado de WhatsApp')} · ${out.length} ${tr('mensajes')}';
    await ref.read(appProvider).importIntoChat(target, out, note: note);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = out.length;
    });
  }

  MediaType _typeFor(String ext) => switch (ext) {
        '.jpg' || '.jpeg' || '.png' || '.heic' || '.webp' || '.gif' => MediaType.image,
        '.mp4' || '.mov' || '.3gp' || '.m4v' || '.webm' => MediaType.video,
        '.opus' || '.ogg' || '.m4a' || '.mp3' || '.aac' => MediaType.audio,
        _ => MediaType.file,
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Importar de WhatsApp'))),
      body: SafeArea(
        child: _done != null
            ? _doneView(cs)
            : _chat == null
                ? _intro(cs)
                : _setup(cs),
      ),
    );
  }

  Widget _intro(ColorScheme cs) => ListView(padding: const EdgeInsets.all(20), children: [
        const Text('📥', style: TextStyle(fontSize: 56), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(tr('Trae tus chats de WhatsApp a KLK'),
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(tr('Así no pierdes tus mensajes y fotos al pasarte a KLK.'),
            textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
        const SizedBox(height: 24),
        _step('1', tr('En WhatsApp, abre el chat que quieres traer.')),
        _step('2', tr('Toca el nombre arriba y luego «Exportar chat».')),
        _step('3', tr('Elige «Adjuntar archivos» si quieres las fotos y audios.')),
        _step('4', tr('Toca «Guardar en Archivos» (o «Guardar en el dispositivo»).')),
        _step('5', tr('Vuelve aquí y toca «Elegir archivo».')),
        const SizedBox(height: 20),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: TextStyle(color: cs.error), textAlign: TextAlign.center),
          ),
        FilledButton.icon(
          onPressed: _busy ? null : _pick,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.folder_open),
          label: Text(tr('Elegir archivo')),
        ),
        const SizedBox(height: 12),
        Text(tr('Los mensajes importados se quedan solo en tu móvil: no se le envían a nadie.'),
            textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
      ]);

  Widget _step(String n, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 13, child: Text(n, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800))),
          const SizedBox(width: 12),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(text, style: const TextStyle(fontSize: 16)))),
        ]),
      );

  Widget _setup(ColorScheme cs) {
    final chat = _chat!;
    final people = chat.participants;
    final first = chat.messages.first.at, last = chat.messages.last.at;
    final fmt = DateFormat.yMMMd('es');
    final chats = ref.watch(appProvider).chats.where((c) => !c.isNotes).toList();
    final withFiles = chat.messages.where((m) => m.attachment != null && _files.containsKey(m.attachment)).length;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.chat_outlined),
          title: Text('${chat.messages.length} ${tr('mensajes')}'),
          subtitle: Text('${fmt.format(first)} – ${fmt.format(last)}'
              '${withFiles > 0 ? ' · $withFiles ${tr('fotos y archivos')}' : ''}'),
        ),
      ),
      const SizedBox(height: 16),
      Text(tr('¿Cuál de estos eres tú?'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      for (final n in people.take(12))
        RadioListTile<String>(
          value: n,
          groupValue: _me,
          onChanged: _busy ? null : (v) => setState(() => _me = v),
          title: Text(n),
        ),
      const SizedBox(height: 12),
      Text(tr('¿En qué chat de KLK lo pongo?'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        value: chats.any((c) => c.id == _target) ? _target : null,
        isExpanded: true,
        hint: Text(tr('Elige un chat')),
        items: [
          for (final c in chats)
            DropdownMenuItem(
              value: c.id,
              child: Row(children: [
                ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath, radius: 14),
                const SizedBox(width: 10),
                Expanded(child: Text(c.title, overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
        onChanged: _busy ? null : (v) => setState(() => _target = v),
      ),
      const SizedBox(height: 8),
      Text(tr('Si la persona aún no está en KLK, primero abre un chat con ella.'),
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
      const SizedBox(height: 24),
      if (_busy) ...[
        LinearProgressIndicator(value: _progress),
        const SizedBox(height: 8),
        Text(tr('Importando…'), textAlign: TextAlign.center),
      ] else
        FilledButton(
          onPressed: _me != null && _target != null ? _import : null,
          child: Text(tr('Importar')),
        ),
    ]);
  }

  Widget _doneView(ColorScheme cs) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('✅', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 12),
            Text('${tr('Listo')}: $_done ${tr('mensajes importados')}',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Ver el chat'))),
            TextButton(
              onPressed: () => setState(() {
                _done = null;
                _chat = null;
                _files = {};
              }),
              child: Text(tr('Importar otro chat')),
            ),
          ]),
        ),
      );
}
