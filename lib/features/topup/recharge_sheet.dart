import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../../core/util/phone.dart';
import '../chat/presentation/chat_sheets.dart';
import '../messaging/app_controller.dart';

/// ¿Es un móvil de RD? (+1 809/829/849)
bool isDominicanMobile(String phone) => RegExp(r'^\+1(809|829|849)\d{7}$').hasMatch(phone);

/// Normaliza lo que escribe la persona: "809 555 1234" → +18095551234.
String normalizeDrPhone(String raw) {
  final d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.length == 10) return '+1$d';
  if (d.length == 11 && d.startsWith('1')) return '+$d';
  return '+$d';
}

String formatMoney(int cents, String currency) {
  final v = (cents / 100).toStringAsFixed(2).replaceAll('.', ',');
  return switch (currency.toUpperCase()) {
    'EUR' => '$v €',
    'USD' => 'US\$$v',
    _ => '$v $currency',
  };
}

String shortOperator(String name) {
  final n = name.replaceAll(RegExp(r'(República Dominicana|Dominican Republic|Dominicana)', caseSensitive: false), '').trim();
  return n.isEmpty ? name : n;
}

/// Abre la hoja de recarga. Si el chat es con alguien de RD, su número viene puesto.
Future<void> showRechargeSheet(BuildContext context, {String? chatId}) async {
  final container = ProviderScope.containerOf(context);
  final app = container.read(appProvider);
  if (app.topupApi == null) {
    return showMoneyInfo(context, recharge: true);
  }
  final chat = chatId == null ? null : app.chatById(chatId);
  final phone = (chat != null && !chat.isGroup && isDominicanMobile(chat.phone)) ? chat.phone : '';
  final done = await showModalBottomSheet<_Done>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _RechargeSheet(initialPhone: phone),
  );
  if (done == null || done.off || !context.mounted) {
    if (done?.off == true && context.mounted) await showMoneyInfo(context, recharge: true);
    return;
  }
  // Aviso en el chat para la persona recargada.
  if (chat != null && !chat.isGroup && chat.phone == done.phone) {
    await app.sendText(chat.id,
        '📱 ¡Te puse una recarga de RD\$${done.amount} a tu ${shortOperator(done.operator)}! Ya debería estar en tu saldo 🇩🇴');
  }
}

class _Done {
  final bool off;
  final String phone, operator, amount;
  const _Done({this.off = false, this.phone = '', this.operator = '', this.amount = ''});
}

enum _Step { phone, amounts, paying, done, failed }

class _RechargeSheet extends ConsumerStatefulWidget {
  final String initialPhone;
  const _RechargeSheet({required this.initialPhone});

  @override
  ConsumerState<_RechargeSheet> createState() => _RechargeSheetState();
}

class _RechargeSheetState extends ConsumerState<_RechargeSheet> with WidgetsBindingObserver {
  late final _phone = TextEditingController(text: widget.initialPhone.isEmpty ? '' : prettyPhone(widget.initialPhone));
  _Step _step = _Step.phone;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _quote;
  Map<String, dynamic>? _choice;
  String? _orderId;
  String? _payUrl;
  Timer? _poll;
  DateTime? _pollUntil;

  ApiClient get _api => ref.read(appProvider).topupApi!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialPhone.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _lookup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _phone.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver del navegador se mira enseguida si ya pagó.
    if (state == AppLifecycleState.resumed && _step == _Step.paying) _check();
  }

  String get _currency => (_quote?['currency'] as String?) ?? 'EUR';
  bool get _test => _quote?['test'] == true;

  Future<void> _lookup() async {
    final phone = normalizeDrPhone(_phone.text);
    if (!isDominicanMobile(phone)) {
      setState(() => _error = 'Escribe un móvil de RD: 809, 829 o 849 y 7 números más');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final q = await _api.topupQuote(phone);
      if (!mounted) return;
      setState(() {
        _quote = q;
        _choice = null;
        _step = _Step.amounts;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'topups_off') {
        Navigator.pop(context, const _Done(off: true));
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pay() async {
    final q = _quote!, c = _choice!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _api.createTopup(q['phone'] as String, c['amount'] as num);
      _orderId = (r['topup'] as Map<String, dynamic>)['id'] as String;
      _payUrl = r['payUrl'] as String;
      if (!mounted) return;
      setState(() => _step = _Step.paying);
      _pollUntil = DateTime.now().add(const Duration(minutes: 35));
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _check());
      await _openPay();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPay() async {
    final url = Uri.parse(_payUrl!);
    final ok = await launchUrl(url, mode: LaunchMode.inAppBrowserView).catchError((_) => false);
    if (!ok) await launchUrl(url, mode: LaunchMode.externalApplication).catchError((_) => false);
  }

  bool _checking = false;
  Future<void> _check() async {
    if (_orderId == null || _checking) return;
    if (_pollUntil != null && DateTime.now().isAfter(_pollUntil!)) {
      _poll?.cancel();
      return;
    }
    _checking = true;
    try {
      final t = await _api.topup(_orderId!);
      if (!mounted) return;
      final status = t['status'] as String? ?? '';
      if (status == 'done') {
        _poll?.cancel();
        _closeBrowser();
        setState(() => _step = _Step.done);
      } else if (status == 'failed' || status == 'refunded' || status == 'expired') {
        _poll?.cancel();
        _closeBrowser();
        setState(() {
          _step = _Step.failed;
          _error = status == 'expired'
              ? 'Se acabó el tiempo para pagar. No se cobró nada.'
              : 'La compañía no aceptó la recarga. Te devolvemos el dinero a tu tarjeta (tarda unos días).';
        });
      } else if (status == 'paid') {
        _closeBrowser();
      }
    } catch (_) {
      // Sin conexión un momento: se vuelve a mirar en 3 s.
    } finally {
      _checking = false;
    }
  }

  void _closeBrowser() {
    closeInAppWebView().catchError((_) {});
  }

  void _finish() {
    final q = _quote!;
    Navigator.pop(
        context,
        _Done(
          phone: q['phone'] as String,
          operator: q['operator'] as String? ?? '',
          amount: (_choice!['amount'] as num).toStringAsFixed(0),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 0, 22, 18 + bottom),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.phone_iphone, color: Color(0xFF1F7A4D), size: 30),
              const SizedBox(width: 10),
              const Expanded(
                  child: Text('Recarga a RD', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
              if (_test)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFFFFD60A), borderRadius: BorderRadius.circular(99)),
                  child: const Text('MODO PRUEBA',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black)),
                ),
            ]),
            const SizedBox(height: 4),
            Text('Claro, Altice y Viva', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 16),
            ...switch (_step) {
              _Step.phone || _Step.amounts => _chooser(cs),
              _Step.paying => _paying(cs),
              _Step.done => _doneView(cs),
              _Step.failed => _failedView(cs),
            },
          ]),
        ),
      ),
    );
  }

  List<Widget> _chooser(ColorScheme cs) {
    final q = _quote;
    final options = ((q?['options'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return [
      TextField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        autofocus: widget.initialPhone.isEmpty,
        decoration: InputDecoration(
          labelText: 'Número de RD',
          hintText: '809 555 1234',
          prefixIcon: const Icon(Icons.call_outlined),
          border: const OutlineInputBorder(),
          suffixIcon: _step == _Step.amounts
              ? IconButton(
                  tooltip: 'Cambiar número',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => setState(() {
                        _step = _Step.phone;
                        _quote = null;
                      }))
              : null,
        ),
        readOnly: _step == _Step.amounts,
        onSubmitted: (_) => _lookup(),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: TextStyle(color: cs.error)),
      ],
      const SizedBox(height: 14),
      if (_step == _Step.phone)
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: const StadiumBorder()),
          onPressed: _busy ? null : _lookup,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Seguir', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        )
      else ...[
        Row(children: [
          const Icon(Icons.cell_tower, size: 18),
          const SizedBox(width: 6),
          Text(shortOperator(q?['operator'] as String? ?? ''), style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final o in options)
            ChoiceChip(
              label: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('RD\$${(o['amount'] as num).toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                Text(formatMoney((o['priceCents'] as num).toInt(), _currency), style: const TextStyle(fontSize: 12)),
              ]),
              selected: identical(_choice, o),
              onSelected: (_) => setState(() => _choice = o),
            ),
        ]),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
          onPressed: _busy || _choice == null ? null : _pay,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.lock_outline),
          label: Text(
            _choice == null
                ? 'Elige cuánto'
                : 'Pagar ${formatMoney((_choice!['priceCents'] as num).toInt(), _currency)}',
            style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _test
              ? 'Modo prueba: no se cobra nada y no llega saldo de verdad.'
              : 'Pagas con tarjeta, Apple Pay o Google Pay en una página segura. KLK no guarda tu tarjeta.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6)),
        ),
      ],
    ];
  }

  List<Widget> _paying(ColorScheme cs) => [
        const SizedBox(height: 8),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 16),
        const Text('Esperando el pago…',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Cuando pagues, vuelve aquí. La recarga llega en unos segundos.',
            textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65))),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: _openPay, child: const Text('Abrir la página de pago otra vez')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
      ];

  List<Widget> _doneView(ColorScheme cs) => [
        const Icon(Icons.check_circle, size: 64, color: Color(0xFF1F7A4D)),
        const SizedBox(height: 10),
        Text('¡Recarga hecha! RD\$${(_choice!['amount'] as num).toStringAsFixed(0)}',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('${shortOperator(_quote!['operator'] as String? ?? '')} · ${prettyPhone(_quote!['phone'] as String)}',
            textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65))),
        const SizedBox(height: 18),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50), shape: const StadiumBorder()),
          onPressed: _finish,
          child: const Text('Listo'),
        ),
      ];

  List<Widget> _failedView(ColorScheme cs) => [
        Icon(Icons.error_outline, size: 60, color: cs.error),
        const SizedBox(height: 10),
        const Text('No se pudo recargar',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(_error ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 18),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
      ];
}
