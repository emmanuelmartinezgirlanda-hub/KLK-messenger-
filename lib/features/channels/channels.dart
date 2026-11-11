import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/l10n/l10n.dart';
import '../../core/network/api_client.dart';
import '../../core/util/share.dart';
import '../messaging/app_controller.dart';

/// Canales: alguien publica (noticias, un negocio, un artista, la iglesia…)
/// y quien lo sigue lo lee. Son públicos: no van cifrados de punta a punta.

class KChannel {
  KChannel(this.j);
  final Map<String, dynamic> j;
  String get id => j['id'] as String;
  String get name => j['name'] as String? ?? '';
  String get description => j['description'] as String? ?? '';
  String get emoji => j['emoji'] as String? ?? '📢';
  int get logoV => (j['logoV'] as num?)?.toInt() ?? 0;
  int get followers => (j['followers'] as num?)?.toInt() ?? 0;
  bool get following => j['following'] == true;
  bool get mine => j['mine'] == true;
  Map<String, dynamic>? get lastPost => j['lastPost'] as Map<String, dynamic>?;
}

class KChanPost {
  KChanPost(this.j);
  final Map<String, dynamic> j;
  String get id => j['id'] as String;
  String get body => j['body'] as String? ?? '';
  bool get hasImage => j['hasImage'] == true;
  DateTime get at => DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now();
}

String _followers(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)} M ${tr('seguidores')}';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)} mil ${tr('seguidores')}';
  return '$n ${n == 1 ? tr('seguidor') : tr('seguidores')}';
}

String _ago(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return tr('ahora');
  if (diff.inHours < 1) return '${diff.inMinutes} min';
  if (diff.inDays < 1) return '${diff.inHours} h';
  if (diff.inDays < 7) return '${diff.inDays} d';
  return '${d.day}/${d.month}/${d.year % 100}';
}

ApiClient? _api(WidgetRef ref) => ref.read(appProvider).serverApi;

String _err(Object e) => e is ApiException ? e.message : tr('No hay conexión. Inténtalo otra vez.');

Widget _emojiAvatar(KChannel c, {double radius = 24}) => _ChannelAvatar(c: c, radius: radius);

final _logoCache = <String, Uint8List>{};

/// La foto del canal: su logo si tiene; si no, su emoji.
class _ChannelAvatar extends ConsumerStatefulWidget {
  const _ChannelAvatar({required this.c, required this.radius, this.local});
  final KChannel c;
  final double radius;
  final Uint8List? local; // logo recién elegido (aún sin subir)

  @override
  ConsumerState<_ChannelAvatar> createState() => _ChannelAvatarState();
}

class _ChannelAvatarState extends ConsumerState<_ChannelAvatar> {
  Uint8List? _img;
  String get _key => '${widget.c.id}@${widget.c.logoV}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ChannelAvatar old) {
    super.didUpdateWidget(old);
    if (old.c.id != widget.c.id || old.c.logoV != widget.c.logoV) _load();
  }

  Future<void> _load() async {
    if (widget.c.logoV <= 0) {
      if (mounted) setState(() => _img = null);
      return;
    }
    final cached = _logoCache[_key];
    if (cached != null) {
      setState(() => _img = cached);
      return;
    }
    final api = _api(ref);
    if (api == null) return;
    try {
      final b = Uint8List.fromList(await api.bytes('/v1/channels/${widget.c.id}/logo?v=${widget.c.logoV}'));
      _logoCache[_key] = b;
      if (mounted) setState(() => _img = b);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final img = widget.local ?? _img;
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: const Color(0xFF002D62).withValues(alpha: 0.12),
      backgroundImage: img != null ? MemoryImage(img) : null,
      child: img != null ? null : Text(widget.c.emoji, style: TextStyle(fontSize: widget.radius * 0.95)),
    );
  }
}

/// Elige una foto de la galería, cuadrada y pequeña, para el logo.
Future<Uint8List?> _pickLogo(BuildContext context) async {
  try {
    var x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 82);
    if (x == null) return null;
    var b = await x.readAsBytes();
    if (b.length > 390 * 1024) {
      x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 320, maxHeight: 320, imageQuality: 65);
      if (x == null) return null;
      b = await x.readAsBytes();
    }
    return b.length > 390 * 1024 ? null : b;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('KLK no tiene permiso para tus fotos. Actívalo en Ajustes → KLK.'))));
    }
    return null;
  }
}

/// Sección «Canales» para la pestaña de Estados (como en WhatsApp «Novedades»).
class ChannelsSection extends ConsumerStatefulWidget {
  const ChannelsSection({super.key});

  @override
  ConsumerState<ChannelsSection> createState() => _ChannelsSectionState();
}

class _ChannelsSectionState extends ConsumerState<ChannelsSection> {
  List<KChannel>? _mine;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = _api(ref);
    if (api == null) {
      if (mounted) setState(() => _mine = []);
      return;
    }
    try {
      final j = await api.json('GET', '/v1/channels?mine=1') as Map<String, dynamic>;
      final list = (j['channels'] as List).map((e) => KChannel(e as Map<String, dynamic>)).toList();
      if (mounted) setState(() => _mine = list);
    } catch (_) {
      if (mounted) setState(() => _mine ??= []);
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mine = _mine;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(height: 32),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
        child: Row(children: [
          Expanded(
              child: Text(tr('Canales'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
          TextButton.icon(
            onPressed: () => _open(const ChannelsDirectoryScreen()),
            icon: const Icon(Icons.explore_outlined, size: 20),
            label: Text(tr('Buscar')),
          ),
        ]),
      ),
      if (mine == null)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
      else if (mine.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Sigue canales de noticias, negocios, artistas y más. O crea el tuyo.'),
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.tonal(
                  onPressed: () => _open(const ChannelsDirectoryScreen()), child: Text(tr('Ver canales'))),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => _open(const CreateChannelScreen()), child: Text(tr('Crear canal'))),
            ]),
          ]),
        )
      else
        for (final c in mine)
          ListTile(
            leading: _emojiAvatar(c),
            title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              c.lastPost == null
                  ? _followers(c.followers)
                  : '${(c.lastPost!['hasImage'] == true) ? '📷 ' : ''}${c.lastPost!['body'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: c.lastPost == null
                ? null
                : Text(_ago(KChanPost(c.lastPost!).at), style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            onTap: () => _open(ChannelScreen(channel: c)),
          ),
    ]);
  }
}

/// Buscar y descubrir canales.
class ChannelsDirectoryScreen extends ConsumerStatefulWidget {
  const ChannelsDirectoryScreen({super.key});

  @override
  ConsumerState<ChannelsDirectoryScreen> createState() => _ChannelsDirectoryScreenState();
}

class _ChannelsDirectoryScreenState extends ConsumerState<ChannelsDirectoryScreen> {
  final _q = TextEditingController();
  List<KChannel>? _list;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final api = _api(ref);
    if (api == null) {
      setState(() => _error = tr('Entra con tu cuenta para ver los canales.'));
      return;
    }
    final seq = ++_seq;
    try {
      final j = await api.json('GET', '/v1/channels?q=${Uri.encodeQueryComponent(_q.text.trim())}')
          as Map<String, dynamic>;
      if (seq != _seq || !mounted) return;
      setState(() {
        _error = null;
        _list = (j['channels'] as List).map((e) => KChannel(e as Map<String, dynamic>)).toList();
      });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _follow(KChannel c) async {
    final api = _api(ref);
    if (api == null) return;
    HapticFeedback.selectionClick();
    try {
      await api.json(c.following ? 'DELETE' : 'POST', '/v1/channels/${c.id}/follow');
      setState(() {
        c.j['following'] = !c.following;
        c.j['followers'] = c.followers + (c.following ? 1 : -1);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Canales'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateChannelScreen()));
          _search();
        },
        icon: const Icon(Icons.add),
        label: Text(tr('Crear canal')),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _q,
            onChanged: (_) => Future.delayed(const Duration(milliseconds: 300), _search),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: tr('Buscar canales'),
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
            ),
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
              : list == null
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                                _q.text.isEmpty
                                    ? tr('Aún no hay canales. ¡Crea el primero!')
                                    : tr('No encontré canales con ese nombre.'),
                                textAlign: TextAlign.center),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 90),
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final c = list[i];
                            return ListTile(
                              leading: _emojiAvatar(c),
                              title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                  c.description.isEmpty ? _followers(c.followers) : '${_followers(c.followers)} · ${c.description}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              trailing: c.mine
                                  ? Chip(label: Text(tr('Tuyo')))
                                  : c.following
                                      ? OutlinedButton(onPressed: () => _follow(c), child: Text(tr('Siguiendo')))
                                      : FilledButton(onPressed: () => _follow(c), child: Text(tr('Seguir'))),
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => ChannelScreen(channel: c)));
                                _search();
                              },
                            );
                          },
                        ),
        ),
      ]),
    );
  }
}

/// Crear (o editar) un canal.
class CreateChannelScreen extends ConsumerStatefulWidget {
  const CreateChannelScreen({super.key, this.edit});
  final KChannel? edit;

  @override
  ConsumerState<CreateChannelScreen> createState() => _CreateChannelScreenState();
}

class _CreateChannelScreenState extends ConsumerState<CreateChannelScreen> {
  late final _name = TextEditingController(text: widget.edit?.name ?? '');
  late final _desc = TextEditingController(text: widget.edit?.description ?? '');
  late String _emoji = widget.edit?.emoji ?? '📢';
  Uint8List? _logo; // nuevo logo elegido
  bool _removeLogo = false;
  bool _busy = false;
  String? _error;

  static const _emojis = ['📢', '🇩🇴', '📰', '⚾', '🎵', '🙏', '🍽️', '💈', '🛍️', '💼', '🏝️', '😂', '⚽', '🏀', '📚', '❤️'];

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final api = _api(ref);
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = {'name': _name.text.trim(), 'description': _desc.text.trim(), 'emoji': _emoji};
      final j = widget.edit == null
          ? await api.json('POST', '/v1/channels', body) as Map<String, dynamic>
          : await api.json('PUT', '/v1/channels/${widget.edit!.id}', body) as Map<String, dynamic>;
      final c = KChannel(j);
      // Logo: subir el nuevo o quitar el que había.
      if (_logo != null) {
        final r = await api.json('PUT', '/v1/channels/${c.id}/logo', {'image': base64Encode(_logo!)}) as Map<String, dynamic>;
        c.j['logoV'] = r['logoV'];
        _logoCache['${c.id}@${r['logoV']}'] = _logo!;
      } else if (_removeLogo && (widget.edit?.logoV ?? 0) > 0) {
        await api.json('DELETE', '/v1/channels/${c.id}/logo');
        c.j['logoV'] = 0;
      }
      if (!mounted) return;
      if (widget.edit == null) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChannelScreen(channel: c)));
      } else {
        Navigator.of(context).pop(c);
      }
    } catch (e) {
      setState(() => _error = _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.edit == null ? tr('Crear canal') : tr('Editar canal'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(
          child: _logo != null || (!_removeLogo && (widget.edit?.logoV ?? 0) > 0)
              ? _ChannelAvatar(c: widget.edit ?? KChannel({'id': '', 'emoji': _emoji}), radius: 52, local: _logo)
              : Text(_emoji, style: const TextStyle(fontSize: 64)),
        ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final b = await _pickLogo(context);
                    if (b != null) {
                      setState(() {
                        _logo = b;
                        _removeLogo = false;
                      });
                    }
                  },
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_logo != null || (!_removeLogo && (widget.edit?.logoV ?? 0) > 0) ? tr('Cambiar logo') : tr('Poner mi logo')),
          ),
          if (_logo != null || (!_removeLogo && (widget.edit?.logoV ?? 0) > 0))
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _logo = null;
                        _removeLogo = true;
                      }),
              child: Text(tr('Quitar')),
            ),
        ]),
        Center(
          child: Text(tr('Sin logo, el canal sale con el emoji que elijas abajo.'),
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 10),
        Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: [
          for (final e in _emojis)
            ChoiceChip(
              label: Text(e, style: const TextStyle(fontSize: 20)),
              selected: e == _emoji,
              onSelected: (_) => setState(() => _emoji = e),
            ),
        ]),
        const SizedBox(height: 20),
        TextField(
          controller: _name,
          maxLength: 60,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: tr('Nombre del canal'), hintText: tr('Noticias de mi barrio, Barbería El Primo…')),
        ),
        TextField(
          controller: _desc,
          maxLength: 300,
          maxLines: 3,
          decoration: InputDecoration(labelText: tr('Descripción (opcional)')),
        ),
        const SizedBox(height: 8),
        Text(tr('Cualquiera puede encontrar tu canal y seguirlo. Solo tú publicas. Tus seguidores no ven tu número.'),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
        if (_error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: cs.error))),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _name.text.trim().length < 2 ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.edit == null ? tr('Crear canal') : tr('Guardar')),
        ),
      ]),
    );
  }
}

final _imageCache = <String, Uint8List>{};

/// Un canal: sus publicaciones; si es mío, escribo abajo.
class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({super.key, required this.channel});
  final KChannel channel;

  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  late KChannel _c = widget.channel;
  List<KChanPost>? _posts;
  String? _error;
  final _text = TextEditingController();
  Uint8List? _photo;
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
    final api = _api(ref);
    if (api == null) return;
    try {
      final c = await api.json('GET', '/v1/channels/${_c.id}') as Map<String, dynamic>;
      final j = await api.json('GET', '/v1/channels/${_c.id}/posts') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _c = KChannel(c);
        _posts = (j['posts'] as List).map((e) => KChanPost(e as Map<String, dynamic>)).toList();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _err(e));
    }
  }

  Future<void> _follow() async {
    final api = _api(ref);
    if (api == null) return;
    HapticFeedback.selectionClick();
    try {
      await api.json(_c.following ? 'DELETE' : 'POST', '/v1/channels/${_c.id}/follow');
      setState(() {
        _c.j['following'] = !_c.following;
        _c.j['followers'] = _c.followers + (_c.following ? 1 : -1);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  Future<void> _pickPhoto() async {
    try {
      var x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1280, maxHeight: 1280, imageQuality: 72);
      if (x == null) return;
      var b = await x.readAsBytes();
      if (b.length > 390 * 1024) {
        x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 900, maxHeight: 900, imageQuality: 55);
        if (x == null) return;
        b = await x.readAsBytes();
      }
      if (b.length > 390 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Esa foto es demasiado grande.'))));
        }
        return;
      }
      setState(() => _photo = b);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('KLK no tiene permiso para tus fotos. Actívalo en Ajustes → KLK.'))));
      }
    }
  }

  Future<void> _post() async {
    final api = _api(ref);
    final text = _text.text.trim();
    if (api == null || (text.isEmpty && _photo == null)) return;
    setState(() => _sending = true);
    try {
      final j = await api.json('POST', '/v1/channels/${_c.id}/posts', {
        'body': text,
        if (_photo != null) 'image': base64Encode(_photo!),
      }) as Map<String, dynamic>;
      final p = KChanPost(j);
      if (_photo != null) _imageCache['${_c.id}/${p.id}'] = _photo!;
      setState(() {
        _posts = [p, ...?_posts];
        _text.clear();
        _photo = null;
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deletePost(KChanPost p) async {
    final api = _api(ref);
    if (api == null) return;
    try {
      await api.json('DELETE', '/v1/channels/${_c.id}/posts/${p.id}');
      setState(() => _posts?.remove(p));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
    }
  }

  Future<void> _menu(String v) async {
    final api = _api(ref);
    if (api == null) return;
    switch (v) {
      case 'share':
        final link = api.base.replace(path: '/k/${_c.id}').toString();
        await shareText(context, '${_c.emoji} ${tr('Sigue el canal')} «${_c.name}» ${tr('en KLK messenger')}\n$link');
      case 'edit':
        final c = await Navigator.of(context)
            .push<KChannel>(MaterialPageRoute(builder: (_) => CreateChannelScreen(edit: _c)));
        if (c != null) _load();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('¿Borrar el canal?')),
            content: Text(tr('Se borran todas sus publicaciones y tus seguidores dejarán de verlo. No se puede deshacer.')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Borrar'))),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await api.json('DELETE', '/v1/channels/${_c.id}');
          if (mounted) Navigator.of(context).pop();
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_err(e))));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final posts = _posts;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          _emojiAvatar(_c, radius: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_c.name, overflow: TextOverflow.ellipsis),
              Text(_followers(_c.followers), style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ]),
          ),
        ]),
        actions: [
          if (!_c.mine)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _c.following
                  ? OutlinedButton(onPressed: _follow, child: Text(tr('Siguiendo')))
                  : FilledButton(onPressed: _follow, child: Text(tr('Seguir'))),
            ),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'share', child: Text(tr('Compartir canal'))),
              if (_c.mine) PopupMenuItem(value: 'edit', child: Text(tr('Editar canal'))),
              if (_c.mine) PopupMenuItem(value: 'delete', child: Text(tr('Borrar canal'))),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _error != null && posts == null
                ? Center(child: Text(_error!))
                : posts == null
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                          children: [
                            for (final p in posts)
                              _PostBubble(
                                channelId: _c.id,
                                post: p,
                                mine: _c.mine,
                                onDelete: () => _deletePost(p),
                              ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Column(children: [
                                _emojiAvatar(_c, radius: 36),
                                const SizedBox(height: 8),
                                Text(_c.name,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                                if (_c.description.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(_c.description,
                                        textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                                  ),
                                const SizedBox(height: 6),
                                Text(
                                    _c.mine
                                        ? tr('Este es tu canal. Lo que publiques lo verán todos tus seguidores.')
                                        : tr('Canal público. El dueño no ve tu número.'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                              ]),
                            ),
                          ],
                        ),
                      ),
          ),
          if (_c.mine) ...[
            if (_photo != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Stack(children: [
                  ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(_photo!, height: 140, fit: BoxFit.cover)),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton.filledTonal(
                        onPressed: () => setState(() => _photo = null), icon: const Icon(Icons.close, size: 18)),
                  ),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 8, 8),
              child: Row(children: [
                IconButton(onPressed: _sending ? null : _pickPhoto, icon: const Icon(Icons.photo_outlined)),
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 6,
                    decoration: InputDecoration(
                      hintText: tr('Publicar en el canal'),
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _sending ? null : _post,
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _PostBubble extends ConsumerWidget {
  const _PostBubble({required this.channelId, required this.post, required this.mine, required this.onDelete});
  final String channelId;
  final KChanPost post;
  final bool mine;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => showModalBottomSheet<void>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (post.body.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text(tr('Copiar')),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: post.body));
                    Navigator.pop(ctx);
                  },
                ),
              if (mine)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Color(0xFFCE1126)),
                  title: Text(tr('Borrar publicación'), style: const TextStyle(color: Color(0xFFCE1126))),
                  onTap: () {
                    Navigator.pop(ctx);
                    onDelete();
                  },
                ),
            ]),
          ),
        ),
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (post.hasImage) _PostImage(channelId: channelId, postId: post.id),
            if (post.body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                child: SelectableText(post.body, style: const TextStyle(fontSize: 16)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
              child: Text(_ago(post.at), style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _PostImage extends ConsumerStatefulWidget {
  const _PostImage({required this.channelId, required this.postId});
  final String channelId;
  final String postId;

  @override
  ConsumerState<_PostImage> createState() => _PostImageState();
}

class _PostImageState extends ConsumerState<_PostImage> {
  Uint8List? _bytes;
  bool _failed = false;

  String get _key => '${widget.channelId}/${widget.postId}';

  @override
  void initState() {
    super.initState();
    _bytes = _imageCache[_key];
    if (_bytes == null) _fetch();
  }

  Future<void> _fetch() async {
    final api = _api(ref);
    if (api == null) return;
    try {
      final b = Uint8List.fromList(await api.bytes('/v1/channels/${widget.channelId}/posts/${widget.postId}/image'));
      _imageCache[_key] = b;
      if (mounted) setState(() => _bytes = b);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: b != null
          ? GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                  body: Center(child: InteractiveViewer(child: Image.memory(b))),
                ),
              )),
              child: Image.memory(b, fit: BoxFit.cover, width: double.infinity),
            )
          : SizedBox(
              height: 180,
              width: double.infinity,
              child: Center(child: _failed ? const Icon(Icons.broken_image_outlined) : const CircularProgressIndicator()),
            ),
    );
  }
}
