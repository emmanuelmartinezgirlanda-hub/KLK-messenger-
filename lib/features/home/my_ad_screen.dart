import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:klk_native/klk_native.dart';

import '../../core/l10n/l10n.dart';
import '../../core/network/api_client.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import 'ads_carousel.dart';

/// «Anúnciate en KLK»: el negocio crea su anuncio, paga la suscripción
/// «KLK Anuncios» (aparte de Plus, la cobra Apple o Google) y KLK lo revisa
/// antes de que salga arriba de los chats de todos.
class MyAdScreen extends ConsumerStatefulWidget {
  const MyAdScreen({super.key});

  @override
  ConsumerState<MyAdScreen> createState() => _MyAdScreenState();
}

class _MyAdScreenState extends ConsumerState<MyAdScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _cta = TextEditingController();
  final _url = TextEditingController();
  String _color = 'red';
  Uint8List? _logo; // logo nuevo elegido
  String? _logoUrl; // logo que ya tenía
  bool _keepLogo = true;

  Map<String, dynamic>? _ad; // mi anuncio en el servidor
  bool _loading = true;
  bool _busy = false;
  /// La tienda ya tiene la suscripción (si Apple aún no la aprobó, no se puede comprar).
  bool _storeReady = false;
  String _price = '6,99 €';

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _body, _cta]) {
      c.addListener(() => setState(() {}));
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in [_title, _body, _cta, _url]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final app = ref.read(appProvider);
    try {
      final products = await KlkNative.storeProducts([AppController.adsProduct]);
      if (products.isNotEmpty && (products.first['price'] as String?)?.isNotEmpty == true) {
        _price = products.first['price'] as String;
        _storeReady = true;
      }
    } catch (_) {}
    try {
      final ad = await app.myAd();
      if (ad != null) {
        _ad = ad;
        _title.text = ad['title'] as String? ?? '';
        _body.text = ad['body'] as String? ?? '';
        _cta.text = ad['cta'] as String? ?? '';
        _url.text = ad['url'] as String? ?? '';
        _color = ad['color'] as String? ?? 'red';
        if (ad['hasImage'] == true) {
          _logoUrl = app.adImageUrl(KlkAd.fromJson(ad));
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  bool get _paid {
    final p = DateTime.tryParse(_ad?['paidUntil'] as String? ?? '');
    return p != null && p.add(const Duration(days: 1)).isAfter(DateTime.now());
  }

  Future<void> _pickLogo() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 320, maxHeight: 320, imageQuality: 80);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    if (bytes.length > 150 * 1024) {
      _snack(tr('Ese logo pesa mucho. Prueba con otra imagen.'));
      return;
    }
    setState(() {
      _logo = bytes;
      _keepLogo = false;
    });
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _publish() async {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      _snack(tr('Pon el nombre de tu negocio y el mensaje'));
      return;
    }
    final app = ref.read(appProvider);
    setState(() => _busy = true);
    try {
      var proofs = const <String>[];
      if (!_paid) {
        proofs = await app.buyAdSubscription(); // la tienda cobra
      }
      final ad = await app.saveMyAd({
        'title': _title.text.trim(),
        'body': _body.text.trim(),
        'cta': _cta.text.trim(),
        'url': _url.text.trim(),
        'color': _color,
        if (_logo != null) 'image': base64Encode(_logo!),
        'keepImage': _logo == null && _keepLogo,
      }, proofs: proofs);
      await app.markHasAd(true);
      if (!mounted) return;
      setState(() {
        _ad = ad;
        _logo = null;
      });
      _snack(tr('¡Listo! Lo revisamos y en poco tiempo sale arriba de los chats'));
    } on KlkNativeException catch (e) {
      if (e.code != 'cancelled' && mounted) _snack(e.message);
    } on ApiException catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack(tr('No se pudo publicar. Inténtalo otra vez.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('¿Quitar tu anuncio?')),
        content: Text(tr('Deja de salir. Para dejar de pagar, cancela también la suscripción en la tienda.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('No'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Quitar'))),
        ],
      ),
    );
    if (ok != true) return;
    final app = ref.read(appProvider);
    try {
      await app.deleteMyAd();
      await app.markHasAd(false);
      if (!mounted) return;
      setState(() => _ad = null);
      _snack(tr('Anuncio quitado'));
    } catch (_) {
      _snack(tr('No se pudo quitar. Inténtalo otra vez.'));
    }
  }

  Widget _status(ColorScheme cs) {
    final ad = _ad;
    if (ad == null) return const SizedBox.shrink();
    final status = ad['status'] as String? ?? 'pending';
    final (icon, color, text) = switch (status) {
      'active' when _paid => (Icons.check_circle_rounded, const Color(0xFF1F7A4D), tr('Tu anuncio está saliendo arriba de los chats')),
      'active' => (Icons.payments_rounded, const Color(0xFFC2410C), tr('La suscripción terminó: renuévala para que vuelva a salir')),
      'rejected' => (Icons.cancel_rounded, const Color(0xFFB42318), tr('No se aprobó. Cámbialo y vuelve a enviarlo.')),
      _ => (Icons.hourglass_top_rounded, const Color(0xFF1E6FE8), tr('Lo estamos revisando. Sale cuando lo aprobemos.')),
    };
    final note = ad['note'] as String? ?? '';
    final clicks = (ad['clicks'] as num?)?.toInt() ?? 0;
    final paid = ad['paidUntil'] as String?;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(fontWeight: FontWeight.w700, color: color))),
        ]),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${tr('Motivo')}: $note'),
        ],
        const SizedBox(height: 6),
        Text(
          '$clicks ${tr('toques')}${paid != null ? ' · ${tr('pagado hasta el')} $paid' : ''}',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    ImageProvider? logo;
    if (_logo != null) {
      logo = MemoryImage(_logo!);
    } else if (_keepLogo && _logoUrl != null) {
      logo = NetworkImage(_logoUrl!);
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('Anúnciate en KLK'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Text(tr('Así lo verá todo el mundo, arriba de sus chats:'),
                  style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 10),
              SizedBox(
                height: 104,
                child: adPreview(title: _title.text, body: _body.text, cta: _cta.text, color: _color, logo: logo),
              ),
              const SizedBox(height: 16),
              _status(cs),
              if (_ad != null) const SizedBox(height: 16),
              Row(children: [
                OutlinedButton.icon(
                  onPressed: _pickLogo,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(logo == null ? tr('Poner mi logo') : tr('Cambiar logo')),
                ),
                if (logo != null)
                  TextButton(
                    onPressed: () => setState(() {
                      _logo = null;
                      _keepLogo = false;
                    }),
                    child: Text(tr('Quitar')),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                maxLength: 40,
                decoration: InputDecoration(labelText: tr('Nombre del negocio'), hintText: 'Colmado La Esquina'),
              ),
              TextField(
                controller: _body,
                maxLength: 120,
                maxLines: 2,
                decoration: InputDecoration(labelText: tr('Mensaje'), hintText: tr('Pide por KLK y te lo llevamos')),
              ),
              TextField(
                controller: _cta,
                maxLength: 16,
                decoration: InputDecoration(labelText: tr('Texto del botón'), hintText: tr('Pedir, Llamar, Ver…')),
              ),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: tr('Al tocarlo, abrir…'),
                  hintText: tr('Tu web, tel:+1809… o @tuusuario'),
                  helperText: tr('Si lo dejas vacío, al tocarlo te escriben a tu chat de KLK.'),
                ),
              ),
              const SizedBox(height: 16),
              Text(tr('Color'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final e in adColorChoices.entries)
                  GestureDetector(
                    onTap: () => setState(() => _color = e.key),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: e.value,
                        shape: BoxShape.circle,
                        border: Border.all(color: _color == e.key ? cs.onSurface : Colors.transparent, width: 3),
                      ),
                      child: _color == e.key ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                    ),
                  ),
              ]),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                onPressed: _busy || (!_paid && !_storeReady) ? null : _publish,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text(
                        _paid
                            ? (_ad == null ? tr('Enviar mi anuncio') : tr('Guardar cambios'))
                            : _storeReady
                                ? '${tr('Publicar por')} $_price ${tr('al mes')}'
                                : tr('Muy pronto: anúnciate desde la app'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 10),
              Text(
                tr('Es una suscripción aparte de KLK Plus. Se renueva sola cada mes y la cobra '
                    '${KlkNative.isGooglePlay ? 'Google Play' : 'Apple'}. Puedes cancelarla cuando quieras. '
                    'Revisamos cada anuncio antes de que salga: nada engañoso, ni ofensivo, ni para adultos.'),
                style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
              ),
              if (_ad != null) ...[
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: KlkNative.storeManage,
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: Text(tr('Gestionar suscripción')),
                ),
                TextButton.icon(
                  onPressed: _remove,
                  icon: const Icon(Icons.delete_outline, color: Color(0xFFB42318)),
                  label: Text(tr('Quitar mi anuncio'), style: const TextStyle(color: Color(0xFFB42318))),
                ),
              ],
            ]),
    );
  }
}
