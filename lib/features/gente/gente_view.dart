import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/l10n.dart';
import '../chat/presentation/chat_avatar.dart';
import '../messaging/app_controller.dart';
import 'gente.dart';

const _rojo = Color(0xFFCE1126);
const _azul = Color(0xFF002D62);

// =====================================================================
// La pestaña: KLK Mi Gente
// =====================================================================

class GenteView extends ConsumerStatefulWidget {
  const GenteView({super.key});

  @override
  ConsumerState<GenteView> createState() => _GenteViewState();
}

class _GenteViewState extends ConsumerState<GenteView> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) ref.read(genteProvider).loadMore();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final g = ref.read(genteProvider);
      if (!g.loadedOnce) g.refresh();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(genteProvider);
    final cs = Theme.of(context).colorScheme;
    final posts = g.posts;
    final mine = g.myCountry;
    final bottom = MediaQuery.paddingOf(context).bottom + 100; // la barra de abajo flota encima

    return RefreshIndicator(
      onRefresh: g.refresh,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: bottom),
        itemCount: posts.length + 3,
        itemBuilder: (context, i) {
          if (i == 0) return const _ComposerCard();
          if (i == 1) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: Text(tr('🌎 Todo')),
                  selected: g.country.isEmpty,
                  onSelected: (_) => g.setCountry(''),
                ),
                if (mine.isNotEmpty)
                  ChoiceChip(
                    label: Text('${flagOf(mine)} ${tr('Mi país')}'),
                    selected: g.country == mine,
                    onSelected: (_) => g.setCountry(mine),
                  ),
                if (mine != 'DO')
                  ChoiceChip(
                    label: Text('🇩🇴 ${tr('RD')}'),
                    selected: g.country == 'DO',
                    onSelected: (_) => g.setCountry('DO'),
                  ),
              ]),
            );
          }
          if (i == posts.length + 2) {
            if (g.loading) {
              return const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator()));
            }
            if (g.error != null && posts.isEmpty) {
              return _Empty(
                icon: Icons.wifi_off_rounded,
                text: '${tr('No se pudo cargar Mi Gente')}.\n${g.error}',
                action: TextButton(onPressed: g.refresh, child: Text(tr('Reintentar'))),
              );
            }
            if (posts.isEmpty && g.loadedOnce) {
              return _Empty(
                icon: Icons.waving_hand_rounded,
                text: tr('Todavía no hay nada por aquí. ¡Sé el primero en saludar a tu gente!'),
              );
            }
            if (g.isDemo && posts.isNotEmpty) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Text(tr('Modo demo: estas publicaciones son de ejemplo.'),
                    textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
              );
            }
            return const SizedBox(height: 12);
          }
          return GentePostCard(post: posts[i - 2]);
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Empty({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
      child: Column(children: [
        Icon(icon, size: 52, color: cs.onSurface.withValues(alpha: 0.35)),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
        if (action != null) action!,
      ]),
    );
  }
}

/// "¿Qué hay, Ana?" arriba del muro.
class _ComposerCard extends ConsumerWidget {
  const _ComposerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final first = app.profile.name.trim().split(RegExp(r'\s+')).first;
    void open({bool photos = false}) => Navigator.of(context)
        .push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => GenteComposeScreen(pickPhotos: photos)));
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      elevation: 0,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(children: [
          ChatAvatar(id: 'me', title: app.profile.name, photoPath: app.profile.photoPath, radius: 20),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: open,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: Text(first.isEmpty ? tr('¿Qué hay de nuevo?') : '${tr('¿Qué hay')}, $first?',
                    style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
              ),
            ),
          ),
          IconButton(
            tooltip: tr('Publicar fotos'),
            onPressed: () => open(photos: true),
            icon: const Icon(Icons.photo_library_rounded, color: Color(0xFF1F7A4D)),
          ),
        ]),
      ),
    );
  }
}

// =====================================================================
// Foto de alguien y fotos de una publicación
// =====================================================================

class GenteAvatar extends ConsumerWidget {
  final GenteAuthor author;
  final double radius;
  const GenteAvatar({super.key, required this.author, this.radius = 20});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.read(appProvider);
    // Si es alguien de mis chats y tengo su foto, uso esa.
    final local = author.id == app.myId ? app.profile.photoPath : app.chatById(author.id)?.avatarPath;
    final fallback = ChatAvatar(id: author.id, title: author.displayName, photoPath: local, radius: radius);
    final url = ref.read(genteProvider).imageUrl(author.photo);
    if (url == null) return fallback;
    final px = (radius * 2 * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipOval(
      child: Image.network(
        url,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        cacheWidth: px,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (_, child, p) => p == null ? child : fallback,
      ),
    );
  }
}

class _NetPhoto extends ConsumerWidget {
  final String id;
  final BoxFit fit;
  const _NetPhoto(this.id, {this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final url = ref.read(genteProvider).imageUrl(id);
    final box = ColoredBox(color: cs.surfaceContainerHighest, child: const SizedBox.expand());
    if (url == null) return box;
    return Image.network(
      url,
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      loadingBuilder: (_, child, p) => p == null ? child : box,
      errorBuilder: (_, __, ___) => Container(
        color: cs.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.broken_image_outlined, color: cs.onSurface.withValues(alpha: 0.4)),
      ),
    );
  }
}

/// 1 foto grande; 2 lado a lado; 3 o 4 en cuadrícula.
class _PhotoGrid extends StatelessWidget {
  final List<String> photos;
  const _PhotoGrid({required this.photos});

  void _open(BuildContext context, int i) => Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PhotoViewer(photos: photos, initial: i),
      ));

  @override
  Widget build(BuildContext context) {
    Widget tile(int i) => GestureDetector(onTap: () => _open(context, i), child: _NetPhoto(photos[i]));
    const gap = 3.0;
    final n = photos.length;
    Widget body;
    if (n == 1) {
      body = AspectRatio(aspectRatio: 4 / 3, child: tile(0));
    } else if (n == 2) {
      body = AspectRatio(
        aspectRatio: 2,
        child: Row(children: [Expanded(child: tile(0)), const SizedBox(width: gap), Expanded(child: tile(1))]),
      );
    } else if (n == 3) {
      body = AspectRatio(
        aspectRatio: 4 / 3,
        child: Row(children: [
          Expanded(flex: 2, child: tile(0)),
          const SizedBox(width: gap),
          Expanded(
            child: Column(children: [Expanded(child: tile(1)), const SizedBox(height: gap), Expanded(child: tile(2))]),
          ),
        ]),
      );
    } else {
      body = AspectRatio(
        aspectRatio: 1,
        child: Column(children: [
          Expanded(
              child: Row(children: [Expanded(child: tile(0)), const SizedBox(width: gap), Expanded(child: tile(1))])),
          const SizedBox(height: gap),
          Expanded(
              child: Row(children: [Expanded(child: tile(2)), const SizedBox(width: gap), Expanded(child: tile(3))])),
        ]),
      );
    }
    return body;
  }
}

class _PhotoViewer extends StatefulWidget {
  final List<String> photos;
  final int initial;
  const _PhotoViewer({required this.photos, required this.initial});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final _page = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: widget.photos.length > 1
              ? Text('${_i + 1} / ${widget.photos.length}', style: const TextStyle(color: Colors.white))
              : null,
        ),
        body: PageView.builder(
          controller: _page,
          itemCount: widget.photos.length,
          onPageChanged: (i) => setState(() => _i = i),
          itemBuilder: (_, i) => InteractiveViewer(
            maxScale: 4,
            child: Center(child: _NetPhoto(widget.photos[i], fit: BoxFit.contain)),
          ),
        ),
      );
}

// =====================================================================
// Una publicación
// =====================================================================

Future<String?> askGenteReportReason(BuildContext context) => showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(tr('¿Por qué lo denuncias?'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          for (final (v, label) in [
            ('spam', tr('Spam o publicidad')),
            ('estafa', tr('Estafa o engaño')),
            ('acoso', tr('Acoso o amenazas')),
            ('ofensivo', tr('Contenido ofensivo o violento')),
            ('otro', tr('Otro motivo')),
          ])
            ListTile(title: Text(label), onTap: () => Navigator.pop(ctx, v)),
        ]),
      ),
    );

/// Las normas de Mi Gente: hay que aceptarlas antes de publicar o comentar
/// por primera vez (Apple lo pide para el contenido que suben los usuarios).
Future<bool> ensureGenteRules(BuildContext context, WidgetRef ref) async {
  final g = ref.read(genteProvider);
  if (g.rulesAccepted || g.isDemo) return true;
  final rules = [
    ('🤝', tr('Respeta a todos. Nada de acoso, amenazas, insultos ni discriminación.')),
    ('🚫', tr('Nada de contenido sexual, violento o ilegal.')),
    ('💸', tr('Nada de estafas, spam ni ventas engañosas.')),
    ('🔒', tr('No publiques datos personales ni fotos de otros sin su permiso.')),
    ('🛡️', tr('Lo que incumpla las normas se borra y la cuenta se puede bloquear. Tolerancia cero.')),
  ];
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Normas de KLK Mi Gente'), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(tr('Lo que publicas aquí lo ve la gente de KLK. Para que sea un sitio bonito para todos:'),
              style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.7))),
          const SizedBox(height: 10),
          for (final (e, t) in rules)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 12),
                Expanded(child: Text(t, style: const TextStyle(fontSize: 15))),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                final url = ref.read(appProvider).serverApi?.pageUrl('/normas');
                if (url != null) launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              },
              child: Text(tr('Leer las normas completas')),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _rojo, minimumSize: const Size.fromHeight(50)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Acepto las normas')),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Ahora no'))),
        ]),
      ),
    ),
  );
  if (ok != true) return false;
  await g.acceptRules();
  return true;
}

/// Pregunta y bloquea a alguien en Mi Gente. Devuelve true si lo bloqueó.
Future<bool> confirmGenteBlock(BuildContext context, WidgetRef ref, GenteAuthor a) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${tr('¿Bloquear a')} ${a.displayName}?'),
      content: Text(tr('No verás lo que publica, no verá lo tuyo y no podrá comentar ni dar me gusta a tus publicaciones. '
          'Puedes desbloquearlo cuando quieras.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _rojo),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Bloquear')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(genteProvider).block(a.id);
    messenger?.showSnackBar(SnackBar(content: Text('${a.displayName} ${tr('está bloqueado en Mi Gente')}')));
    return true;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('${tr('No se pudo bloquear')}: $e')));
    return false;
  }
}

class GentePostCard extends ConsumerWidget {
  final GentePost post;

  /// Dentro de la pantalla de comentarios: el texto entero y sin abrirla otra vez.
  final bool full;
  const GentePostCard({super.key, required this.post, this.full = false});

  void _say(BuildContext context, String t) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t)));

  Future<void> _menu(BuildContext context, WidgetRef ref, String action) async {
    final g = ref.read(genteProvider);
    switch (action) {
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('¿Borrar esta publicación?')),
            content: Text(tr('Se borra para todos, con sus fotos, me gusta y comentarios.')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Borrar'))),
            ],
          ),
        );
        if (ok != true || !context.mounted) return;
        try {
          await g.delete(post);
          if (context.mounted) {
            if (full) Navigator.of(context).pop();
            _say(context, tr('Publicación borrada'));
          }
        } catch (e) {
          if (context.mounted) _say(context, '${tr('No se pudo borrar')}: $e');
        }
      case 'report':
        final reason = await askGenteReportReason(context);
        if (reason == null || !context.mounted) return;
        try {
          await g.report(post, reason);
          if (context.mounted) _say(context, tr('Gracias. KLK revisará esta publicación.'));
        } catch (e) {
          if (context.mounted) _say(context, '${tr('No se pudo denunciar')}: $e');
        }
      case 'block':
        final done = await confirmGenteBlock(context, ref, post.author);
        if (done && full && context.mounted) Navigator.of(context).pop();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: post.text));
        if (context.mounted) _say(context, tr('Texto copiado'));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.read(appProvider);
    final cs = Theme.of(context).colorScheme;
    final mine = post.author.id == app.myId;
    final flag = flagOf(post.country);
    void openPost() {
      if (full) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => GentePostScreen(post: post)));
    }

    void openAuthor() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GenteAuthorScreen(author: post.author)));

    final long = !full && post.text.length > 320;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      elevation: 0,
      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 2, 6),
          child: Row(children: [
            GestureDetector(onTap: openAuthor, child: GenteAvatar(author: post.author)),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: openAuthor,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(post.author.displayName,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('${genteAgo(post.createdAt)}${flag.isEmpty ? '' : ' · $flag'}',
                      style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
                ]),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: tr('Más opciones'),
              icon: const Icon(Icons.more_horiz),
              onSelected: (v) => _menu(context, ref, v),
              itemBuilder: (_) => [
                if (post.text.isNotEmpty) PopupMenuItem(value: 'copy', child: Text(tr('Copiar texto'))),
                if (mine) PopupMenuItem(value: 'delete', child: Text(tr('Borrar publicación'))),
                if (!mine) PopupMenuItem(value: 'block', child: Text('${tr('Bloquear a')} ${post.author.displayName}')),
                if (!mine) PopupMenuItem(value: 'report', child: Text(tr('Denunciar'))),
              ],
            ),
          ]),
        ),
        if (post.text.isNotEmpty)
          InkWell(
            onTap: full ? null : openPost,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(long ? '${post.text.substring(0, 300).trimRight()}…' : post.text,
                    style: TextStyle(fontSize: post.text.length < 90 && post.photos.isEmpty ? 18 : 15.5, height: 1.35)),
                if (long)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(tr('Ver más'), style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary)),
                  ),
              ]),
            ),
          ),
        if (post.photos.isNotEmpty) _PhotoGrid(photos: post.photos),
        if (post.likes > 0 || post.comments > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Row(children: [
              if (post.likes > 0) ...[
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(color: _rojo, shape: BoxShape.circle),
                  child: const Icon(Icons.favorite_rounded, size: 11, color: Colors.white),
                ),
                const SizedBox(width: 5),
                Text('${post.likes}', style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.7))),
              ],
              const Spacer(),
              if (post.comments > 0)
                GestureDetector(
                  onTap: openPost,
                  child: Text(post.comments == 1 ? tr('1 comentario') : '${post.comments} ${tr('comentarios')}',
                      style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.7))),
                ),
            ]),
          ),
        const Divider(height: 14, indent: 12, endIndent: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Row(children: [
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: post.liked ? _rojo : cs.onSurface.withValues(alpha: 0.75)),
                onPressed: () async {
                  HapticFeedback.lightImpact();
                  try {
                    await ref.read(genteProvider).toggleLike(post);
                  } catch (e) {
                    if (context.mounted) _say(context, '${tr('No se pudo')}: $e');
                  }
                },
                icon: Icon(post.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                label: Text(tr('Me gusta')),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: cs.onSurface.withValues(alpha: 0.75)),
                onPressed: full ? null : openPost,
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: Text(tr('Comentar')),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// =====================================================================
// Una publicación con sus comentarios
// =====================================================================

class GentePostScreen extends ConsumerStatefulWidget {
  final GentePost post;
  const GentePostScreen({super.key, required this.post});

  @override
  ConsumerState<GentePostScreen> createState() => _GentePostScreenState();
}

class _GentePostScreenState extends ConsumerState<GentePostScreen> {
  final _text = TextEditingController();
  List<GenteComment>? _comments;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(genteProvider).comments(widget.post.id);
      if (!mounted) return;
      setState(() {
        _comments = list;
        _error = null;
      });
      ref.read(genteProvider).setCommentCount(widget.post.id, list.length);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    if (!await ensureGenteRules(context, ref) || !mounted) return;
    setState(() => _sending = true);
    try {
      final c = await ref.read(genteProvider).addComment(widget.post.id, t);
      if (!mounted) return;
      _text.clear();
      setState(() => _comments = [...?_comments, c]);
      ref.read(genteProvider).setCommentCount(widget.post.id, _comments!.length);
    } catch (e) {
      if (mounted) _say('${tr('No se pudo comentar')}: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _commentMenu(GenteComment c) async {
    final app = ref.read(appProvider);
    final g = ref.read(genteProvider);
    final post = g.byId(widget.post.id) ?? widget.post;
    final canDelete = c.author.id == app.myId || post.author.id == app.myId;
    final mineComment = c.author.id == app.myId;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: Text(tr('Copiar')),
            onTap: () => Navigator.pop(ctx, 'copy'),
          ),
          if (canDelete)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(tr('Borrar comentario')),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          if (!mineComment)
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text(tr('Denunciar')),
              onTap: () => Navigator.pop(ctx, 'report'),
            ),
          if (!mineComment)
            ListTile(
              leading: const Icon(Icons.block_rounded, color: Color(0xFFFF6B7A)),
              title: Text('${tr('Bloquear a')} ${c.author.displayName}', style: const TextStyle(color: Color(0xFFFF6B7A))),
              onTap: () => Navigator.pop(ctx, 'block'),
            ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: c.text));
      case 'delete':
        try {
          await g.deleteComment(c);
          if (!mounted) return;
          setState(() => _comments = _comments?.where((x) => x.id != c.id).toList());
          g.setCommentCount(widget.post.id, _comments?.length ?? 0);
        } catch (e) {
          if (mounted) _say('${tr('No se pudo borrar')}: $e');
        }
      case 'block':
        if (await confirmGenteBlock(context, ref, c.author) && mounted) {
          setState(() => _comments = _comments?.where((x) => x.author.id != c.author.id).toList());
        }
      case 'report':
        final reason = await askGenteReportReason(context);
        if (reason == null || !mounted) return;
        try {
          await g.reportComment(c, reason);
          if (mounted) _say(tr('Gracias. KLK revisará este comentario.'));
        } catch (e) {
          if (mounted) _say('${tr('No se pudo denunciar')}: $e');
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(genteProvider);
    final app = ref.read(appProvider);
    final cs = Theme.of(context).colorScheme;
    final post = g.byId(widget.post.id) ?? widget.post;
    final comments = _comments;
    return Scaffold(
      appBar: AppBar(title: Text(post.author.displayName)),
      body: Column(children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
              GentePostCard(post: post, full: true),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                child: Text(tr('Comentarios'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              if (comments == null && _error == null)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('${tr('No se pudieron cargar')}: $_error', textAlign: TextAlign.center),
                )
              else if (comments!.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(g.isDemo ? tr('En el modo demo no hay comentarios.') : tr('Sé el primero en comentar.'),
                      textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
                )
              else
                for (final c in comments)
                  InkWell(
                    onLongPress: () => _commentMenu(c),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        GestureDetector(
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => GenteAuthorScreen(author: c.author))),
                          child: GenteAvatar(author: c.author, radius: 17),
                        ),
                        const SizedBox(width: 9),
                        Flexible(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(c.author.id == app.myId ? '${c.author.displayName} (${tr('tú')})' : c.author.displayName,
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
                                const SizedBox(height: 2),
                                Text(c.text, style: const TextStyle(fontSize: 15)),
                              ]),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 10, top: 3),
                              child: Text(genteAgo(c.createdAt),
                                  style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.55))),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
            ]),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Row(children: [
              ChatAvatar(id: 'me', title: app.profile.name, photoPath: app.profile.photoPath, radius: 17),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 1000,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr('Escribe un comentario…'),
                    counterText: '',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22)),
                  ),
                ),
              ),
              IconButton(
                tooltip: tr('Enviar'),
                onPressed: _text.text.trim().isEmpty || _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Icon(Icons.send_rounded, color: _rojo),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// =====================================================================
// El muro de una persona
// =====================================================================

class GenteAuthorScreen extends ConsumerStatefulWidget {
  final GenteAuthor author;
  const GenteAuthorScreen({super.key, required this.author});

  @override
  ConsumerState<GenteAuthorScreen> createState() => _GenteAuthorScreenState();
}

class _GenteAuthorScreenState extends ConsumerState<GenteAuthorScreen> {
  List<GentePost>? _posts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(genteProvider).postsBy(widget.author.id);
      if (mounted) setState(() => _posts = list);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(genteProvider);
    final cs = Theme.of(context).colorScheme;
    final a = widget.author;
    // Si ya está en el muro, uso la versión de ahí (me gusta al día).
    final posts = [for (final p in _posts ?? const <GentePost>[]) g.byId(p.id) ?? p];
    final mine = a.id == ref.read(appProvider).myId;
    return Scaffold(
      appBar: AppBar(title: Text(a.displayName)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(colors: [_azul, _rojo], begin: Alignment.topLeft, end: Alignment.bottomRight),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: GenteAvatar(author: a, radius: 32),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.displayName,
                      style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)),
                  Text(_posts == null ? '' : '${posts.length} ${posts.length == 1 ? tr('publicación') : tr('publicaciones')}',
                      style: const TextStyle(color: Colors.white70)),
                ]),
              ),
            ]),
          ),
          if (!mine && g.hiddenAuthors.contains(a.id))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                Expanded(
                  child: Text(tr('Bloqueaste a esta persona en Mi Gente.'),
                      style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65))),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      await g.unblock(a.id);
                      await _load();
                      await g.refresh();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('No se pudo')}: $e')));
                      }
                    }
                  },
                  child: Text(tr('Desbloquear')),
                ),
              ]),
            )
          else if (!mine && !g.isDemo)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    if (await confirmGenteBlock(context, ref, a) && context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.block_rounded, size: 18),
                  label: Text(tr('Bloquear')),
                ),
              ),
            ),
          if (_posts == null && _error == null)
            const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Padding(padding: const EdgeInsets.all(20), child: Text('${tr('No se pudo cargar')}: $_error'))
          else if (posts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Text(tr('Todavía no ha publicado nada.'),
                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
            )
          else
            for (final p in posts) GentePostCard(post: p),
        ]),
      ),
    );
  }
}

// =====================================================================
// Publicar
// =====================================================================

class GenteComposeScreen extends ConsumerStatefulWidget {
  /// Abrir directamente la galería para elegir fotos.
  final bool pickPhotos;
  const GenteComposeScreen({super.key, this.pickPhotos = false});

  @override
  ConsumerState<GenteComposeScreen> createState() => _GenteComposeScreenState();
}

class _GenteComposeScreenState extends ConsumerState<GenteComposeScreen> {
  final _text = TextEditingController();
  final List<Uint8List> _photos = [];
  bool _sending = false;
  int _uploaded = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!await ensureGenteRules(context, ref)) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (widget.pickPhotos && mounted) _pick(ImageSource.gallery);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _pick(ImageSource source) async {
    final room = 4 - _photos.length;
    if (room <= 0) {
      _say(tr('Máximo 4 fotos por publicación.'));
      return;
    }
    try {
      final picker = ImagePicker();
      final List<XFile> files;
      if (source == ImageSource.gallery) {
        files = await picker.pickMultiImage(maxWidth: 1600, maxHeight: 1600, imageQuality: 80, limit: room > 1 ? room : null);
      } else {
        final x = await picker.pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
        files = x == null ? const [] : [x];
      }
      final bytes = <Uint8List>[];
      for (final f in files.take(room)) {
        bytes.add(await f.readAsBytes());
      }
      if (!mounted) return;
      if (files.length > room) _say(tr('Máximo 4 fotos por publicación.'));
      setState(() => _photos.addAll(bytes));
    } catch (_) {
      if (mounted) _say(tr('KLK no tiene permiso para tus fotos o la cámara. Actívalo en Ajustes del iPhone → KLK.'));
    }
  }

  Future<void> _publish() async {
    final text = _text.text.trim();
    if ((text.isEmpty && _photos.isEmpty) || _sending) return;
    if (!await ensureGenteRules(context, ref) || !mounted) return;
    setState(() {
      _sending = true;
      _uploaded = 0;
    });
    try {
      await ref.read(genteProvider).publish(text, _photos, onPhoto: (n) {
        if (mounted) setState(() => _uploaded = n);
      });
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) _say('${tr('No se pudo publicar')}: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final g = ref.read(genteProvider);
    final cs = Theme.of(context).colorScheme;
    final canSend = (_text.text.trim().isNotEmpty || _photos.isNotEmpty) && !_sending;
    final country = g.myCountry;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Publicar en Mi Gente')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _rojo),
              onPressed: canSend ? _publish : null,
              child: _sending
                  ? Text(_photos.isEmpty ? tr('Publicando…') : '${tr('Subiendo')} $_uploaded/${_photos.length}…')
                  : Text(tr('Publicar')),
            ),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Row(children: [
          ChatAvatar(id: 'me', title: app.profile.name, photoPath: app.profile.photoPath, radius: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.profile.name.trim().isEmpty ? tr('Tú') : app.profile.name.trim(),
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              Text('🌎 ${tr('Público para la gente de KLK')}${country.isEmpty ? '' : ' · ${flagOf(country)}'}',
                  style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
            ]),
          ),
        ]),
        if (app.profile.name.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(tr('Consejo: pon tu nombre en Ajustes para que tu gente sepa quién eres.'),
                style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.65))),
          ),
        TextField(
          controller: _text,
          autofocus: false,
          minLines: 4,
          maxLines: 12,
          maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(hintText: tr('¿Qué quieres contarle a tu gente?'), border: InputBorder.none),
        ),
        if (_photos.isNotEmpty)
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < _photos.length; i++)
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(_photos[i], width: 104, height: 104, fit: BoxFit.cover, cacheWidth: 312),
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: GestureDetector(
                    onTap: _sending ? null : () => setState(() => _photos.removeAt(i)),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ]),
          ]),
        const SizedBox(height: 14),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _sending || _photos.length >= 4 ? null : () => _pick(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(tr('Fotos')),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _sending || _photos.length >= 4 ? null : () => _pick(ImageSource.camera),
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(tr('Cámara')),
          ),
          const Spacer(),
          Text('${_photos.length}/4', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.55))),
        ]),
        const SizedBox(height: 18),
        Text(
          tr('Lo que publicas aquí lo puede ver cualquiera que use KLK (no va cifrado como tus chats). '
              'No publiques datos personales. Lo que incumpla las normas se borra.'),
          style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6)),
        ),
      ]),
    );
  }
}
