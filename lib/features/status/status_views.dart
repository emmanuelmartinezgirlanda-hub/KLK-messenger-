import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:klk_native/klk_native.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

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

/// Duración máxima de un estado de vídeo. En el iPhone se comprime antes de subirlo.
const maxStatusVideo = Duration(minutes: 10);

/// Límite de subida del servidor (64 MB).
const _maxUploadBytes = 64 * 1024 * 1024;

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
  String? _media; // foto o vídeo elegido
  bool _isVideo = false;
  bool _posting = false;
  bool _preparing = false; // comprimiendo un vídeo

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _say(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickMedia() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Foto de la galería'),
            onTap: () => Navigator.pop(ctx, 'photo'),
          ),
          ListTile(
            leading: const Icon(Icons.video_library_outlined),
            title: const Text('Vídeo de la galería'),
            subtitle: const Text('Hasta 10 minutos'),
            onTap: () => Navigator.pop(ctx, 'video'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Hacer una foto'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('Grabar un vídeo'),
            subtitle: const Text('Hasta 10 minutos'),
            onTap: () => Navigator.pop(ctx, 'record'),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    final picker = ImagePicker();
    try {
      XFile? x;
      final video = choice == 'video' || choice == 'record';
      if (video) {
        x = await picker.pickVideo(
          source: choice == 'record' ? ImageSource.camera : ImageSource.gallery,
          maxDuration: maxStatusVideo,
        );
      } else {
        x = await picker.pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1600,
          imageQuality: 85,
        );
      }
      if (x == null) return;
      var path = x.path;
      if (video) {
        // Los vídeos largos se comprimen en el móvil para que quepan
        setState(() => _preparing = true);
        try {
          path = await KlkNative.compressVideo(path);
        } catch (e) {
          _say(e.toString());
        } finally {
          if (mounted) setState(() => _preparing = false);
        }
        if (await File(path).length() > _maxUploadBytes) {
          _say('Ese vídeo pesa demasiado aun comprimido (máx. 64 MB). Prueba con uno más corto.');
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _media = path;
        _isVideo = video;
      });
    } catch (_) {
      _say('KLK no tiene permiso para tus fotos o la cámara. Actívalo en Ajustes del iPhone → KLK.');
    }
  }

  Future<void> _post() async {
    if (_text.text.trim().isEmpty && _media == null) return;
    setState(() => _posting = true);
    await ref.read(appProvider).postStatus(text: _text.text.trim(), color: _color, mediaSourcePath: _media);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final canPost = (_text.text.trim().isNotEmpty || _media != null) && !_posting && !_preparing;
    final media = _media;
    return Scaffold(
      backgroundColor: media != null ? Colors.black : Color(_color),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(tooltip: 'Foto o vídeo', icon: const Icon(Icons.perm_media_outlined), onPressed: _pickMedia),
          if (media == null)
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
              child: media != null
                  ? Stack(alignment: Alignment.topRight, children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: _isVideo
                              ? StatusVideo(key: ValueKey(media), path: media, loop: true)
                              : Image.file(File(media)),
                        ),
                      ),
                      IconButton(
                        onPressed: () => setState(() {
                          _media = null;
                          _isVideo = false;
                        }),
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
          if (media != null)
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
                  fillColor: Colors.white12,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                child: Text(
                    _preparing
                        ? 'Preparando el vídeo…'
                        : _isVideo
                            ? 'Vídeo de hasta 10 min · lo verán tus contactos durante 24 horas'
                            : 'Lo verán tus contactos durante 24 horas',
                    style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              ),
              FloatingActionButton(
                onPressed: canPost ? _post : null,
                backgroundColor: canPost ? Colors.white : Colors.white38,
                foregroundColor: media != null ? Colors.black : Color(_color),
                child: _posting ? const CircularProgressIndicator() : const Icon(Icons.send),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Vídeo de un estado. En el editor se repite; en el visor avisa al terminar.
class StatusVideo extends StatefulWidget {
  final String path;
  final bool loop;
  final void Function(VideoPlayerController c)? onReady;
  const StatusVideo({super.key, required this.path, this.loop = false, this.onReady});

  @override
  State<StatusVideo> createState() => _StatusVideoState();
}

class _StatusVideoState extends State<StatusVideo> {
  late final VideoPlayerController _c = VideoPlayerController.file(File(widget.path));
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _c.setLooping(widget.loop);
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _c.play();
      widget.onReady?.call(_c);
    }).catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No se pudo reproducir este vídeo', style: TextStyle(color: Colors.white70)),
      );
    }
    if (!_c.value.isInitialized) {
      return const SizedBox(width: 48, height: 48, child: CircularProgressIndicator(color: Colors.white));
    }
    return AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c));
  }
}

// ---------- Ver estados ----------

/// Visor a pantalla completa: los de texto y foto duran 5 s y los vídeos lo
/// que dure el vídeo (máx. 30 s). Tocar a la derecha pasa al siguiente y a la
/// izquierda vuelve al anterior; mantener pulsado pausa.
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
  VideoPlayerController? _video; // lo maneja StatusVideo; aquí solo se lee
  static const _duration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    // Empieza por el primero sin ver
    final first = widget.posts.indexWhere((p) => !p.viewed);
    _i = first < 0 ? 0 : first;
    _start();
  }

  bool _playable(StatusPost p) => p.isVideo && p.mediaPath != null && File(p.mediaPath!).existsSync();

  void _start() {
    _timer?.cancel();
    _video = null;
    _progress = 0;
    final post = widget.posts[_i];
    if (!post.isMine && !post.viewed) ref.read(appProvider).markStatusViewed(post.id);
    // Los vídeos avanzan con el vídeo (ver _tickVideo); el resto con el reloj
    if (_playable(post)) return;
    _resumeClock();
  }

  void _resumeClock() {
    const tick = Duration(milliseconds: 50);
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) {
      setState(() => _progress += tick.inMilliseconds / _duration.inMilliseconds);
      if (_progress >= 1) _next();
    });
  }

  void _onVideoReady(VideoPlayerController c) {
    _video = c;
    c.addListener(_tickVideo);
  }

  void _tickVideo() {
    final c = _video;
    if (c == null || !mounted || !c.value.isInitialized) return;
    final total = c.value.duration < maxStatusVideo ? c.value.duration : maxStatusVideo;
    if (total.inMilliseconds <= 0) return;
    final p = c.value.position.inMilliseconds / total.inMilliseconds;
    setState(() => _progress = p);
    final ended = !c.value.isPlaying && c.value.position >= c.value.duration;
    if (p >= 1 || ended) {
      c.removeListener(_tickVideo);
      _next();
    }
  }

  void _pause() {
    _timer?.cancel();
    _video?.pause();
  }

  void _resume() {
    if (_video != null) {
      _video!.play();
    } else if (!_playable(widget.posts[_i])) {
      _resumeClock();
    }
  }

  void _next() {
    _video?.removeListener(_tickVideo);
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
    _video?.removeListener(_tickVideo);
    setState(() => _i--);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _video?.removeListener(_tickVideo);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.posts[_i];
    final hasFile = post.mediaPath != null && File(post.mediaPath!).existsSync();
    final isVideo = hasFile && post.isVideo;
    return Scaffold(
      backgroundColor: hasFile ? Colors.black : Color(post.color),
      body: GestureDetector(
        onTapUp: (d) {
          if (d.globalPosition.dx < MediaQuery.sizeOf(context).width / 3) {
            _prev();
          } else {
            _next();
          }
        },
        onLongPressStart: (_) => _pause(),
        onLongPressEnd: (_) => _resume(),
        child: Stack(fit: StackFit.expand, children: [
          if (isVideo)
            Center(child: StatusVideo(key: ValueKey(post.id), path: post.mediaPath!, onReady: _onVideoReady))
          else if (hasFile)
            Image.file(File(post.mediaPath!), fit: BoxFit.contain),
          if (post.text.isNotEmpty)
            Align(
              alignment: hasFile ? Alignment.bottomCenter : Alignment.center,
              child: Container(
                margin: EdgeInsets.fromLTRB(24, 0, 24, hasFile ? 64 : 0),
                padding: hasFile ? const EdgeInsets.all(10) : EdgeInsets.zero,
                decoration: hasFile ? BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(10)) : null,
                child: Text(post.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: hasFile ? 17 : 30, fontWeight: FontWeight.w700)),
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
                  if (isVideo) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.videocam_outlined)),
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
