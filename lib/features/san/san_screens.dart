import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/l10n/l10n.dart';
import '../chat/presentation/chat_avatar.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import '../plus/plus_screen.dart';
import '../plus/plus_state.dart';
import 'san.dart';
import 'san_pdf.dart';

const _verde = Color(0xFF1F7A4D);
const _verdeOscuro = Color(0xFF0E4D2F);
const _oro = Color(0xFFE0B54A);
const _rojo = Color(0xFFCE1126);
const _azul = Color(0xFF002D62);

/// Moneda probable según mi número.
String defaultSanCurrency(String phone) {
  if (phone.startsWith('+1809') || phone.startsWith('+1829') || phone.startsWith('+1849')) return 'RD\$';
  if (phone.startsWith('+44')) return '£';
  if (phone.startsWith('+1')) return 'US\$';
  if (phone.startsWith('+3') || phone.startsWith('+4')) return '€';
  return 'RD\$';
}

/// Una persona que puede entrar al san.
class _Person {
  final String id, name;
  bool on = true;
  int numbers = 1;
  String? photo; // miniatura en base64 (solo gente sin KLK)
  _Person(this.id, this.name, {this.photo});

  bool get noKlk => id.startsWith('x:');
}

// =====================================================================
// Fotos de la gente del san
// =====================================================================

final _photoCache = <String, Uint8List>{};

Uint8List? _decodePhoto(String? b64) {
  if (b64 == null || b64.isEmpty) return null;
  final hit = _photoCache[b64];
  if (hit != null) return hit;
  try {
    final bytes = base64Decode(b64);
    if (_photoCache.length > 200) _photoCache.clear();
    return _photoCache[b64] = bytes;
  } catch (_) {
    return null;
  }
}

/// Foto redonda de alguien del san: su foto de perfil de KLK si la tengo,
/// la que le puso quien organiza si no tiene KLK, o su inicial.
class SanAvatar extends ConsumerWidget {
  final String id;
  final String name;
  final String? photo; // base64 (gente sin KLK)
  final double radius;
  const SanAvatar({super.key, required this.id, required this.name, this.photo, this.radius = 18});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = _decodePhoto(photo);
    if (bytes != null) {
      return CircleAvatar(radius: radius, backgroundImage: MemoryImage(bytes));
    }
    final app = ref.read(appProvider);
    final path = id == app.myId ? app.profile.photoPath : app.chatById(id)?.avatarPath;
    return ChatAvatar(id: id, title: name, photoPath: path, radius: radius);
  }
}

/// Foto de la persona con el número de su turno encima.
class _TurnAvatar extends StatelessWidget {
  final int n;
  final Color color;
  final Widget avatar;
  const _TurnAvatar({required this.n, required this.avatar, this.color = _azul});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 44,
        height: 40,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(left: 0, top: 2, child: avatar),
          Positioned(
            right: 0,
            bottom: -2,
            child: Container(
              constraints: const BoxConstraints(minWidth: 20),
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
              ),
              child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      );
}

// =====================================================================
// Crear un san
// =====================================================================

/// Pantalla para armar un san con la gente del chat. Devuelve el san o null.
class SanCreateScreen extends ConsumerStatefulWidget {
  final String chatId;
  final San? copyFrom; // "otra vuelta": mismos datos
  const SanCreateScreen({super.key, required this.chatId, this.copyFrom});

  @override
  ConsumerState<SanCreateScreen> createState() => _SanCreateScreenState();
}

class _SanCreateScreenState extends ConsumerState<SanCreateScreen> {
  final _name = TextEditingController();
  final _amount = TextEditingController();
  String _currency = 'RD\$';
  String _period = '2week';
  late DateTime _start;
  final List<_Person> _people = [];
  List<SanSlot> _order = [];
  bool _drawn = false;
  bool _drawing = false;
  final _rnd = Random.secure();

  @override
  void initState() {
    super.initState();
    final app = ref.read(appProvider);
    final chat = app.chatById(widget.chatId);
    final now = DateTime.now();
    _start = DateTime(now.year, now.month, now.day + 1);
    _currency = defaultSanCurrency(app.session?.phone ?? '');
    final myName = app.profile.name.trim().isEmpty ? tr('Yo') : app.profile.name.trim();
    _people.add(_Person(app.myId, myName));
    if (chat != null) {
      if (chat.isGroup) {
        for (final m in chat.members) {
          final saved = app.chatById(m.id);
          final n = saved != null && saved.title.isNotEmpty ? saved.title : (m.name.isNotEmpty ? m.name : 'Miembro');
          _people.add(_Person(m.id, n));
        }
      } else {
        _people.add(_Person(chat.id, chat.title));
      }
      _name.text = 'San ${chat.isGroup ? chat.title : 'con ${chat.title}'}';
    }
    final c = widget.copyFrom;
    if (c != null) {
      // La gente sin KLK del san anterior (con su foto)
      for (final sl in c.slots) {
        if (sl.id.startsWith('x:') && !_people.any((p) => p.id == sl.id)) {
          _people.add(_Person(sl.id, sl.name, photo: c.photos[sl.id]));
        }
      }
      _name.text = c.name;
      _amount.text = c.amount == c.amount.roundToDouble() ? c.amount.toInt().toString() : c.amount.toString();
      _currency = c.currency;
      _period = c.period;
      final next = c.dateOf(c.rounds);
      _start = next.isAfter(_start) ? next : _start;
      final counts = <String, int>{};
      for (final s in c.slots) {
        counts[s.id] = (counts[s.id] ?? 0) + 1;
      }
      for (final p in _people) {
        p.on = counts.containsKey(p.id);
        p.numbers = counts[p.id] ?? 1;
      }
    }
    _rebuildOrder();
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  double get _amountValue => double.tryParse(_amount.text.replaceAll(' ', '').replaceAll(',', '.')) ?? 0;

  /// Orden sin sortear (en el orden de la lista).
  void _rebuildOrder() {
    _order = [
      for (final p in _people.where((p) => p.on))
        for (var i = 0; i < p.numbers; i++) SanSlot(p.id, p.name),
    ];
    _drawn = false;
  }

  Future<void> _draw() async {
    if (_order.length < 2) return;
    setState(() => _drawing = true);
    // Unas cuantas barajadas rápidas para que se vea el sorteo
    for (var i = 0; i < 9; i++) {
      await Future<void>.delayed(Duration(milliseconds: 70 + i * 18));
      if (!mounted) return;
      HapticFeedback.selectionClick();
      setState(() => _order = [..._order]..shuffle(_rnd));
    }
    HapticFeedback.mediumImpact();
    setState(() {
      _drawing = false;
      _drawn = true;
    });
  }

  /// Añadir gente que no está en el chat: de mis contactos de KLK o solo un nombre.
  Future<void> _addPeople() async {
    final app = ref.read(appProvider);
    final have = {for (final p in _people) p.id};
    final contacts = app.chats
        .where((c) => !c.isGroup && !c.isNotes && !c.blocked && !c.id.startsWith('community:') && !have.contains(c.id))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final picked = await showModalBottomSheet<List<_Person>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddPeopleSheet(contacts: contacts),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      for (final p in picked) {
        if (!_people.any((x) => x.id == p.id)) _people.add(p);
      }
      _rebuildOrder();
    });
  }

  San _build() {
    final app = ref.read(appProvider);
    return San(
      name: _name.text.trim().isEmpty ? 'San' : _name.text.trim(),
      amount: _amountValue,
      currency: _currency,
      period: _period,
      start: _start,
      organizer: app.myId,
      slots: _order,
      photos: {
        for (final p in _people)
          if (p.on && p.noKlk && p.photo != null) p.id: p.photo!,
      },
    );
  }

  int get _photoBytes => _people.fold(0, (n, p) => n + (p.on && p.photo != null ? p.photo!.length : 0));

  /// Ponerle (o quitarle) la foto a alguien que no tiene KLK.
  Future<void> _photoFor(_Person p) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('${tr('Foto de')} ${p.name}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(tr('Elegir de la galería')),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(tr('Hacer una foto')),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          if (p.photo != null)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFFF6B7A)),
              title: Text(tr('Quitar foto'), style: const TextStyle(color: Color(0xFFFF6B7A))),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'remove') {
      setState(() => p.photo = null);
      return;
    }
    try {
      // Miniatura pequeña: el san viaja dentro de un mensaje cifrado.
      final x = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 96,
        maxHeight: 96,
        imageQuality: 70,
      );
      if (x == null || !mounted) return;
      final b64 = base64Encode(await x.readAsBytes());
      if (!mounted) return;
      if (_photoBytes - (p.photo?.length ?? 0) + b64.length > San.maxPhotoBytes) {
        _snack(tr('Ya hay muchas fotos en este san. Quita alguna para poner esta.'));
        return;
      }
      setState(() => p.photo = b64);
    } catch (_) {
      if (mounted) _snack(tr('KLK no tiene permiso para tus fotos o la cámara. Actívalo en Ajustes del iPhone → KLK.'));
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: tr('¿Cuándo es el primer turno?'),
    );
    if (d != null) setState(() => _start = d);
  }

  Future<void> _create() async {
    if (_amountValue <= 0) {
      _snack(tr('Pon cuánto pone cada uno'));
      return;
    }
    if (_order.length < 2) {
      _snack(tr('Hacen falta al menos 2 números'));
      return;
    }
    if (!_drawn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('¿Sin sortear?')),
          content: Text(tr('Los turnos irán en el orden de la lista. Si quieres, sortéalos para que sea justo.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Sortear'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Seguir así'))),
          ],
        ),
      );
      if (ok != true) {
        await _draw();
        return;
      }
    }
    if (mounted) Navigator.pop(context, _build());
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.6);
    final lang = currentLanguageCode();
    final preview = _build();
    final amountOk = _amountValue > 0;

    Widget label(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        );

    return Scaffold(
      appBar: AppBar(title: Text(widget.copyFrom == null ? tr('Nuevo san') : tr('Otra vuelta del san'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 120), children: [
        const _SanHero(),
        label(tr('Nombre')),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          maxLength: 40,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.edit_rounded),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
        ),
        label(tr('¿Cuánto pone cada uno?')),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              decoration: InputDecoration(
                hintText: '1000',
                prefixIcon: const Icon(Icons.savings_rounded),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: [for (final c in const ['RD\$', 'US\$', '€', '£']) ButtonSegment(value: c, label: Text(c))],
          selected: {_currency},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _currency = v.first),
        ),
        label(tr('¿Cada cuánto?')),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'week', label: Text(tr('Semanal'))),
            ButtonSegment(value: '2week', label: Text(tr('Quincenal'))),
            ButtonSegment(value: 'month', label: Text(tr('Mensual'))),
          ],
          selected: {_period},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _period = v.first),
        ),
        const SizedBox(height: 10),
        Material(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          child: ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            leading: const Icon(Icons.event_rounded),
            title: Text(tr('Primer turno')),
            subtitle: Text(sanDate(_start, lang)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _pickDate,
          ),
        ),
        label(tr('¿Quién entra?')),
        Material(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final p in _people)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 4, right: 12),
                leading: Row(mainAxisSize: MainAxisSize.min, children: [
                  Checkbox(
                    value: p.on,
                    onChanged: (v) => setState(() {
                      p.on = v ?? false;
                      _rebuildOrder();
                    }),
                  ),
                  GestureDetector(
                    onTap: p.noKlk ? () => _photoFor(p) : null,
                    child: Stack(clipBehavior: Clip.none, children: [
                      SanAvatar(id: p.id, name: p.name, photo: p.photo, radius: 18),
                      if (p.noKlk)
                        Positioned(
                          right: -3,
                          bottom: -3,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: _verde,
                              shape: BoxShape.circle,
                              border: Border.all(color: cs.surface, width: 1.5),
                            ),
                            child: const Icon(Icons.photo_camera_rounded, size: 10, color: Colors.white),
                          ),
                        ),
                    ]),
                  ),
                ]),
                title: Text(p.id == ref.read(appProvider).myId ? '${p.name} (${tr('tú')})' : p.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: p.on ? Text(p.numbers == 1 ? tr('1 número') : '${p.numbers} ${tr('números')}') : null,
                trailing: !p.on
                    ? null
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: tr('Un número menos'),
                          onPressed: p.numbers <= 1
                              ? null
                              : () => setState(() {
                                    p.numbers--;
                                    _rebuildOrder();
                                  }),
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                        ),
                        Text('${p.numbers}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                        IconButton(
                          tooltip: tr('Un número más'),
                          onPressed: p.numbers >= 4
                              ? null
                              : () => setState(() {
                                    p.numbers++;
                                    _rebuildOrder();
                                  }),
                          icon: const Icon(Icons.add_circle_outline_rounded),
                        ),
                      ]),
                onTap: () => setState(() {
                  p.on = !p.on;
                  _rebuildOrder();
                }),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46), shape: const StadiumBorder()),
          onPressed: _addPeople,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: Text(tr('Añadir más personas')),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text(
              '${tr('Con 2 números, esa persona pone el doble y cobra dos veces.')} '
              '${tr('Puedes añadir gente que no está en este chat (o que no tiene KLK): tú llevas sus pagos. Solo ven el san los de este chat; para que lo vean todos, créalo en un grupo.')} '
              '${tr('A quien no tiene KLK puedes ponerle una foto tocando su círculo.')}',
              style: TextStyle(fontSize: 12.5, color: muted)),
        ),
        Row(children: [
          Expanded(child: label(tr('Turnos'))),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _verde),
              onPressed: _drawing || _order.length < 2 ? null : _draw,
              icon: const Icon(Icons.casino_rounded),
              label: Text(_drawn ? tr('Sortear otra vez') : tr('Sortear')),
            ),
          ),
        ]),
        if (_order.length >= 2)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              _drawn ? tr('¡Sorteado! Mantén pulsado y arrastra si queréis cambiar algún turno.') : tr('Toca «Sortear» para que el orden sea justo.'),
              style: TextStyle(fontSize: 12.5, color: _drawn ? _verde : muted, fontWeight: _drawn ? FontWeight.w700 : null),
            ),
          ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _order.length,
          onReorder: (a, b) => setState(() {
            if (b > a) b--;
            final s = _order.removeAt(a);
            _order.insert(b, s);
          }),
          itemBuilder: (_, i) {
            final s = _order[i];
            return ReorderableDelayedDragStartListener(
              key: ValueKey('$i-${s.id}-${_order.length}'),
              index: i,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: _drawing ? _oro.withValues(alpha: 0.18) : cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ListTile(
                  leading: _TurnAvatar(
                    n: i + 1,
                    avatar: SanAvatar(
                        id: s.id, name: s.name, photo: _people.where((p) => p.id == s.id).firstOrNull?.photo),
                  ),
                  title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(sanDate(preview.dateOf(i), lang)),
                  trailing: amountOk
                      ? Text(preview.money(preview.pot), style: const TextStyle(fontWeight: FontWeight.w800, color: _verde))
                      : const Icon(Icons.drag_indicator_rounded),
                ),
              ),
            );
          },
        ),
        if (amountOk && _order.length >= 2) ...[
          const SizedBox(height: 10),
          _Summary(san: preview),
        ],
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _verde,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: _drawing ? null : _create,
            icon: const Icon(Icons.handshake_rounded),
            label: Text(tr('Crear san y enviarlo al chat'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }
}

class _SanHero extends StatelessWidget {
  const _SanHero();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_verde, _verdeOscuro]),
        ),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.handshake_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              tr('Ahorra con tu gente, como siempre. KLK lleva la cuenta: quién pagó, a quién le toca y cuándo. El dinero lo mueven ustedes.'),
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.35),
            ),
          ),
        ]),
      );
}

class _Summary extends StatelessWidget {
  final San san;
  const _Summary({required this.san});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lang = currentLanguageCode();
    Widget row(IconData i, String t) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(i, size: 18, color: _verde),
            const SizedBox(width: 10),
            Expanded(child: Text(t, style: const TextStyle(fontSize: 14))),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _verde.withValues(alpha: 0.08),
        border: Border.all(color: _verde.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Resumen'), style: TextStyle(fontWeight: FontWeight.w800, color: cs.onSurface)),
        const SizedBox(height: 6),
        row(Icons.payments_rounded, '${tr('Cada número pone')} ${san.money(san.amount)} ${tr(san.periodLabel)}'),
        row(Icons.emoji_events_rounded, '${tr('A quien le toca se lleva')} ${san.money(san.pot)}'),
        row(Icons.repeat_rounded, '${san.rounds} ${tr('turnos')} · ${tr('termina el')} ${sanDate(san.endDate, lang)}'),
      ]),
    );
  }
}

// =====================================================================
// Tarjeta del san dentro del chat
// =====================================================================

class SanCard extends ConsumerWidget {
  final Message message;
  const SanCard({super.key, required this.message});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    final san = San.tryParse(message.media?.san);
    if (san == null) {
      return const Padding(padding: EdgeInsets.all(12), child: Text('San'));
    }
    final now = DateTime.now();
    final lang = currentLanguageCode();
    final me = app.myId;
    final r = san.currentRound(now);
    final started = san.started(now);
    final finished = san.finished(now);
    final receiver = san.slots[r];
    final mine = san.slotsOf(me);
    final owe = mine.where((s) => san.payOf(r, s) == SanPay.none).toList();
    final claimed = mine.where((s) => san.payOf(r, s) == SanPay.claimed).toList();
    final paid = san.paidCount(r);
    final organizerName = san.organizer == me
        ? tr('ti')
        : (san.slots.where((s) => s.id == san.organizer).map((s) => s.name).firstOrNull ?? message.sender);

    String headline;
    String sub;
    if (finished) {
      headline = tr('¡San terminado!');
      sub = '${san.rounds} ${tr('turnos')} · ${tr('todos cobraron')}';
    } else if (!started) {
      headline = '${tr('Empieza el')} ${sanDate(san.dateOf(0), lang)}';
      sub = '${tr('Primer turno')}: ${receiver.id == me ? tr('¡tú!') : receiver.name}';
    } else {
      headline = receiver.id == me ? tr('¡Te toca a ti!') : '${tr('Le toca a')} ${receiver.name}';
      sub = '${tr('Turno')} ${r + 1} ${tr('de')} ${san.rounds} · ${sanDate(san.dateOf(r), lang)}';
    }

    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SanDetailScreen(chatId: message.chatId, messageId: message.id))),
      child: Container(
        width: 268,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: finished ? const [Color(0xFF3A3A3A), Color(0xFF1E1E1E)] : const [_verde, _verdeOscuro],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration:
                    BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(11)),
                child: const Icon(Icons.handshake_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(san.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w800)),
                  Text('${san.money(san.amount)} ${tr(san.periodLabel)} · ${tr('organiza')} $organizerName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Text(headline, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
            child: Text(sub, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          if (!finished)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: _oro, borderRadius: BorderRadius.circular(20)),
                child: Text('${tr('Se lleva')} ${san.money(san.pot)}',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            ),
          // Turnos: una rayita por turno
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Row(children: [
              for (var i = 0; i < san.rounds; i++)
                Expanded(
                  child: Container(
                    height: 5,
                    margin: EdgeInsets.only(right: i == san.rounds - 1 ? 0 : 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: san.roundComplete(i)
                          ? _oro
                          : (i == r && started && !finished ? Colors.white : Colors.white.withValues(alpha: 0.25)),
                    ),
                  ),
                ),
            ]),
          ),
          if (started && !finished)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text('${tr('Pagaron')} $paid ${tr('de')} ${san.slots.length} ${tr('este turno')}',
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 10),
          if (!finished && started && owe.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: _verdeOscuro),
                  onPressed: () async {
                    for (final s in owe) {
                      await app.sanAction(message, {
                        'a': 'pay',
                        'r': r,
                        's': s,
                        'v': san.organizer == me ? SanPay.paid.name : SanPay.claimed.name,
                      });
                    }
                    HapticFeedback.mediumImpact();
                  },
                  icon: const Icon(Icons.check_circle_rounded),
                  label: Text(san.organizer == me
                      ? tr('Marcar mi pago')
                      : '${tr('Ya pagué')} ${san.money(san.amount * owe.length)}'),
                ),
              ),
            )
          else if (!finished && started && claimed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Row(children: [
                const Icon(Icons.schedule_rounded, color: Colors.white70, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(tr('Avisaste que pagaste. Falta que lo confirme quien organiza.'),
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ),
              ]),
            ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.18)))),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(tr('Ver todo el san'),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// =====================================================================
// Todo el san: turnos, pagos y acciones
// =====================================================================

class SanDetailScreen extends ConsumerStatefulWidget {
  final String chatId;
  final String messageId;
  const SanDetailScreen({super.key, required this.chatId, required this.messageId});

  @override
  ConsumerState<SanDetailScreen> createState() => _SanDetailScreenState();
}

class _SanDetailScreenState extends ConsumerState<SanDetailScreen> {
  int? _open;

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _tapSlot(Message m, San san, int r, int s) async {
    final app = ref.read(appProvider);
    final me = app.myId;
    final cur = san.payOf(r, s);
    final organizer = san.organizer == me;
    String? v;
    if (organizer) {
      v = cur == SanPay.paid ? SanPay.none.name : SanPay.paid.name;
    } else if (san.slots[s].id == me) {
      if (cur == SanPay.paid) {
        _snack(tr('Ya está confirmado. Solo quien organiza puede cambiarlo.'));
        return;
      }
      v = cur == SanPay.claimed ? SanPay.none.name : SanPay.claimed.name;
    } else {
      _snack(tr('Solo quien organiza puede marcar los pagos de los demás.'));
      return;
    }
    HapticFeedback.selectionClick();
    await app.sanAction(m, {'a': 'pay', 'r': r, 's': s, 'v': v});
  }

  Future<void> _remind(Message m, San san, int r, {bool started = true}) async {
    if (!started) {
      // Antes de empezar: aviso para que todos tengan el dinero listo.
      final lang = currentLanguageCode();
      final text = '⏰ ${tr('Recordatorio del san')} «${san.name}»\n'
          '${tr('Empieza el')} ${sanDate(san.dateOf(0), lang)}. '
          '${tr('Turno')} 1: ${tr('le toca a')} ${san.slots[0].name}.\n'
          '${tr('Cada número')}: ${san.money(san.amount)}. ${tr('¡Tengan el dinero listo!')} 🙏';
      await ref.read(appProvider).sendText(widget.chatId, text);
      _snack(tr('Recordatorio enviado al chat'));
      return;
    }
    final pending = <String>{
      for (var s = 0; s < san.slots.length; s++)
        if (san.payOf(r, s) != SanPay.paid) san.slots[s].name,
    }.toList();
    if (pending.isEmpty) {
      _snack(tr('¡Todos pagaron este turno! 🎉'));
      return;
    }
    final lang = currentLanguageCode();
    final text = '⏰ ${tr('Recordatorio del san')} «${san.name}»\n'
        '${tr('Turno')} ${r + 1}: ${tr('le toca a')} ${san.slots[r].name} (${sanDate(san.dateOf(r), lang)}).\n'
        '${tr('Faltan por pagar')}: ${pending.join(', ')}. ${tr('Cada número')}: ${san.money(san.amount)}. 🙏';
    await ref.read(appProvider).sendText(widget.chatId, text);
    _snack(tr('Recordatorio enviado al chat'));
  }

  Future<void> _end(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('¿Terminar el san?')),
        content: Text(tr('Se marcará como terminado para todos. Los pagos apuntados se quedan como están.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _rojo),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Terminar'))),
        ],
      ),
    );
    if (ok == true) await ref.read(appProvider).sanAction(m, {'a': 'end'});
  }

  // ---------- Entregar el dinero del turno ----------

  Future<void> _sendPayout(Message m, San san, int r) async {
    final app = ref.read(appProvider);
    final who = san.slots[r];
    final bank = app.sanBankOf(m.id, who.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.send_rounded, color: _verde),
        title: Text('${tr('Enviar')} ${san.money(san.pot)} ${tr('a')} ${who.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (bank != null) ...[
            _BankBox(bank: bank, full: true),
            const SizedBox(height: 12),
          ] else if (!who.id.startsWith('x:') && who.id != app.myId) ...[
            Text('${who.name} ${tr('aún no ha puesto su cuenta en KLK. Pídesela antes de enviar.')}'),
            const SizedBox(height: 12),
          ],
          Text(tr('Envía el dinero desde tu banco como siempre. Cuando lo hayas hecho, toca «Ya lo envié» y le avisamos en el chat.')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Todavía no'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _verde),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Ya lo envié')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!await app.sanAction(m, {'a': 'sent', 'r': r})) return;
    HapticFeedback.mediumImpact();
    await app.sendText(widget.chatId,
        '💸 ${tr('Dinero del san')} «${san.name}» ${tr('enviado a')} ${who.name}: ${san.money(san.pot)}.\n${who.name}, ${tr('revisa tu cuenta')} 🙏');
  }

  Future<void> _confirmGot(Message m, San san, int r) async {
    final app = ref.read(appProvider);
    if (!await app.sanAction(m, {'a': 'got', 'r': r})) return;
    HapticFeedback.mediumImpact();
    await app.sendText(widget.chatId, '✅ ${tr('Me llegó el dinero del san')} «${san.name}»: ${san.money(san.pot)}. ${tr('¡Gracias!')} 🎉');
  }

  Future<void> _undoSent(Message m, int r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('¿Desmarcar el envío?')),
        content: Text(tr('Úsalo solo si lo marcaste por error.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Desmarcar'))),
        ],
      ),
    );
    if (ok == true) await ref.read(appProvider).sanAction(m, {'a': 'unsent', 'r': r});
  }

  Future<void> _editBank(Message m, San san) async {
    final app = ref.read(appProvider);
    final current = app.sanBankOf(m.id, app.myId);
    final chat = app.chatById(widget.chatId);
    final organizerName = chat != null && !chat.isGroup
        ? chat.title
        : (san.slots.where((x) => x.id == san.organizer).firstOrNull?.name ?? tr('quien organiza'));
    final result = await showModalBottomSheet<(bool, SanBank?)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BankSheet(initial: current ?? app.myLastSanBank, organizer: organizerName, canDelete: current != null),
    );
    if (result == null) return;
    final ok = await app.shareSanBank(m, result.$2);
    _snack(!ok
        ? tr('No se pudo enviar. Revisa la conexión e inténtalo otra vez.')
        : result.$2 == null
            ? tr('Cuenta borrada')
            : '${tr('Cuenta guardada. Solo la ve')} $organizerName 🔒');
  }

  Widget _payout(Message m, San san, int i, bool organizer, String me, Color muted) {
    final app = ref.read(appProvider);
    final who = san.slots[i];
    final out = san.outOf(i);
    final bank = organizer ? app.sanBankOf(m.id, who.id) : null;
    final children = <Widget>[];
    if (out == 'got') {
      children.add(_Status(Icons.verified_rounded, _oro, '${who.name} ${tr('confirmó que le llegó el dinero')} 🎉'));
    } else if (out == 'sent') {
      children.add(_Status(Icons.send_rounded, _verde, '${tr('Dinero enviado')} · ${tr('esperando que')} ${who.name} ${tr('confirme')}'));
      if (who.id == me) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _verde, minimumSize: const Size.fromHeight(46)),
            onPressed: () => _confirmGot(m, san, i),
            icon: const Icon(Icons.check_circle_rounded),
            label: Text(tr('Me llegó el dinero')),
          ),
        ));
      }
      if (organizer) {
        children.add(Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => _undoSent(m, i), child: Text(tr('Desmarcar envío'))),
        ));
      }
    } else if (organizer) {
      if (who.id != me) {
        children.add(bank != null
            ? _BankBox(bank: bank)
            : Text(
                who.id.startsWith('x:')
                    ? '${who.name} ${tr('no tiene KLK: pídele la cuenta por fuera.')}'
                    : '${who.name} ${tr('aún no ha puesto su cuenta para cobrar.')}',
                style: TextStyle(fontSize: 12.5, color: muted)));
        children.add(const SizedBox(height: 8));
      }
      children.add(FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: _verde, minimumSize: const Size.fromHeight(46)),
        onPressed: san.roundComplete(i) ? () => _sendPayout(m, san, i) : null,
        icon: const Icon(Icons.send_rounded),
        label: Text(san.roundComplete(i)
            ? '${tr('Enviar')} ${san.money(san.pot)} ${tr('a')} ${who.name}'
            : tr('Cuando paguen todos, podrás enviarlo')),
      ));
    } else if (san.roundComplete(i)) {
      children.add(_Status(Icons.savings_rounded, _verde, tr('¡Ya pagaron todos! Falta que quien organiza lo envíe.')));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Future<void> _again(San san) async {
    final next = await Navigator.of(context).push<San>(
        MaterialPageRoute(builder: (_) => SanCreateScreen(chatId: widget.chatId, copyFrom: san)));
    if (next == null || !mounted) return;
    await ref.read(appProvider).sendSan(widget.chatId, next);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.6);
    final lang = currentLanguageCode();
    final m = app.messagesFor(widget.chatId).where((x) => x.id == widget.messageId).firstOrNull;
    final san = San.tryParse(m?.media?.san);
    if (m == null || san == null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text(tr('Este san ya no está en el chat'))));
    }
    final now = DateTime.now();
    final me = app.myId;
    final r = san.currentRound(now);
    final started = san.started(now);
    final finished = san.finished(now);
    final organizer = san.organizer == me;
    final mine = san.slotsOf(me);
    final open = _open ?? r;
    final collected = [for (var i = 0; i < san.rounds; i++) i].where(san.roundComplete).length;
    // Lo que yo he puesto y lo que me toca cobrar
    var iPaid = 0;
    for (var i = 0; i < san.rounds; i++) {
      for (final s in mine) {
        if (san.payOf(i, s) == SanPay.paid) iPaid++;
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(san.name)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
        // Cabecera
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: finished ? const [Color(0xFF3A3A3A), Color(0xFF1E1E1E)] : const [_verde, _verdeOscuro],
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (started && !finished)
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: SanAvatar(id: san.slots[r].id, name: san.slots[r].name, photo: san.photos[san.slots[r].id], radius: 20),
                )
              else
                const Icon(Icons.handshake_rounded, color: Colors.white, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  finished
                      ? tr('¡San terminado!')
                      : !started
                          ? '${tr('Empieza el')} ${sanDate(san.dateOf(0), lang)}'
                          : (san.slots[r].id == me ? tr('¡Te toca a ti!') : '${tr('Le toca a')} ${san.slots[r].name}'),
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Pill(Icons.payments_rounded, '${san.money(san.amount)} ${tr(san.periodLabel)}'),
              _Pill(Icons.emoji_events_rounded, '${tr('Se lleva')} ${san.money(san.pot)}'),
              _Pill(Icons.flag_rounded, '$collected/${san.rounds} ${tr('cobrados')}'),
              _Pill(Icons.event_available_rounded, '${tr('Termina')} ${sanDate(san.endDate, lang)}'),
            ]),
            if (mine.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${tr('Tus números')}: ${mine.map((s) => '#${s + 1} (${sanDate(san.dateOf(s), lang)})').join(', ')} · '
                '${tr('has puesto')} ${san.money(san.amount * iPaid)}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ]),
        ),
        if (organizer && !finished)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _remind(m, san, r, started: started),
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: Text(tr('Recordar')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: _rojo),
                  onPressed: () => _end(m),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(tr('Terminar')),
                ),
              ),
            ]),
          ),
        if (organizer && finished)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _verde, minimumSize: const Size.fromHeight(48)),
              onPressed: () => _again(san),
              icon: const Icon(Icons.replay_rounded),
              label: Text(tr('Otra vuelta')),
            ),
          ),
        if (mine.isNotEmpty && !organizer && !finished)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Builder(builder: (_) {
              final myBank = app.sanBankOf(m.id, me);
              return Material(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  onTap: () => _editBank(m, san),
                  leading: const CircleAvatar(
                    backgroundColor: _verde,
                    child: Icon(Icons.account_balance_rounded, color: Colors.white, size: 20),
                  ),
                  title: Text(myBank == null ? tr('Pon tu cuenta para cobrar') : tr('Tu cuenta para cobrar'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(myBank == null
                      ? tr('Así te envían el dinero cuando te toque. Solo la ve quien organiza 🔒')
                      : '${myBank.holder.isEmpty ? '' : '${myBank.holder} · '}${myBank.account.isEmpty ? myBank.note : myBank.masked}'),
                  trailing: Icon(myBank == null ? Icons.add_circle_outline_rounded : Icons.edit_rounded),
                ),
              );
            }),
          ),
        // Extras de KLK Plus
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              if (organizer && !finished)
                SwitchListTile(
                  secondary: const Icon(Icons.alarm_on_rounded),
                  title: Row(children: [
                    Flexible(child: Text(tr('Recordatorios automáticos'), style: const TextStyle(fontWeight: FontWeight.w700))),
                    if (!plusActive.value) ...[const SizedBox(width: 6), const PlusMark(size: 16)],
                  ]),
                  subtitle: Text(tr('El día antes de cada turno, KLK avisa en el chat a quien falte por pagar.')),
                  value: plusActive.value && app.sanAutoOn(m.id),
                  onChanged: (v) => plusActive.value
                      ? app.setSanAuto(m.id, v)
                      : showPlusRequired(context, tr('Los recordatorios automáticos')),
                ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_rounded),
                title: Row(children: [
                  Flexible(child: Text(tr('Historial en PDF'), style: const TextStyle(fontWeight: FontWeight.w700))),
                  if (!plusActive.value) ...[const SizedBox(width: 6), const PlusMark(size: 16)],
                ]),
                subtitle: Text(tr('Quién pagó cada turno y a quién se entregó. Para guardarlo o mandarlo.')),
                trailing: const Icon(Icons.ios_share_rounded),
                onTap: () => plusActive.value
                    ? shareSanPdf(context, san, chatTitle: app.chatById(widget.chatId)?.title ?? '')
                    : showPlusRequired(context, tr('El historial en PDF')),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 4),
          child: Text(tr('Turnos'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            organizer
                ? tr('Toca a cada persona para marcar que pagó (o quitarlo).')
                : tr('Toca tu nombre para avisar que ya pagaste. Quien organiza lo confirma.'),
            style: TextStyle(fontSize: 12.5, color: muted),
          ),
        ),
        for (var i = 0; i < san.rounds; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: i == r && started && !finished
                  ? _verde.withValues(alpha: 0.12)
                  : cs.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                ListTile(
                  onTap: () => setState(() => _open = open == i ? -1 : i),
                  leading: _TurnAvatar(
                      n: i + 1,
                      avatar: SanAvatar(id: san.slots[i].id, name: san.slots[i].name, photo: san.photos[san.slots[i].id]),
                      color: san.roundComplete(i) ? _oro : (i == r && started && !finished ? _verde : _azul)),
                  title: Text(san.slots[i].id == me ? '${san.slots[i].name} (${tr('tú')})' : san.slots[i].name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      '${sanDate(san.dateOf(i), lang)} · ${san.paidCount(i)}/${san.slots.length} ${tr('pagaron')}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (san.outOf(i) == 'got')
                      const Icon(Icons.savings_rounded, color: _oro)
                    else if (san.outOf(i) == 'sent')
                      const Icon(Icons.send_rounded, color: _verde)
                    else if (san.roundComplete(i))
                      const Icon(Icons.verified_rounded, color: _oro)
                    else if (i == r && started && !finished)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: _verde, borderRadius: BorderRadius.circular(12)),
                        child: Text(tr('Ahora'),
                            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800)),
                      ),
                    Icon(open == i ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                  ]),
                ),
                if (open == i)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Column(children: [
                      for (var s = 0; s < san.slots.length; s++)
                        _PayRow(
                          slot: san.slots[s],
                          photo: san.photos[san.slots[s].id],
                          number: s + 1,
                          pay: san.payOf(i, s),
                          me: san.slots[s].id == me,
                          amount: san.money(san.amount),
                          onTap: finished ? null : () => _tapSlot(m, san, i, s),
                        ),
                      _payout(m, san, i, organizer, me, muted),
                    ]),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          tr('KLK solo lleva la cuenta del san. El dinero se mueve entre ustedes como siempre (en mano, por banco…). Todo va cifrado: KLK no ve cuánto ponen.'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Pill(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white, size: 15),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _Status extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Status(this.icon, this.color, this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5))),
        ]),
      );
}

/// Los datos para cobrar de alguien (solo los ve quien organiza), con botón de copiar.
class _BankBox extends StatelessWidget {
  final SanBank bank;
  final bool full;
  const _BankBox({required this.bank, this.full = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget line(String label, String value, {bool copy = false}) => Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(children: [
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '$label: ', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6), fontSize: 12.5)),
                TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              ])),
            ),
            if (copy)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: tr('Copiar'),
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value.replaceAll(' ', '')));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copiado'))));
                },
              ),
          ]),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _verde.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.lock_rounded, size: 14, color: _verde),
          const SizedBox(width: 4),
          Text(tr('Cuenta para cobrar · solo la ves tú'),
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: _verde)),
        ]),
        if (bank.holder.isNotEmpty) line(tr('Titular'), bank.holder),
        if (bank.account.isNotEmpty) line(tr('Cuenta'), full ? bank.account : bank.masked, copy: full),
        if (bank.bank.isNotEmpty) line(tr('Banco'), bank.bank),
        if (bank.note.isNotEmpty) line(tr('Otra forma'), bank.note, copy: full),
      ]),
    );
  }
}

/// Formulario de MIS datos para cobrar el san.
class _BankSheet extends StatefulWidget {
  final SanBank? initial;
  final String organizer;
  final bool canDelete;
  const _BankSheet({required this.initial, required this.organizer, required this.canDelete});

  @override
  State<_BankSheet> createState() => _BankSheetState();
}

class _BankSheetState extends State<_BankSheet> {
  late final _holder = TextEditingController(text: widget.initial?.holder ?? '');
  late final _account = TextEditingController(text: widget.initial?.account ?? '');
  late final _bank = TextEditingController(text: widget.initial?.bank ?? '');
  late final _note = TextEditingController(text: widget.initial?.note ?? '');

  @override
  void dispose() {
    _holder.dispose();
    _account.dispose();
    _bank.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _valid => _holder.text.trim().isNotEmpty && (_account.text.trim().length >= 6 || _note.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    InputDecoration deco(String label, IconData icon, {String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Tu cuenta para cobrar'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lock_rounded, size: 16, color: _verde),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${tr('Solo la verá')} ${widget.organizer}, ${tr('para enviarte el dinero cuando te toque. Va cifrada: ni KLK ni los demás del san la ven.')}',
                  style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.7)),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            TextField(
              controller: _holder,
              textCapitalization: TextCapitalization.words,
              decoration: deco(tr('Titular de la cuenta'), Icons.person_rounded),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _account,
              textCapitalization: TextCapitalization.characters,
              decoration: deco(tr('IBAN o número de cuenta'), Icons.account_balance_rounded, hint: 'ES12 3456 7890 …'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _bank,
              textCapitalization: TextCapitalization.words,
              decoration: deco(tr('Banco (opcional)'), Icons.apartment_rounded, hint: 'Banreservas, Popular, BBVA…'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              decoration: deco(tr('Otra forma (opcional)'), Icons.phone_iphone_rounded, hint: 'Bizum, Zelle, Revolut…'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _verde, minimumSize: const Size.fromHeight(50)),
              onPressed: !_valid
                  ? null
                  : () => Navigator.pop(
                        context,
                        (
                          true,
                          SanBank(
                            holder: _holder.text.trim(),
                            account: _account.text.trim().toUpperCase(),
                            bank: _bank.text.trim(),
                            note: _note.text.trim(),
                            at: DateTime.now(),
                          ),
                        ),
                      ),
              child: Text(tr('Guardar')),
            ),
            if (widget.canDelete)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: _rojo),
                onPressed: () => Navigator.pop(context, (true, null)),
                child: Text(tr('Borrar mi cuenta de este san')),
              ),
          ]),
        ),
      ),
    );
  }
}

class _PayRow extends StatelessWidget {
  final SanSlot slot;
  final int number;
  final SanPay pay;
  final bool me;
  final String amount;
  final String? photo;
  final VoidCallback? onTap;
  const _PayRow(
      {required this.slot,
      required this.number,
      required this.pay,
      required this.me,
      required this.amount,
      this.photo,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (pay) {
      SanPay.paid => (Icons.check_circle_rounded, _verde, tr('Pagó')),
      SanPay.claimed => (Icons.schedule_rounded, const Color(0xFFE0A030), tr('Dice que pagó')),
      SanPay.none => (Icons.radio_button_unchecked_rounded, Colors.grey, tr('Falta')),
    };
    return ListTile(
      dense: true,
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: SanAvatar(id: slot.id, name: slot.name, photo: photo, radius: 16),
      title: Text(me ? '${slot.name} (${tr('tú')})' : slot.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('#$number · $amount'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
        const SizedBox(width: 6),
        Icon(icon, color: color),
      ]),
    );
  }
}

/// Hoja para añadir personas al san (contactos de KLK o un nombre a mano).
class _AddPeopleSheet extends StatefulWidget {
  final List<Chat> contacts;
  const _AddPeopleSheet({required this.contacts});

  @override
  State<_AddPeopleSheet> createState() => _AddPeopleSheetState();
}

class _AddPeopleSheetState extends State<_AddPeopleSheet> {
  final _name = TextEditingController();
  final _chosen = <String>{};
  final _typed = <_Person>[];
  String _q = '';
  final _rnd = Random();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _addTyped() {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    setState(() {
      _typed.add(_Person('x:${DateTime.now().microsecondsSinceEpoch}${_rnd.nextInt(999)}', n));
      _name.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.6);
    final q = _q.trim().toLowerCase();
    final list = widget.contacts.where((c) => q.isEmpty || c.title.toLowerCase().contains(q)).toList();
    final count = _chosen.length + _typed.length + (_name.text.trim().isEmpty ? 0 : 1);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(tr('Añadir al san'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      hintText: tr('Escribe un nombre (no necesita KLK)'),
                      prefixIcon: const Icon(Icons.person_outline_rounded),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onSubmitted: (_) => _addTyped(),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(onPressed: _addTyped, icon: const Icon(Icons.add_rounded)),
              ]),
            ),
            if (_typed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final p in _typed)
                    InputChip(label: Text(p.name), onDeleted: () => setState(() => _typed.remove(p))),
                ]),
              ),
            if (widget.contacts.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('O elige de tus contactos de KLK'),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: muted)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: tr('Buscar'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onChanged: (v) => setState(() => _q = v),
                ),
              ),
            ],
            Expanded(
              child: ListView(children: [
                for (final c in list)
                  CheckboxListTile(
                    value: _chosen.contains(c.id),
                    onChanged: (v) => setState(() => v == true ? _chosen.add(c.id) : _chosen.remove(c.id)),
                    secondary: ChatAvatar(id: c.id, title: c.title, photoPath: c.avatarPath, radius: 18),
                    title: Text(c.title),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _verde, minimumSize: const Size.fromHeight(50)),
                onPressed: count == 0
                    ? null
                    : () {
                        _addTyped();
                        Navigator.pop(context, [
                          for (final c in widget.contacts.where((c) => _chosen.contains(c.id))) _Person(c.id, c.title),
                          ..._typed,
                        ]);
                      },
                child: Text(count == 0 ? tr('Elige o escribe a alguien') : '${tr('Añadir')} ($count)'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
