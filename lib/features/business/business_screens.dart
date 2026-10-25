import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/brand/klk_brand.dart';
import '../../core/l10n/l10n.dart';
import '../chat/presentation/chat_screen.dart';
import '../chat/presentation/chat_sheets.dart';
import '../communities/community.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'business.dart';

const _rojo = KlkBrand.rojoPatria;
const _azul = KlkBrand.azulQuisqueya;
const _verde = Color(0xFF1F7A4D);

/// Cuadradito con las iniciales del negocio.
class BizAvatar extends StatelessWidget {
  final BizProfile biz;
  final double size;
  final bool onRed;
  const BizAvatar({super.key, required this.biz, this.size = 48, this.onRed = false});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onRed ? Colors.white : _rojo,
          borderRadius: BorderRadius.circular(size * 0.28),
        ),
        child: Text(biz.initials,
            style: TextStyle(color: onRed ? _rojo : Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.34)),
      );
}

class VerifiedMark extends StatelessWidget {
  final double size;
  final Color color;
  const VerifiedMark({super.key, this.size = 18, this.color = const Color(0xFF1D9BF0)});
  @override
  Widget build(BuildContext context) =>
      Tooltip(message: tr('Negocio verificado por KLK'), child: Icon(Icons.verified_rounded, size: size, color: color));
}

String _countryName(String code) {
  final c = demoCommunities.where((x) => x.id == code).firstOrNull;
  return c == null ? code : '${c.flag} ${c.name}';
}

// ---------------------------------------------------------------------------
// Buscar negocios
// ---------------------------------------------------------------------------

class BusinessDirectoryScreen extends ConsumerStatefulWidget {
  const BusinessDirectoryScreen({super.key});

  @override
  ConsumerState<BusinessDirectoryScreen> createState() => _BusinessDirectoryScreenState();
}

class _BusinessDirectoryScreenState extends ConsumerState<BusinessDirectoryScreen> {
  final _q = TextEditingController();
  BizKind? _kind;
  String _country = '';
  List<BizProfile> _list = const [];
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _country = countryOfPhone(ref.read(appProvider).session?.phone ?? '') ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(appProvider).searchBusinesses(q: _q.text, kind: _kind, country: _country);
      if (!mounted || seq != _seq) return;
      setState(() => _list = list);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = '$e');
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(tr('Todos los países')), onTap: () => Navigator.pop(ctx, '')),
          for (final c in demoCommunities)
            ListTile(leading: Text(c.flag, style: const TextStyle(fontSize: 22)), title: Text(c.name), onTap: () => Navigator.pop(ctx, c.id)),
        ]),
      ),
    );
    if (picked == null) return;
    setState(() => _country = picked);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Negocios'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: tr('Busca un colmado, barbería, comida…'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: tr('Buscar'),
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: _load,
              ),
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ActionChip(
                  avatar: const Icon(Icons.public, size: 18),
                  label: Text(_country.isEmpty ? tr('Todos los países') : _countryName(_country)),
                  onPressed: _pickCountry,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Text(tr('Todos')),
                  selected: _kind == null,
                  onSelected: (_) {
                    setState(() => _kind = null);
                    _load();
                  },
                ),
              ),
              for (final k in BizKind.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text('${k.emoji} ${k.label}'),
                    selected: _kind == k,
                    onSelected: (_) {
                      setState(() => _kind = _kind == k ? null : k);
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(children: [
                      Text('${tr('No se pudo buscar.')}\n$_error', textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: _load, child: Text(tr('Reintentar'))),
                    ]),
                  ),
                if (_error == null && !_loading && _list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
                    child: Column(children: [
                      const Text('🏪', style: TextStyle(fontSize: 48)),
                      const SizedBox(height: 12),
                      Text(tr('Todavía no hay negocios aquí'),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                      const SizedBox(height: 6),
                      Text(
                        tr('¿Tienes un colmado, barbería o negocio? Créalo gratis en Ajustes → Mi negocio, y dile a tus clientes que te busquen aquí.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65)),
                      ),
                    ]),
                  ),
                for (final b in _list)
                  ListTile(
                    leading: BizAvatar(biz: b),
                    title: Row(children: [
                      Flexible(
                          child: Text(b.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
                      if (b.verified) const Padding(padding: EdgeInsets.only(left: 4), child: VerifiedMark(size: 16)),
                    ]),
                    subtitle: Text(
                      [
                        '${b.kind.emoji} ${b.kind.label}',
                        if (b.city.isNotEmpty) b.city,
                        b.openAt(DateTime.now()) ? tr('Abierto') : tr('Cerrado'),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => BusinessProfileScreen(business: b))),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Perfil del negocio, catálogo, pedido y cita
// ---------------------------------------------------------------------------

class BusinessProfileScreen extends ConsumerStatefulWidget {
  final BizProfile business;

  /// El dueño mirando su propio negocio "como lo ven los clientes".
  final bool preview;
  const BusinessProfileScreen({super.key, required this.business, this.preview = false});

  @override
  ConsumerState<BusinessProfileScreen> createState() => _BusinessProfileScreenState();
}

class _BusinessProfileScreenState extends ConsumerState<BusinessProfileScreen> {
  late BizProfile _b = widget.business;
  final Map<String, int> _cart = {}; // id del producto -> cantidad
  String _cat = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (!widget.preview) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final fresh = await ref.read(appProvider).businessProfile(_b.id);
          if (fresh != null && mounted) setState(() => _b = fresh);
        } catch (_) {}
      });
    }
  }

  void _say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  int get _count => _cart.values.fold(0, (a, b) => a + b);

  List<BizLine> get _lines => [
        for (final i in _b.items)
          if ((_cart[i.id] ?? 0) > 0) BizLine(i.name, _cart[i.id]!, i.price),
      ];

  Future<void> _openChat() async {
    if (widget.preview) return _say(tr('Así lo verán tus clientes.'));
    setState(() => _busy = true);
    try {
      final id = await ref.read(appProvider).startChatWithBusiness(_b);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: id)));
    } catch (e) {
      _say('${tr('No se pudo abrir el chat')}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report() async {
    final r = await pickReport(context, _b.name, includeLabel: tr('Adjuntar el nombre y la descripción del negocio'));
    if (r == null) return;
    try {
      await ref.read(appProvider).reportMember(_b.id, r.$1,
          messages: r.$2 ? ['Negocio: ${_b.name} — ${_b.about}'] : const [], block: r.$3, name: _b.name);
      _say(tr('Denuncia enviada. Gracias por avisar.'));
    } catch (e) {
      _say('${tr('No se pudo enviar')}: $e');
    }
  }

  Future<void> _sendDeal(BizDeal deal) async {
    if (widget.preview) return _say(tr('Así lo verán tus clientes.'));
    setState(() => _busy = true);
    try {
      final chatId = await ref.read(appProvider).sendBizDeal(_b, deal);
      if (!mounted) return;
      setState(_cart.clear);
      await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
    } catch (e) {
      _say('${tr('No se pudo enviar')}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkout() async {
    final deal = await showModalBottomSheet<BizDeal>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _OrderSheet(biz: _b, lines: _lines),
    );
    if (deal != null) await _sendDeal(deal);
  }

  Future<void> _book(BizItem service) async {
    final taken = await ref.read(appProvider).bookedSlots(_b.id);
    if (!mounted) return;
    final deal = await showModalBottomSheet<BizDeal>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BookingSheet(biz: _b, service: service, taken: taken),
    );
    if (deal != null) await _sendDeal(deal);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = _b;
    final cats = <String>{for (final i in b.items) if (i.cat.isNotEmpty) i.cat}.toList();
    final items = _cat.isEmpty ? b.items : b.items.where((i) => i.cat == _cat).toList();
    final open = b.openAt(DateTime.now());
    final lines = _lines;
    final total = BizDeal(type: 'order', biz: b.id, bizName: b.name, lines: lines).total;

    return Scaffold(
      body: CustomScrollView(slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: _rojo,
          foregroundColor: Colors.white,
          title: Text(widget.preview ? tr('Así te ven tus clientes') : b.name),
          actions: [
            if (!widget.preview)
              PopupMenuButton<String>(
                onSelected: (a) {
                  if (a == 'report') _report();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'report', child: Text(tr('Denunciar negocio'))),
                ],
              ),
          ],
        ),
        SliverToBoxAdapter(
          child: Container(
            color: _rojo,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                BizAvatar(biz: b, size: 64, onRed: true),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text(b.name,
                            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                      ),
                      if (b.verified) const Padding(padding: EdgeInsets.only(left: 6), child: VerifiedMark(color: Colors.white)),
                    ]),
                    const SizedBox(height: 2),
                    Text('${b.kind.emoji} ${b.kind.label}${b.city.isEmpty ? '' : ' · ${b.city}'}',
                        style: const TextStyle(color: Colors.white, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text('${open ? tr('Abierto ahora') : tr('Cerrado ahora')} · ${b.hoursLabel}',
                        style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ]),
                ),
              ]),
              if (b.about.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(b.about, style: const TextStyle(color: Colors.white, fontSize: 14.5)),
              ],
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: _rojo, minimumSize: const Size(0, 46)),
                    icon: const Icon(Icons.chat_bubble_rounded),
                    label: Text(tr('Escribir')),
                    onPressed: _busy ? null : _openChat,
                  ),
                ),
              ]),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (b.address.isNotEmpty)
              ListTile(leading: const Icon(Icons.place_outlined), title: Text(b.address), dense: true),
            if (b.delivery.isNotEmpty)
              ListTile(leading: const Icon(Icons.delivery_dining_outlined), title: Text(b.delivery), dense: true),
            if (b.country.isNotEmpty)
              ListTile(leading: const Icon(Icons.public), title: Text(_countryName(b.country)), dense: true),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(b.kind.catalogLabel.toUpperCase(),
                  style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: cs.secondary)),
            ),
            if (cats.length > 1)
              SizedBox(
                height: 44,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(label: Text(tr('Todo')), selected: _cat.isEmpty, onSelected: (_) => setState(() => _cat = '')),
                  ),
                  for (final c in cats)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(label: Text(c), selected: _cat == c, onSelected: (_) => setState(() => _cat = c)),
                    ),
                ]),
              ),
            if (b.items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(tr('Este negocio todavía no ha puesto su catálogo. Escríbele por el chat.'),
                    textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65))),
              ),
          ]),
        ),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (_, i) {
            final it = items[i];
            final q = _cart[it.id] ?? 0;
            final price = it.price == null ? tr('Consultar') : bizMoney(it.price!, b.currency);
            return ListTile(
              title: Text(it.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                price,
                if (it.minutes != null) '${it.minutes} min',
                if (it.desc.isNotEmpty) it.desc,
              ].join(' · ')),
              trailing: b.kind.usesBookings
                  ? FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _rojo),
                      onPressed: _busy ? null : () => _book(it),
                      child: Text(tr('Reservar')),
                    )
                  : q == 0
                      ? IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: _rojo),
                          tooltip: tr('Añadir al pedido'),
                          icon: const Icon(Icons.add),
                          onPressed: () => setState(() => _cart[it.id] = 1),
                        )
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: tr('Quitar uno'),
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => setState(() => q <= 1 ? _cart.remove(it.id) : _cart[it.id] = q - 1),
                          ),
                          Text('$q', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                          IconButton(
                            tooltip: tr('Añadir otro'),
                            icon: const Icon(Icons.add_circle, color: _rojo),
                            onPressed: q >= 99 ? null : () => setState(() => _cart[it.id] = q + 1),
                          ),
                        ]),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 110)),
      ]),
      bottomNavigationBar: _count == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF14181F),
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _busy ? null : _checkout,
                  child: Row(children: [
                    Text('${tr('Ver pedido')} · $_count', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const Spacer(),
                    Text(total == null ? '' : bizMoney(total, b.currency),
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  ]),
                ),
              ),
            ),
    );
  }
}

class _OrderSheet extends StatefulWidget {
  final BizProfile biz;
  final List<BizLine> lines;
  const _OrderSheet({required this.biz, required this.lines});

  @override
  State<_OrderSheet> createState() => _OrderSheetState();
}

class _OrderSheetState extends State<_OrderSheet> {
  final _addr = TextEditingController();
  final _note = TextEditingController();
  bool _delivery = true;

  @override
  void dispose() {
    _addr.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.biz;
    final deal = BizDeal(type: 'order', biz: b.id, bizName: b.name, currency: b.currency, lines: widget.lines);
    final total = deal.total;
    final canDeliver = b.delivery.isNotEmpty;
    final needAddr = canDeliver && _delivery;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Tu pedido'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (final l in widget.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(child: Text('${l.qty} × ${l.name}')),
                Text(l.total == null ? tr('Consultar') : bizMoney(l.total!, b.currency)),
              ]),
            ),
          const Divider(height: 20),
          Row(children: [
            Text(tr('Total'), style: const TextStyle(fontWeight: FontWeight.w800)),
            const Spacer(),
            Text(total == null ? tr('Te lo dice el negocio') : bizMoney(total, b.currency),
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 12),
          if (canDeliver)
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: Text(tr('Delivery')), icon: const Icon(Icons.delivery_dining_outlined)),
                ButtonSegment(value: false, label: Text(tr('Lo recojo')), icon: const Icon(Icons.storefront_outlined)),
              ],
              selected: {_delivery},
              onSelectionChanged: (s) => setState(() => _delivery = s.first),
            ),
          if (needAddr) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _addr,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 160,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: tr('¿A dónde te lo llevan?'), hintText: tr('Calle, número, referencia')),
            ),
          ],
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 300,
            decoration: InputDecoration(labelText: tr('Nota (opcional)'), hintText: tr('Ej.: el salami picado')),
          ),
          Text(tr('Pagas como siempre: al recibir o en el negocio. KLK no cobra nada.'),
              style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65))),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _rojo, minimumSize: const Size.fromHeight(52)),
            onPressed: needAddr && _addr.text.trim().length < 4
                ? null
                : () => Navigator.pop(
                    context,
                    BizDeal(
                      type: 'order',
                      biz: b.id,
                      bizName: b.name,
                      currency: b.currency,
                      lines: widget.lines,
                      address: needAddr ? _addr.text.trim() : tr('Lo recojo en el negocio'),
                      note: _note.text.trim(),
                    )),
            child: Text(tr('Enviar pedido')),
          ),
        ]),
      ),
    );
  }
}

class _BookingSheet extends StatefulWidget {
  final BizProfile biz;
  final BizItem service;
  final Set<DateTime> taken;
  const _BookingSheet({required this.biz, required this.service, required this.taken});

  @override
  State<_BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends State<_BookingSheet> {
  late final List<DateTime> _days;
  DateTime? _day;
  DateTime? _time;
  String _staff = '';
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final minutes = widget.service.minutes ?? widget.biz.slotMin;
    _days = [
      for (var i = 0; i < 21; i++)
        if (widget.biz.slotsFor(DateTime(now.year, now.month, now.day + i), minutes, taken: widget.taken).isNotEmpty)
          DateTime(now.year, now.month, now.day + i)
    ].take(14).toList();
    _day = _days.firstOrNull;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.biz;
    final s = widget.service;
    final minutes = s.minutes ?? b.slotMin;
    final slots = _day == null ? const <DateTime>[] : b.slotsFor(_day!, minutes, taken: widget.taken);
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${tr('Reservar')}: ${s.name}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Text([
            if (s.price != null) bizMoney(s.price!, b.currency),
            '$minutes min',
          ].join(' · ')),
          if (b.staff.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(tr('¿Con quién?'), style: const TextStyle(fontWeight: FontWeight.w700)),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: Text(tr('Me da igual')), selected: _staff.isEmpty, onSelected: (_) => setState(() => _staff = '')),
              for (final p in b.staff)
                ChoiceChip(label: Text(p), selected: _staff == p, onSelected: (_) => setState(() => _staff = p)),
            ]),
          ],
          const SizedBox(height: 14),
          Text(tr('Día'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (_days.isEmpty)
            Text(tr('No hay horas libres en los próximos días. Escríbele al negocio por el chat.'))
          else
            SizedBox(
              height: 64,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final d in _days)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(dayShort(d.weekday), style: const TextStyle(fontSize: 12)),
                        Text('${d.day}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      ]),
                      selected: _day == d,
                      onSelected: (_) => setState(() {
                        _day = d;
                        _time = null;
                      }),
                    ),
                  ),
              ]),
            ),
          if (_day != null) ...[
            const SizedBox(height: 12),
            Text(tr('Hora'), style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in slots)
                ChoiceChip(
                  label: Text(DateFormat('h:mm a', 'es').format(t)),
                  selected: _time == t,
                  onSelected: (_) => setState(() => _time = t),
                ),
            ]),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 300,
            decoration: InputDecoration(labelText: tr('Nota (opcional)')),
          ),
          Text(tr('El negocio te confirma la cita por el chat. Te avisamos 1 hora antes.'),
              style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.65))),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _rojo, minimumSize: const Size.fromHeight(52)),
            onPressed: _time == null
                ? null
                : () => Navigator.pop(
                    context,
                    BizDeal(
                      type: 'cita',
                      biz: b.id,
                      bizName: b.name,
                      currency: b.currency,
                      service: s.name,
                      price: s.price,
                      minutes: minutes,
                      at: _time,
                      staff: _staff,
                      note: _note.text.trim(),
                    )),
            child: Text(_time == null
                ? tr('Elige una hora')
                : '${tr('Pedir cita')} · ${DateFormat("EEE d, h:mm a", 'es').format(_time!)}'),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tarjeta del pedido o cita dentro del chat
// ---------------------------------------------------------------------------

class BizCard extends ConsumerStatefulWidget {
  final Message message;
  const BizCard({super.key, required this.message});

  @override
  ConsumerState<BizCard> createState() => _BizCardState();
}

class _BizCardState extends ConsumerState<BizCard> {
  bool _busy = false;

  Future<void> _act(String status) async {
    setState(() => _busy = true);
    try {
      final ok = await ref.read(appProvider).bizAction(widget.message, status);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Ese cambio ya no se puede hacer.'))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toFiao(BizDeal d) async {
    final app = ref.read(appProvider);
    final total = d.total;
    if (total == null) return;
    final chat = app.chatById(widget.message.chatId);
    app.fiaoAdd(id: widget.message.chatId, name: chat?.title ?? tr('Cliente'), amount: total, note: d.summary());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${tr('Apuntado al fiao')}: ${bizMoney(total, d.currency)}')));
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final d = BizDeal.tryParse(widget.message.media?.biz);
    if (d == null) return Padding(padding: const EdgeInsets.all(12), child: Text(tr('Pedido')));
    final iAmBiz = d.biz == app.myId;
    final total = d.total;
    final statusColor = switch (d.status) {
      BizStatus.pending => const Color(0xFFB26A00),
      BizStatus.rejected || BizStatus.cancelled => const Color(0xFFB3261E),
      _ => _verde,
    };

    Widget action(String label, String status, {bool primary = false, Color? color}) => Expanded(
          child: primary
              ? FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: color ?? _verde, padding: EdgeInsets.zero),
                  onPressed: _busy ? null : () => _act(status),
                  child: Text(label, textAlign: TextAlign.center),
                )
              : OutlinedButton(
                  style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: _busy ? null : () => _act(status),
                  child: Text(label, textAlign: TextAlign.center),
                ),
        );

    final buttons = <Widget>[
      if (iAmBiz && d.status == BizStatus.pending) ...[
        action(tr('Rechazar'), BizStatus.rejected),
        const SizedBox(width: 8),
        action(d.isOrder ? tr('Aceptar') : tr('Confirmar'), BizStatus.accepted, primary: true),
      ],
      if (iAmBiz && d.status == BizStatus.accepted && d.isOrder)
        action(tr('Salió el delivery 🛵'), BizStatus.onTheWay, primary: true),
      if (iAmBiz && d.status == BizStatus.accepted && d.isOrder) const SizedBox(width: 8),
      if (iAmBiz && (d.status == BizStatus.onTheWay || d.status == BizStatus.accepted))
        action(d.isOrder ? tr('Entregado') : tr('Atendido'), BizStatus.done, primary: d.isBooking),
      if (!iAmBiz && (d.status == BizStatus.pending || d.status == BizStatus.accepted))
        action(d.isOrder ? tr('Cancelar pedido') : tr('Cancelar cita'), BizStatus.cancelled, color: _rojo),
    ];

    final light = Theme.of(context).brightness == Brightness.light;
    return Container(
      width: 270,
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: light ? Colors.white : const Color(0xFF1F2C34),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(d.isOrder ? Icons.shopping_basket_rounded : Icons.event_available_rounded, color: _rojo, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              d.isOrder ? tr('Pedido') : tr('Cita'),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
          Text(iAmBiz ? tr('Cliente') : d.bizName,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 8),
        if (d.isOrder) ...[
          for (final l in d.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text('${l.qty} × ${l.name}', style: const TextStyle(fontSize: 14))),
                if (l.total != null) Text(bizMoney(l.total!, d.currency), style: const TextStyle(fontSize: 13)),
              ]),
            ),
          const Divider(height: 14),
          Row(children: [
            Text(tr('Total'), style: const TextStyle(fontWeight: FontWeight.w800)),
            const Spacer(),
            Text(total == null ? tr('Por confirmar') : bizMoney(total, d.currency),
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          if (d.address.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('📍 ${d.address}', style: const TextStyle(fontSize: 13)),
          ],
        ] else ...[
          Text(d.service, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          if (d.at != null)
            Text(DateFormat("EEEE d 'de' MMMM · h:mm a", 'es').format(d.at!), style: const TextStyle(fontSize: 14)),
          Text([
            if (d.staff.isNotEmpty) '${tr('Con')} ${d.staff}',
            '${d.minutes} min',
            if (d.price != null) bizMoney(d.price!, d.currency),
          ].join(' · '), style: const TextStyle(fontSize: 13)),
        ],
        if (d.note.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('📝 ${d.note}', style: const TextStyle(fontSize: 13)),
        ],
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Text(d.statusLabel, style: TextStyle(color: statusColor, fontWeight: FontWeight.w800, fontSize: 13)),
        ),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: buttons),
        ],
        if (iAmBiz && d.isOrder && total != null && d.status != BizStatus.rejected && d.status != BizStatus.cancelled)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.menu_book_rounded, size: 18),
              label: Text(tr('Apuntar al fiao')),
              onPressed: () => _toFiao(d),
            ),
          ),
      ]),
    );
  }
}

/// Color de marca de los negocios (para otras pantallas).
const bizRed = _rojo;
const bizBlue = _azul;
