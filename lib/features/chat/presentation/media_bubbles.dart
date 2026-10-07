import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../messaging/models.dart';
import '../../messaging/stickers.dart';

/// Contenido multimedia dentro de una burbuja.
class MediaContent extends StatelessWidget {
  final Message message;
  final Color fg;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenViewOnce;
  const MediaContent({super.key, required this.message, required this.fg, this.onRetry, this.onOpenViewOnce});

  @override
  Widget build(BuildContext context) {
    final media = message.media!;
    final path = media.localPath;

    if (media.viewOnce) {
      return _ViewOnceTile(
        media: media,
        fg: fg,
        mine: message.isMine,
        onOpen: (!message.isMine && !media.opened && path != null) ? onOpenViewOnce : null,
        downloading: !message.isMine && !media.opened && path == null,
      );
    }
    if (media.hasFile && path == null) {
      return _Downloading(media: media, fg: fg, onRetry: onRetry);
    }

    return switch (media.type) {
      MediaType.image => _ImageThumb(path: path!),
      MediaType.video => _VideoThumb(path: path!, durationMs: media.durationMs),
      MediaType.audio => VoiceNotePlayer(path: path!, fg: fg, durationMs: media.durationMs),
      MediaType.file => _FileTile(media: media, fg: fg),
      MediaType.location => _LocationCard(lat: media.lat ?? 0, lng: media.lng ?? 0, fg: fg),
      MediaType.sticker => Image.asset(stickerAsset(media.name), width: 150, height: 150),
      MediaType.trip => _TripCard(media: media, fg: fg),
    };
  }
}

// ---------- Ver una vez ----------

class _ViewOnceTile extends StatelessWidget {
  final MessageMedia media;
  final Color fg;
  final bool mine;
  final bool downloading;
  final VoidCallback? onOpen;
  const _ViewOnceTile({required this.media, required this.fg, required this.mine, required this.downloading, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final isVideo = media.type == MediaType.video;
    final text = mine
        ? (isVideo ? 'Vídeo de ver una vez' : 'Foto de ver una vez')
        : media.opened
            ? 'Abierta'
            : downloading
                ? 'Descargando…'
                : (isVideo ? 'Ver vídeo · una vez' : 'Ver foto · una vez');
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 210,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: fg, width: 2)),
            alignment: Alignment.center,
            child: media.opened
                ? Icon(Icons.check, size: 18, color: fg)
                : Text('1', style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }
}

/// Pantalla de "ver una vez": al cerrarla, la foto se borra del móvil.
class ViewOnceViewer extends StatelessWidget {
  final MessageMedia media;
  const ViewOnceViewer({super.key, required this.media});

  @override
  Widget build(BuildContext context) => media.type == MediaType.video
      ? VideoViewer(path: media.localPath!)
      : Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Ver una vez', style: TextStyle(fontSize: 16)),
        ),
        body: Center(child: InteractiveViewer(child: Image.file(File(media.localPath!)))),
        bottomNavigationBar: const SafeArea(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Al cerrar, se borrará de este móvil para siempre.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
          ),
        ),
      );
}

// ---------- Viaje ("Bajando pa' RD") ----------

class _TripCard extends StatelessWidget {
  final MessageMedia media;
  final Color fg;
  const _TripCard({required this.media, required this.fg});

  @override
  Widget build(BuildContext context) {
    final date = media.tripDate;
    final days = date == null ? null : date.difference(DateTime.now()).inDays;
    return Container(
      width: 240,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: fg.withValues(alpha: 0.08)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF002D62), Color(0xFFCE1126)]),
          ),
          child: Row(children: [
            const Icon(Icons.flight_takeoff, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text("¡Bajando pa' ${media.tripTo ?? 'RD'}!",
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            const Text('🇩🇴', style: TextStyle(fontSize: 18)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (media.tripFrom != null && media.tripFrom!.isNotEmpty)
              Text('Desde ${media.tripFrom}', style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
            if (date != null)
              Text(
                '${DateFormat.yMMMMd('es').format(date)}'
                '${days != null && days >= 0 ? ' · ${days == 0 ? '¡hoy!' : 'en $days días'}' : ''}',
                style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 13),
              ),
            const SizedBox(height: 6),
            Text('¿Necesitan que les lleve algo?', style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}

class _Downloading extends StatelessWidget {
  final MessageMedia media;
  final Color fg;
  final VoidCallback? onRetry;
  const _Downloading({required this.media, required this.fg, this.onRetry});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onRetry,
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: fg.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg)),
            const SizedBox(width: 12),
            Expanded(child: Text('Descargando ${media.label}…', style: TextStyle(color: fg, fontSize: 13.5))),
          ]),
        ),
      );
}

// ---------- Foto ----------

class _ImageThumb extends StatelessWidget {
  final String path;
  const _ImageThumb({required this.path});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageViewer(path: path))),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320, minWidth: 120, minHeight: 80),
            child: Hero(tag: path, child: Image.file(File(path), fit: BoxFit.cover)),
          ),
        ),
      );
}

class ImageViewer extends StatelessWidget {
  final String path;
  const ImageViewer({super.key, required this.path});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: Hero(tag: path, child: Image.file(File(path))),
          ),
        ),
      );
}

// ---------- Vídeo ----------

class _VideoThumb extends StatelessWidget {
  final String path;
  final int? durationMs;
  const _VideoThumb({required this.path, this.durationMs});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoViewer(path: path))),
        child: Container(
          width: 240,
          height: 150,
          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
          child: Stack(alignment: Alignment.center, children: [
            const Icon(Icons.play_circle_fill, size: 56, color: Colors.white),
            Positioned(
              left: 10,
              bottom: 8,
              child: Row(children: [
                const Icon(Icons.videocam, size: 16, color: Colors.white70),
                const SizedBox(width: 4),
                Text(durationMs == null ? 'Vídeo' : formatDuration(durationMs!),
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ]),
            ),
          ]),
        ),
      );
}

class VideoViewer extends StatefulWidget {
  final String path;
  const VideoViewer({super.key, required this.path});

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  late final VideoPlayerController _c = VideoPlayerController.file(File(widget.path));

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (mounted) {
        setState(() {});
        _c.play();
      }
    });
    _c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        body: Center(
          child: _c.value.isInitialized
              ? GestureDetector(
                  onTap: () => _c.value.isPlaying ? _c.pause() : _c.play(),
                  child: AspectRatio(
                    aspectRatio: _c.value.aspectRatio,
                    child: Stack(alignment: Alignment.center, children: [
                      VideoPlayer(_c),
                      if (!_c.value.isPlaying) const Icon(Icons.play_arrow, size: 72, color: Colors.white),
                      Positioned(left: 0, right: 0, bottom: 0, child: VideoProgressIndicator(_c, allowScrubbing: true)),
                    ]),
                  ),
                )
              : const CircularProgressIndicator(color: Colors.white),
        ),
      );
}

// ---------- Nota de voz ----------

class VoiceNotePlayer extends StatefulWidget {
  final String path;
  final Color fg;
  final int? durationMs;
  const VoiceNotePlayer({super.key, required this.path, required this.fg, this.durationMs});

  @override
  State<VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<VoiceNotePlayer> {
  final _player = AudioPlayer();
  Duration _pos = Duration.zero;
  Duration? _dur;
  bool _playing = false;
  bool _loaded = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    if (widget.durationMs != null) _dur = Duration(milliseconds: widget.durationMs!);
    _subs.add(_player.positionStream.listen((p) => setState(() => _pos = p)));
    _subs.add(_player.playerStateStream.listen((s) {
      setState(() => _playing = s.playing && s.processingState != ProcessingState.completed);
      if (s.processingState == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    if (!_loaded) {
      final d = await _player.setFilePath(widget.path);
      _loaded = true;
      if (d != null) setState(() => _dur = d);
    }
    await _player.play();
  }

  @override
  Widget build(BuildContext context) {
    final total = _dur ?? Duration.zero;
    final progress = total.inMilliseconds == 0 ? 0.0 : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return SizedBox(
      width: 230,
      child: Row(children: [
        IconButton(
          onPressed: _toggle,
          icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 40, color: widget.fg),
          padding: EdgeInsets.zero,
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: progress,
                activeColor: widget.fg,
                inactiveColor: widget.fg.withValues(alpha: 0.3),
                onChanged: total == Duration.zero
                    ? null
                    : (v) => _player.seek(Duration(milliseconds: (v * total.inMilliseconds).round())),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              formatDuration((_playing || _pos > Duration.zero ? _pos : total).inMilliseconds),
              style: TextStyle(color: widget.fg.withValues(alpha: 0.7), fontSize: 11.5),
            ),
          ]),
        ),
        Icon(Icons.mic, size: 18, color: widget.fg.withValues(alpha: 0.6)),
      ]),
    );
  }
}

// ---------- Documento ----------

class _FileTile extends StatelessWidget {
  final MessageMedia media;
  final Color fg;
  const _FileTile({required this.media, required this.fg});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => OpenFilex.open(media.localPath!),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 240,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: fg.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Icon(Icons.insert_drive_file, size: 34, color: fg),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(media.name ?? 'Documento',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                if (media.size != null)
                  Text(formatBytes(media.size!), style: TextStyle(color: fg.withValues(alpha: 0.65), fontSize: 12)),
              ]),
            ),
          ]),
        ),
      );
}

// ---------- Ubicación ----------

class _LocationCard extends StatelessWidget {
  final double lat, lng;
  final Color fg;
  const _LocationCard({required this.lat, required this.lng, required this.fg});

  Future<void> _open() async {
    final apple = Uri.parse('https://maps.apple.com/?q=$lat,$lng');
    final google = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    final url = Platform.isIOS ? apple : google;
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: _open,
        child: Container(
          width: 240,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: fg.withValues(alpha: 0.08)),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              height: 110,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF7FC8A9), Color(0xFF9BD3E6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(Icons.location_on, size: 48, color: Color(0xFFCE1126)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Ubicación', style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
                Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)} · Toca para abrir el mapa',
                    style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12)),
              ]),
            ),
          ]),
        ),
      );
}
