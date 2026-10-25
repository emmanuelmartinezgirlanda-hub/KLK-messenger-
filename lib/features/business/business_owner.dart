import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/l10n.dart';
import '../../core/util/share.dart';
import '../chat/presentation/chat_screen.dart';
import '../communities/community.dart';
import '../messaging/app_controller.dart';
import 'biz_images.dart';
import 'business.dart';
import 'business_screens.dart';

const _verde = Color(0xFF1F7A4D);

// ---------------------------------------------------------------------------
// Ajustes → Mi negocio
// ---------------------------------------------------------------------------

class MyBusinessScreen extends ConsumerWidget {
  const MyBusinessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final b = app.myBusiness;
    final cs = Theme.of(context).colorScheme;
    if (b == null) return const _BusinessIntro();

    Widget tile(IconData icon, String title, String sub, VoidCallback onTap) => ListTile(
          leading: CircleAvatar(backgroundColor: bizRed.withValues(alpha: 0.12), child: Icon(icon, color: bizRed)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        );

    final debtors = app.fiao.where((a) => a.balance > 0).length;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Mi negocio'))),
      body: ListView(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: bizRed, borderRadius: BorderRadius.circular(20)),
          child: Row(children: [
            _LogoButton(biz: b),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                      child: Text(b.name,
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800))),
                  if (b.verified) const Padding(padding: EdgeInsets.only(left: 6), child: VerifiedMark(color: Colors.white)),
                ]),
                Text('${b.kind.emoji} ${b.kind.label}', style: const TextStyle(color: Colors.white)),
                Text(b.hoursLabel, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            tr('Tus clientes te encuentran en Comunidades → Negocios. Los pedidos y citas te llegan por el chat, cifrados.'),
            style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.65)),
          ),
        ),
        const SizedBox(height: 8),
        tile(Icons.storefront_rounded, tr('Editar perfil'), tr('Nombre, horario, dirección y delivery'), () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => BusinessEditScreen(initial: b)));
        }),
        tile(Icons.list_alt_rounded, b.kind.catalogLabel, '${b.items.length} ${tr('en el catálogo')}', () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CatalogEditScreen()));
        }),
        tile(
            Icons.menu_book_rounded,
            tr('Libreta del fiao'),
            debtors == 0
                ? tr('Nadie te debe')
                : '$debtors ${debtors == 1 ? tr('cliente') : tr('clientes')} · ${bizMoney(app.fiaoTotal, b.currency)}', () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FiaoScreen()));
        }),
        tile(Icons.visibility_outlined, tr('Ver como cliente'), tr('Así ven tu negocio los demás'), () {
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => BusinessProfileScreen(business: b, preview: true)));
        }),
        Builder(
          // El Builder da la posición de la fila: iOS la necesita para abrir «Compartir».
          builder: (tileContext) => tile(
              Icons.ios_share_rounded, tr('Compartir mi negocio'), tr('Para tus estados, WhatsApp o Instagram'), () {
            shareText(
              tileContext,
              '${b.kind.emoji} ${b.name}${b.city.isEmpty ? '' : ' (${b.city})'}\n'
              '${tr('Mira mi catálogo y haz tu pedido por KLK messenger:')}\n'
              '${app.bizShareLink(b.id)}',
              subject: b.name,
            );
          }),
        ),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.close_rounded, color: Color(0xFFB3261E)),
          title: Text(tr('Dejar de ser negocio'), style: const TextStyle(color: Color(0xFFB3261E))),
          subtitle: Text(tr('Tu perfil deja de salir en la búsqueda. Tus chats no se borran.')),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(tr('¿Dejar de ser negocio?')),
                content: Text(tr('Tu perfil y tu catálogo dejarán de ser públicos. La libreta del fiao se queda en tu móvil.')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Sí, dejarlo'))),
                ],
              ),
            );
            if (ok != true) return;
            try {
              await ref.read(appProvider).closeMyBusiness();
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('No se pudo')}: $e')));
              }
            }
          },
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

/// El cuadrado del logo en «Mi negocio»: al tocarlo se pone o se cambia el logo.
class _LogoButton extends ConsumerStatefulWidget {
  final BizProfile biz;
  const _LogoButton({required this.biz});

  @override
  ConsumerState<_LogoButton> createState() => _LogoButtonState();
}

class _LogoButtonState extends ConsumerState<_LogoButton> {
  bool _busy = false;

  Future<void> _change() async {
    final b = widget.biz;
    final messenger = ScaffoldMessenger.of(context);
    final id = await pickAndUploadBizPhoto(context, ref,
        hasPhoto: b.logo.isNotEmpty, maxSide: 512, onBusy: (v) {
      if (mounted) setState(() => _busy = v);
    });
    if (id == null || id == b.logo || !mounted) return;
    setState(() => _busy = true);
    try {
      final app = ref.read(appProvider);
      await app.saveMyBusiness((app.myBusiness ?? b).copyWith(logo: id));
      messenger.showSnackBar(SnackBar(content: Text(id.isEmpty ? tr('Logo quitado') : tr('Logo guardado'))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${tr('No se pudo guardar')}: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.biz.logo.isEmpty ? tr('Poner logo') : tr('Cambiar logo'),
      child: GestureDetector(
        onTap: _busy ? null : _change,
        child: Stack(clipBehavior: Clip.none, children: [
          BizAvatar(biz: widget.biz, size: 56, onRed: true),
          if (_busy)
            const Positioned.fill(
              child: Center(
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: bizRed))),
            ),
          Positioned(
            right: -4,
            bottom: -4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFF14181F),
                shape: BoxShape.circle,
                border: Border.all(color: bizRed, width: 2),
              ),
              child: const Icon(Icons.photo_camera_rounded, size: 13, color: Colors.white),
            ),
          ),
        ]),
      ),
    );
  }
}

class _BusinessIntro extends StatelessWidget {
  const _BusinessIntro();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget point(String emoji, String title, String sub) => ListTile(
          leading: Text(emoji, style: const TextStyle(fontSize: 28)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(sub),
        );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Mi negocio'))),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Text(tr('Pon tu negocio en KLK'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(tr('Colmado, barbería, salón, comida, tienda… Gratis y dentro de tu mismo KLK.'),
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
        ),
        const SizedBox(height: 8),
        point('🛒', tr('Pedidos por chat'), tr('Tus clientes eligen del catálogo y te llega el pedido ordenado.')),
        point('📅', tr('Citas'), tr('Para peluquerías y salones: eligen servicio, día y hora.')),
        point('📒', tr('Libreta del fiao'), tr('Apunta lo que te deben y recuérdaselo con un botón.')),
        point('🔎', tr('Que te encuentren'), tr('Sales en Comunidades → Negocios con tu horario y dirección.')),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: bizRed, minimumSize: const Size.fromHeight(54)),
            onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const BusinessEditScreen())),
            child: Text(tr('Crear cuenta de negocio')),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
          child: Text(
            tr('El nombre, horario, dirección y catálogo serán públicos. Tu número de teléfono no se muestra.'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Editar perfil del negocio
// ---------------------------------------------------------------------------

class BusinessEditScreen extends ConsumerStatefulWidget {
  final BizProfile? initial;
  const BusinessEditScreen({super.key, this.initial});

  @override
  ConsumerState<BusinessEditScreen> createState() => _BusinessEditScreenState();
}

class _BusinessEditScreenState extends ConsumerState<BusinessEditScreen> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _city = TextEditingController(text: widget.initial?.city ?? '');
  late final _about = TextEditingController(text: widget.initial?.about ?? '');
  late final _addr = TextEditingController(text: widget.initial?.address ?? '');
  late final _delivery = TextEditingController(text: widget.initial?.delivery ?? '');
  late final _staff = TextEditingController(text: widget.initial?.staff.join(', ') ?? '');
  late final _quick = TextEditingController(text: widget.initial?.quick.join('\n') ?? '');
  late BizKind _kind = widget.initial?.kind ?? BizKind.colmado;
  late String _country = widget.initial?.country ?? '';
  late String _currency = widget.initial?.currency ?? 'RD\$';
  late int _open = widget.initial?.openHour ?? 8;
  late int _close = widget.initial?.closeHour ?? 20;
  late Set<int> _days = {...(widget.initial?.days ?? const [1, 2, 3, 4, 5, 6])};
  late int _slot = widget.initial?.slotMin ?? 30;
  late String _logo = widget.initial?.logo ?? '';
  bool _saving = false;
  bool _uploadingLogo = false;

  Future<void> _pickLogo() async {
    final id = await pickAndUploadBizPhoto(context, ref, hasPhoto: _logo.isNotEmpty, maxSide: 512, onBusy: (v) {
      if (mounted) setState(() => _uploadingLogo = v);
    });
    if (id != null && mounted) setState(() => _logo = id);
  }

  @override
  void initState() {
    super.initState();
    if (widget.initial == null) {
      final phone = ref.read(appProvider).session?.phone ?? '';
      _country = countryOfPhone(phone) ?? '';
      _currency = switch (_country) { 'DO' => 'RD\$', 'US' || 'PR' => 'US\$', 'GB' => '£', '' => 'RD\$', _ => '€' };
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _city, _about, _addr, _delivery, _staff, _quick]) {
      c.dispose();
    }
    super.dispose();
  }

  String _hour(int h) => h == 24 ? '12:00 a. m.' : DateFormat('h:mm a', 'es').format(DateTime(2000, 1, 1, h));

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Ponle nombre a tu negocio.'))));
      return;
    }
    if (_days.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Elige al menos un día que abres.'))));
      return;
    }
    final app = ref.read(appProvider);
    final base = widget.initial ?? BizProfile(id: app.myId, name: name, kind: _kind);
    final p = base.copyWith(
      name: name,
      kind: _kind,
      country: _country,
      city: _city.text.trim(),
      about: _about.text.trim(),
      address: _addr.text.trim(),
      delivery: _delivery.text.trim(),
      currency: _currency,
      openHour: _open,
      closeHour: _close,
      days: (_days.toList()..sort()),
      slotMin: _slot,
      logo: _logo,
      staff: _staff.text.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).take(10).toList(),
      quick: _quick.text.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty).take(12).toList(),
    );
    setState(() => _saving = true);
    try {
      await app.saveMyBusiness(p);
      if (!mounted) return;
      if (widget.initial == null) {
        await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MyBusinessScreen()));
        if (mounted) return;
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('No se pudo guardar')}: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
          child: Text(t.toUpperCase(),
              style: TextStyle(fontSize: 12, letterSpacing: 1.1, fontWeight: FontWeight.w700, color: cs.secondary)),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? tr('Nuevo negocio') : tr('Editar negocio')),
        actions: [
          TextButton(onPressed: _saving || _uploadingLogo ? null : _save, child: Text(tr('Guardar'))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        label(tr('Logo')),
        Row(children: [
          GestureDetector(
            onTap: _uploadingLogo ? null : _pickLogo,
            child: Stack(alignment: Alignment.center, children: [
              BizAvatar(
                biz: BizProfile(id: '', name: _name.text.trim().isEmpty ? '?' : _name.text.trim(), kind: _kind, logo: _logo),
                size: 72,
              ),
              if (_uploadingLogo)
                const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              OutlinedButton.icon(
                onPressed: _uploadingLogo ? null : _pickLogo,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(_logo.isEmpty ? tr('Poner logo') : tr('Cambiar logo')),
              ),
              Text(tr('Sale en tu perfil, en la búsqueda y cuando compartes tu negocio.'),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
            ]),
          ),
        ]),
        label(tr('Tipo de negocio')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in BizKind.values)
            ChoiceChip(label: Text('${k.emoji} ${k.label}'), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
        ]),
        label(tr('Datos')),
        TextField(
          controller: _name,
          maxLength: 60,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: tr('Nombre del negocio'), hintText: tr('Ej.: Colmado Mi Gente')),
          onChanged: (_) => setState(() {}), // las iniciales del logo
        ),
        TextField(
          controller: _about,
          maxLength: 300,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr('Descripción corta (opcional)')),
        ),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _country,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('País')),
              items: [
                DropdownMenuItem(value: '', child: Text(tr('Sin indicar'))),
                for (final c in demoCommunities) DropdownMenuItem(value: c.id, child: Text('${c.flag} ${c.name}')),
              ],
              onChanged: (v) => setState(() => _country = v ?? ''),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            child: DropdownButtonFormField<String>(
              initialValue: _currency,
              decoration: InputDecoration(labelText: tr('Moneda')),
              items: [for (final c in bizCurrencies) DropdownMenuItem(value: c, child: Text(c))],
              onChanged: (v) => setState(() => _currency = v ?? 'RD\$'),
            ),
          ),
        ]),
        TextField(
          controller: _city,
          maxLength: 60,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: tr('Ciudad o barrio'), hintText: tr('Ej.: Los Mina, Santo Domingo')),
        ),
        TextField(
          controller: _addr,
          maxLength: 120,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr('Dirección (opcional)')),
        ),
        if (!_kind.usesBookings)
          TextField(
            controller: _delivery,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: tr('Delivery (déjalo vacío si no haces)'),
              hintText: tr('Ej.: Delivery RD\$ 50 · gratis desde RD\$ 1,000'),
            ),
          ),
        label(tr('Horario')),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var d = 1; d <= 7; d++)
            FilterChip(
              label: Text(dayShort(d)),
              selected: _days.contains(d),
              onSelected: (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _open,
              decoration: InputDecoration(labelText: tr('Abre')),
              items: [for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text(_hour(h)))],
              onChanged: (v) => setState(() {
                _open = v ?? 8;
                if (_close <= _open) _close = (_open + 1).clamp(1, 24);
              }),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _close,
              decoration: InputDecoration(labelText: tr('Cierra')),
              items: [
                for (var h = _open + 1; h <= 24; h++) DropdownMenuItem(value: h, child: Text(_hour(h))),
              ],
              onChanged: (v) => setState(() => _close = v ?? 20),
            ),
          ),
        ]),
        if (_kind.usesBookings) ...[
          label(tr('Citas')),
          DropdownButtonFormField<int>(
            initialValue: _slot,
            decoration: InputDecoration(labelText: tr('Dar citas cada')),
            items: [for (final m in const [15, 20, 30, 45, 60]) DropdownMenuItem(value: m, child: Text('$m min'))],
            onChanged: (v) => setState(() => _slot = v ?? 30),
          ),
          TextField(
            controller: _staff,
            decoration: InputDecoration(
              labelText: tr('¿Quién atiende? (opcional)'),
              hintText: tr('Separados por comas: Juan, Miguel'),
            ),
          ),
        ],
        label(tr('Respuestas rápidas')),
        TextField(
          controller: _quick,
          maxLines: 5,
          minLines: 2,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: tr('Una por línea. Ej.:\nAbierto hasta las 11\nYa va en camino'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: bizRed, minimumSize: const Size.fromHeight(52)),
          onPressed: _saving || _uploadingLogo ? null : _save,
          child: _saving
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : Text(widget.initial == null ? tr('Crear mi negocio') : tr('Guardar cambios')),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Catálogo: productos o servicios con precio
// ---------------------------------------------------------------------------

class CatalogEditScreen extends ConsumerStatefulWidget {
  const CatalogEditScreen({super.key});

  @override
  ConsumerState<CatalogEditScreen> createState() => _CatalogEditScreenState();
}

class _CatalogEditScreenState extends ConsumerState<CatalogEditScreen> {
  late List<BizItem> _items = [...?ref.read(appProvider).myBusiness?.items];
  bool _dirty = false;
  bool _saving = false;

  Future<void> _edit([BizItem? item]) async {
    final b = ref.read(appProvider).myBusiness!;
    final out = await showModalBottomSheet<BizItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ItemSheet(item: item, biz: b),
    );
    if (out == null) return;
    setState(() {
      final i = _items.indexWhere((x) => x.id == out.id);
      if (i < 0) {
        _items = [..._items, out];
      } else {
        _items = [..._items]..[i] = out;
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final app = ref.read(appProvider);
    final b = app.myBusiness;
    if (b == null) return;
    setState(() => _saving = true);
    try {
      await app.saveMyBusiness(b.copyWith(items: _items));
      if (mounted) {
        setState(() => _dirty = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Catálogo guardado'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('No se pudo guardar')}: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(appProvider).myBusiness;
    if (b == null) return const Scaffold();
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final save = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('¿Guardar los cambios del catálogo?')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Descartar'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Guardar'))),
            ],
          ),
        );
        if (save == true) await _save();
        if (save != null && context.mounted) {
          setState(() => _dirty = false);
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(b.kind.catalogLabel),
          actions: [
            TextButton(onPressed: !_dirty || _saving ? null : _save, child: Text(tr('Guardar'))),
          ],
        ),
        floatingActionButton: _items.length >= BizProfile.maxItems
            ? null
            : FloatingActionButton.extended(
                backgroundColor: bizRed,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add),
                label: Text(b.kind.usesBookings ? tr('Añadir servicio') : tr('Añadir producto')),
                onPressed: () => _edit(),
              ),
        body: _items.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    b.kind.usesBookings
                        ? tr('Añade tus servicios: corte, barba, uñas… con su precio y cuánto duran.')
                        : tr('Añade tus productos con su precio. Tus clientes los eligen y te mandan el pedido.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65)),
                  ),
                ),
              )
            : ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: _items.length,
                onReorder: (a, z) => setState(() {
                  final list = [..._items];
                  final it = list.removeAt(a);
                  list.insert(z > a ? z - 1 : z, it);
                  _items = list;
                  _dirty = true;
                }),
                itemBuilder: (_, i) {
                  final it = _items[i];
                  return Dismissible(
                    key: ValueKey(it.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: const Color(0xFFB3261E),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete_outline, color: Colors.white),
                    ),
                    onDismissed: (_) => setState(() {
                      _items = _items.where((x) => x.id != it.id).toList();
                      _dirty = true;
                    }),
                    child: ListTile(
                      leading: it.img.isEmpty
                          ? null
                          : BizImage(
                              id: it.img,
                              size: 48,
                              radius: 10,
                              fallback: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                      title: Text(it.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text([
                        it.price == null ? tr('Consultar') : bizMoney(it.price!, b.currency),
                        if (it.minutes != null) '${it.minutes} min',
                        if (it.cat.isNotEmpty) it.cat,
                      ].join(' · ')),
                      trailing: const Icon(Icons.drag_handle_rounded),
                      onTap: () => _edit(it),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _ItemSheet extends ConsumerStatefulWidget {
  final BizItem? item;
  final BizProfile biz;
  const _ItemSheet({this.item, required this.biz});

  @override
  ConsumerState<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends ConsumerState<_ItemSheet> {
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _price = TextEditingController(
      text: widget.item?.price == null ? '' : NumberFormat('0.##', 'en').format(widget.item!.price));
  late final _cat = TextEditingController(text: widget.item?.cat ?? '');
  late final _desc = TextEditingController(text: widget.item?.desc ?? '');
  late int _minutes = widget.item?.minutes ?? 30;
  late String _img = widget.item?.img ?? '';
  bool _uploading = false;

  Future<void> _pickPhoto() async {
    final id = await pickAndUploadBizPhoto(context, ref, hasPhoto: _img.isNotEmpty, onBusy: (v) {
      if (mounted) setState(() => _uploading = v);
    });
    if (id != null && mounted) setState(() => _img = id);
  }

  @override
  void dispose() {
    for (final c in [_name, _price, _cat, _desc]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.biz.kind.usesBookings;
    final cats = <String>{for (final i in widget.biz.items) if (i.cat.isNotEmpty) i.cat};
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.item == null ? (services ? tr('Nuevo servicio') : tr('Nuevo producto')) : tr('Editar'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Row(children: [
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _uploading ? null : _pickPhoto,
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _uploading
                    ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)))
                    : _img.isEmpty
                        ? const Icon(Icons.add_a_photo_outlined, size: 30)
                        : BizImage(
                            id: _img,
                            size: 84,
                            radius: 16,
                            fallback: const Center(child: Icon(Icons.image_outlined, size: 30)),
                          ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextButton.icon(
                  onPressed: _uploading ? null : _pickPhoto,
                  icon: Icon(_img.isEmpty ? Icons.add_photo_alternate_outlined : Icons.edit_outlined),
                  label: Text(_img.isEmpty ? tr('Añadir foto') : tr('Cambiar foto')),
                ),
                Text(tr('Opcional. Con foto se vende más.'),
                    style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
              ]),
            ),
          ]),
          TextField(
            controller: _name,
            autofocus: widget.item == null,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr('Nombre'), hintText: services ? tr('Ej.: Corte') : tr('Ej.: Arroz (libra)')),
          ),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            decoration: InputDecoration(
              labelText: '${tr('Precio')} (${widget.biz.currency})',
              helperText: tr('Déjalo vacío para "Consultar"'),
            ),
          ),
          const SizedBox(height: 8),
          if (services)
            DropdownButtonFormField<int>(
              initialValue: _minutes,
              decoration: InputDecoration(labelText: tr('Dura')),
              items: [for (final m in const [15, 20, 30, 45, 60, 90, 120, 180]) DropdownMenuItem(value: m, child: Text('$m min'))],
              onChanged: (v) => setState(() => _minutes = v ?? 30),
            )
          else ...[
            TextField(
              controller: _cat,
              maxLength: 30,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr('Categoría (opcional)'), hintText: tr('Ej.: Despensa, Bebidas')),
            ),
            if (cats.isNotEmpty)
              Wrap(spacing: 6, children: [
                for (final c in cats) ActionChip(label: Text(c), onPressed: () => setState(() => _cat.text = c)),
              ]),
          ],
          TextField(
            controller: _desc,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: tr('Detalle (opcional)')),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: bizRed, minimumSize: const Size.fromHeight(50)),
            onPressed: _name.text.trim().isEmpty || _uploading
                ? null
                : () {
                    final price = double.tryParse(_price.text.trim().replaceAll(',', '.'));
                    Navigator.pop(
                      context,
                      BizItem(
                        id: widget.item?.id ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36),
                        name: _name.text.trim(),
                        price: price == null || price < 0 ? null : price,
                        cat: services ? '' : _cat.text.trim(),
                        desc: _desc.text.trim(),
                        minutes: services ? _minutes : null,
                        img: _img,
                      ),
                    );
                  },
            child: Text(tr('Listo')),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// La libreta del fiao
// ---------------------------------------------------------------------------

class FiaoScreen extends ConsumerWidget {
  const FiaoScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref, {FiaoAccount? account, bool payment = false}) async {
    final app = ref.read(appProvider);
    final cur = app.myBusiness?.currency ?? 'RD\$';
    final r = await showModalBottomSheet<(String id, String name, double amount, String note)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FiaoEntrySheet(account: account, payment: payment, currency: cur),
    );
    if (r == null) return;
    app.fiaoAdd(id: r.$1, name: r.$2, amount: r.$3, note: r.$4);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final cur = app.myBusiness?.currency ?? 'RD\$';
    final open = app.fiao.where((a) => a.balance > 0).toList()..sort((a, b) => b.balance.compareTo(a.balance));
    final closed = app.fiao.where((a) => a.balance <= 0).toList();
    final cs = Theme.of(context).colorScheme;

    Widget row(FiaoAccount a) {
      final since = a.since;
      final days = since == null ? 0 : DateTime.now().difference(since).inDays;
      final note = a.balance <= 0
          ? tr('Cuenta saldada')
          : a.remindedAt != null
              ? '${tr('Recordado')} ${DateFormat('d MMM', 'es').format(a.remindedAt!)}'
              : days == 0
                  ? tr('Desde hoy')
                  : '${tr('Desde hace')} $days ${days == 1 ? tr('día') : tr('días')}';
      return ListTile(
        leading: CircleAvatar(child: Text(a.name.characters.first.toUpperCase())),
        title: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(note),
        trailing: Text(
          a.balance <= 0 ? tr('Pagado') : bizMoney(a.balance, cur),
          style: TextStyle(fontWeight: FontWeight.w800, color: a.balance <= 0 ? _verde : null),
        ),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _FiaoAccountScreen(account: a))),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('Libreta del fiao'))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: bizRed,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(tr('Apuntar')),
        onPressed: () => _add(context, ref),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: bizBlue, borderRadius: BorderRadius.circular(20)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Total que te deben'), style: const TextStyle(color: Colors.white, fontSize: 13)),
            Text(bizMoney(app.fiaoTotal, cur),
                style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
            Text('${open.length} ${tr('clientes con cuenta abierta')}', style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(Icons.lock_outline, size: 16, color: cs.onSurface.withValues(alpha: 0.6)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(tr('La libreta se guarda solo en tu móvil. Haz copias de seguridad.'),
                  style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
            ),
          ]),
        ),
        if (app.fiao.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              tr('Aquí apuntas lo que te deben. También puedes apuntar un pedido desde el chat con el botón «Apuntar al fiao».'),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65)),
            ),
          ),
        for (final a in open) row(a),
        if (closed.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(tr('SALDADAS'),
                style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: cs.secondary)),
          ),
          for (final a in closed) row(a),
        ],
      ]),
    );
  }
}

class _FiaoAccountScreen extends ConsumerWidget {
  final FiaoAccount account;
  const _FiaoAccountScreen({required this.account});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final a = app.fiao.where((x) => x.id == account.id && x.name == account.name).firstOrNull ?? account;
    final cur = app.myBusiness?.currency ?? 'RD\$';
    final entries = [...a.entries]..sort((x, y) => y.at.compareTo(x.at));

    Future<void> add({bool payment = false}) async {
      final r = await showModalBottomSheet<(String id, String name, double amount, String note)>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _FiaoEntrySheet(account: a, payment: payment, currency: cur),
      );
      if (r != null) app.fiaoAdd(id: r.$1, name: r.$2, amount: r.$3, note: r.$4);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(a.name),
        actions: [
          if (a.id.isNotEmpty)
            IconButton(
              tooltip: tr('Abrir chat'),
              icon: const Icon(Icons.chat_bubble_outline),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: a.id))),
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v != 'del') return;
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(tr('¿Borrar esta cuenta de la libreta?')),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Borrar'))),
                  ],
                ),
              );
              if (ok == true) {
                app.fiaoRemove(a);
                if (context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => [PopupMenuItem(value: 'del', child: Text(tr('Borrar cuenta')))],
          ),
        ],
      ),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(a.balance <= 0 ? tr('Cuenta saldada') : '${tr('Debe')} ${bizMoney(a.balance, cur)}',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: a.balance <= 0 ? _verde : null)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: Text(tr('Apuntar más')),
                onPressed: () => add(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _verde),
                icon: const Icon(Icons.check),
                label: Text(tr('Pagó')),
                onPressed: a.balance <= 0 ? null : () => add(payment: true),
              ),
            ),
          ]),
        ),
        if (a.id.isNotEmpty && a.balance > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(tr('Recordarle por el chat')),
              onPressed: () async {
                await app.fiaoRemind(a);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(tr('Recordatorio enviado por el chat'))));
                }
              },
            ),
          ),
        const Divider(height: 32),
        for (final e in entries)
          ListTile(
            dense: true,
            leading: Icon(e.amount < 0 ? Icons.south_west_rounded : Icons.north_east_rounded,
                color: e.amount < 0 ? _verde : bizRed),
            title: Text(e.note.isEmpty ? (e.amount < 0 ? tr('Pago') : tr('Fiao')) : e.note,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(DateFormat("d MMM yyyy, h:mm a", 'es').format(e.at)),
            trailing: Text('${e.amount < 0 ? '−' : '+'} ${bizMoney(e.amount.abs(), cur)}',
                style: TextStyle(fontWeight: FontWeight.w700, color: e.amount < 0 ? _verde : null)),
          ),
      ]),
    );
  }
}

class _FiaoEntrySheet extends ConsumerStatefulWidget {
  final FiaoAccount? account;
  final bool payment;
  final String currency;
  const _FiaoEntrySheet({this.account, this.payment = false, required this.currency});

  @override
  ConsumerState<_FiaoEntrySheet> createState() => _FiaoEntrySheetState();
}

class _FiaoEntrySheetState extends ConsumerState<_FiaoEntrySheet> {
  final _name = TextEditingController();
  late final _amount = TextEditingController(
      text: widget.payment && widget.account != null && widget.account!.balance > 0
          ? NumberFormat('0.##', 'en').format(widget.account!.balance)
          : '');
  final _note = TextEditingController();
  String _chatId = '';

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  double? get _value {
    final v = double.tryParse(_amount.text.trim().replaceAll(',', '.'));
    return v == null || v <= 0 || v > 1e7 ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final a = widget.account;
    final contacts = app.contactChats.where((c) => !c.isNotes).take(300).toList();
    final name = a?.name ?? _name.text.trim();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.payment ? tr('Apuntar un pago') : tr('Apuntar al fiao'),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          if (a == null) ...[
            const SizedBox(height: 8),
            Autocomplete<String>(
              optionsBuilder: (v) {
                final t = foldSearch(v.text);
                if (t.isEmpty) return const [];
                return contacts.where((c) => foldSearch(c.title).contains(t)).map((c) => c.title).take(6);
              },
              onSelected: (s) => setState(() {
                _name.text = s;
                _chatId = contacts.firstWhere((c) => c.title == s).id;
              }),
              fieldViewBuilder: (ctx, ctrl, focus, onSubmit) => TextField(
                controller: ctrl,
                focusNode: focus,
                textCapitalization: TextCapitalization.words,
                onChanged: (v) => setState(() {
                  _name.text = v;
                  _chatId = '';
                }),
                decoration: InputDecoration(
                  labelText: tr('Cliente'),
                  hintText: tr('Nombre o contacto de KLK'),
                  suffixIcon: _chatId.isEmpty ? null : const Icon(Icons.chat_bubble, color: _verde, size: 18),
                ),
              ),
            ),
          ] else
            Text(a.name),
          const SizedBox(height: 8),
          TextField(
            controller: _amount,
            autofocus: a != null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: '${tr('Cantidad')} (${widget.currency})'),
          ),
          TextField(
            controller: _note,
            maxLength: 120,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
                labelText: tr('Nota (opcional)'), hintText: widget.payment ? tr('Ej.: pagó en efectivo') : tr('Ej.: arroz y aceite')),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: widget.payment ? _verde : bizRed, minimumSize: const Size.fromHeight(50)),
            onPressed: _value == null || name.isEmpty
                ? null
                : () => Navigator.pop(context, (
                      a?.id ?? _chatId,
                      name,
                      widget.payment ? -_value! : _value!,
                      _note.text.trim(),
                    )),
            child: Text(widget.payment ? tr('Apuntar pago') : tr('Apuntar')),
          ),
        ]),
      ),
    );
  }
}

String foldSearch(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[áà]'), 'a')
    .replaceAll(RegExp('[éè]'), 'e')
    .replaceAll(RegExp('[íì]'), 'i')
    .replaceAll(RegExp('[óò]'), 'o')
    .replaceAll(RegExp('[úùü]'), 'u')
    .trim();
