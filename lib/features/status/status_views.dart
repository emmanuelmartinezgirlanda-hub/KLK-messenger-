import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../chat/presentation/chat_avatar.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';

const statusColors = [
  0xFF002D62, // azul Quisqueya
  0xFFCE1126, // rojo Patria
  0xFF1F7A4D,
  0xFF6A2C91,
  0xFFC46A00,
  0xFF00A6B4,
  0xFF0B1320,
];

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'ahora';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  return 'hace ${d.inHours} h';
}

/// Pestaña "Estados": el mío arriba y luego los de mis contactos.
class StatusesView extends ConsumerWidget {
  const StatusesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final mine = app.statuses.where((s) => s.isMine).toList();
    final byOwner = <String, List<StatusPost>>{};
    for (final s in app.statuses.where((s) => !s.isMine)) {
      byOwner.putIfAbsent(s.ownerId, () => []).add(s);
    }
    final unseen = byOwner.entries.where((e) => e.value.any((s) => !s.viewed)).toList();
    final seen = byOwner.entries.where((e) => e.value.every((s) => s.viewed)).toList();

    Widget ownerTile(MapEntry<String, List<StatusPost>> e, {required bool ring}) {
      final last = e.value.last;
      final chat = app.chatById(e.key);
      return ListTile(
        leading: _Ring(
          active: ring,
          child: ChatAvatar(id: e.key, title: last.ownerName, photoPath: chat?.avatarPath, radius: 24),
        ),
        title: Text(chat?.title ?? last.ownerName, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(_ago(last.createdAt)),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => StatusViewer(posts: e.value, title: chat?.title ?? last.ownerName),
        )),
      );
    }

    return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
      ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        leading: Stack(clipBehavior: Clip.none, children: [
          _Ring(
            active: mine.isNotEmpty,
            child: ChatAvatar(id: 'me', title: app.profile.name.isEmpty ? 'Tú' : app.profile.name,
                photoPath: app.profile.photoPath, radius: 24),
          ),
          if (mine.isEmpty)
            Positioned(
              right: -2,
              bottom: -2,
              child: CircleAvatar(radius: 11, backgroundColor: cs.secondary,
                  child: Icon(Icons.add, size: 16, color: cs.onSecondary)),
            ),
        ]),
        title: const Text('Mi estado', style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(mine.isEmpty ? 'Toca para compartir algo por 24 horas' : _ago(mine.last.createdAt)),
        onTap: () => mine.isEmpty
            ? showStatusComposer(context)
            : Navigator.of(context).push(MaterialPageRoute(
                fullscreenDialog: true, builder: (_) => StatusViewer(posts: mine, title: 'Mi estado'))),
        trailing: IconButton(
          tooltip: 'Nuevo estado',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => showStatusComposer(context),
        ),
      ),
      if (unseen.isNotEmpty) const _Section('RECIENTES'),
      for (final e in unseen) ownerTile(e, ring: true),
      if (seen.isNotEmpty) const _Section('VISTOS'),
      for (final e in seen) ownerTile(e, ring: false),
      if (byOwner.isEmpty)
        Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Aquí verás los estados de tus contactos. Duran 24 horas y luego desaparecen.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ),
    ]);
  }
}

class _Ring extends StatelessWidget {
  final bool active;
  final Widget child;
  const _Ring({required this.active, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: active
              ? const SweepGradient(colors: [Color(0xFF002D62), Color(0xFFCE1126), Color(0xFFFFB627), Color(0xFF002D62)])
              : null,
          border: active ? null : Border.all(color: Colors.grey.withValues(alpha: 0.5), width: 2),
        ),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.surface),
          child: child,
        ),
      );
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: TextStyle(fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.secondary)),
      );
}

// ---------- Crear estado ----------

Future<void> showStatusComposer(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _StatusComposer()));

class _StatusComposer extends ConsumerStatefulWidget {
  const _StatusComposer();

  @override
  ConsumerState<_StatusComposer> createState() => _StatusComposerState();
}

class _StatusComposerState extends ConsumerState<_StatusComposer> {
  final _text = TextEditingController();
  int _color = statusColors.first;
  String? _photo;
  bool _posting = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
      if (x != null) setState(() => _photo = x.path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('KLK no tiene permiso para tus fotos. Actívalo en Ajustes del iPhone → KLK.')));
      }
    }
  }

  Future<void> _post() async {
    if (_text.text.trim().isEmpty && _photo == null) return;
    setState(() => _posting = true);
    await ref.read(appProvider).postStatus(text: _text.text.trim(), color: _color, photoSourcePath: _photo);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final canPost = (_text.text.trim().isNotEmpty || _photo != null) && !_posting;
    return Scaffold(
      backgroundColor: Color(_color),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(tooltip: 'Foto', icon: const Icon(Icons.photo_library_outlined), onPressed: _pickPhoto),
          IconButton(
            tooltip: 'Color de fondo',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => setState(() => _color = statusColors[(statusColors.indexOf(_color) + 1) % statusColors.length]),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Center(
              child: _photo != null
                  ? Stack(alignment: Alignment.topRight, children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(File(_photo!))),
                      ),
                      IconButton(
                        onPressed: () => setState(() => _photo = null),
                        icon: const CircleAvatar(backgroundColor: Colors.black54, child: Icon(Icons.close, color: Colors.white)),
                      ),
                    ])
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: TextField(
                        controller: _text,
                        autofocus: true,
                        maxLines: null,
                        maxLength: 300,
                        textAlign: TextAlign.center,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700),
                        cursorColor: Colors.white,
                        decoration: const InputDecoration(
                          hintText: 'Escribe algo…',
                          hintStyle: TextStyle(color: Colors.white54),
                          border: InputBorder.none,
                          counterStyle: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
            ),
          ),
          if (_photo != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _text,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Añade un texto…',
                  hintStyle: TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const Expanded(
                child: Text('Lo verán tus contactos durante 24 horas',
                    style: TextStyle(color: Colors.white70, fontSize: 12.5)),
              ),
              FloatingActionButton(
                onPressed: canPost ? _post : null,
                backgroundColor: canPost ? Colors.white : Colors.white38,
                foregroundColor: Color(_color),
                child: _posting ? const CircularProgressIndicator() : const Icon(Icons.send),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------- Ver estados ----------

/// Visor a pantalla completa: avanza solo cada 5 s; tocar a la derecha
/// pasa al siguiente y a la izquierda vuelve al anterior.
class StatusViewer extends ConsumerStatefulWidget {
  final List<StatusPost> posts;
  final String title;
  const StatusViewer({super.key, required this.posts, required this.title});

  @override
  ConsumerState<StatusViewer> createState() => _StatusViewerState();
}

class _StatusViewerState extends ConsumerState<StatusViewer> {
  int _i = 0;
  double _progress = 0;
  Timer? _timer;
  static const _duration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    // Empieza por el primero sin ver
    final first = widget.posts.indexWhere((p) => !p.viewed);
    _i = first < 0 ? 0 : first;
    _start();
  }

  void _start() {
    _timer?.cancel();
    _progress = 0;
    final post = widget.posts[_i];
    if (!post.isMine && !post.viewed) ref.read(appProvider).markStatusViewed(post.id);
    const tick = Duration(milliseconds: 50);
    _timer = Timer.periodic(tick, (_) {
      setState(() => _progress += tick.inMilliseconds / _duration.inMilliseconds);
      if (_progress >= 1) _next();
    });
  }

  void _next() {
    if (_i + 1 >= widget.posts.length) {
      _timer?.cancel();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _i++);
    _start();
  }

  void _prev() {
    if (_i == 0) return;
    setState(() => _i--);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.posts[_i];
    final hasPhoto = post.mediaPath != null && File(post.mediaPath!).existsSync();
    return Scaffold(
      backgroundColor: hasPhoto ? Colors.black : Color(post.color),
      body: GestureDetector(
        onTapUp: (d) {
          if (d.globalPosition.dx < MediaQuery.sizeOf(context).width / 3) {
            _prev();
          } else {
            _next();
          }
        },
        onLongPressStart: (_) => _timer?.cancel(),
        onLongPressEnd: (_) => _start(),
        child: Stack(fit: StackFit.expand, children: [
          if (hasPhoto) Image.file(File(post.mediaPath!), fit: BoxFit.contain),
          if (post.text.isNotEmpty)
            Align(
              alignment: hasPhoto ? Alignment.bottomCenter : Alignment.center,
              child: Container(
                margin: EdgeInsets.fromLTRB(24, 0, 24, hasPhoto ? 64 : 0),
                padding: hasPhoto ? const EdgeInsets.all(10) : EdgeInsets.zero,
                decoration: hasPhoto ? BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)) : null,
                child: Text(post.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: hasPhoto ? 17 : 30, fontWeight: FontWeight.w700)),
              ),
            ),
          SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(children: [
                  for (var j = 0; j < widget.posts.length; j++)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        height: 3,
                        child: LinearProgressIndicator(
                          value: j < _i ? 1.0 : (j == _i ? (_progress > 1 ? 1.0 : _progress) : 0.0),
                          backgroundColor: Colors.white30,
                          valueColor: const AlwaysStoppedAnimation(Colors.white),
                        ),
                      ),
                    ),
                ]),
              ),
              ListTile(
                textColor: Colors.white,
                iconColor: Colors.white,
                title: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(DateFormat.jm('es').format(post.createdAt), style: const TextStyle(color: Colors.white70)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!post.isMine && !post.allowSave)
                    const Tooltip(message: 'Su autor no permite guardarlo', child: Icon(Icons.lock_outline)),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
