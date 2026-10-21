import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:klk_native/klk_native.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';
import '../messaging/app_controller.dart';
import '../theming/presentation/theme_picker_screen.dart';
import 'plus_state.dart';

const _oro = Color(0xFFE0B54A);
const _oroClaro = Color(0xFFFFD86B);
const _oroOscuro = Color(0xFF8A6A12);
const _fondo = [Color(0xFF14100A), Color(0xFF2C220E)];

/// Una ventaja de Plus: icono moderno en un cuadrito con degradado.
class _Perk {
  final IconData icon;
  final List<Color> colors;
  final String title, sub;
  final bool iosOnly;
  const _Perk(this.icon, this.colors, this.title, this.sub, {this.iosOnly = false});
}

const _perks = [
  _Perk(Icons.palette_rounded, [Color(0xFF00B4D8), Color(0xFF0077B6)], 'Temas exclusivos',
      'Punta Cana, Zona Colonial, Carnaval y Oro.'),
  _Perk(Icons.emoji_emotions_rounded, [Color(0xFFFF7A59), Color(0xFFE63946)], 'Stickers exclusivos',
      '12 stickers criollos solo para Plus: ¡El jefe!, ¡Tá en fuego!…'),
  _Perk(Icons.cloud_done_rounded, [Color(0xFF8E7BFF), Color(0xFF4A3AFF)], 'Tus fotos y vídeos, 1 año',
      'Se guardan cifrados un año en vez de 30 días.'),
  _Perk(Icons.closed_caption_rounded, [Color(0xFF2EC4B6), Color(0xFF1F7A4D)], 'Subtítulos en llamadas',
      'Lee en tu idioma lo que te dicen (beta, entre iPhones).'),
  _Perk(Icons.music_note_rounded, [Color(0xFFF4A261), Color(0xFFE76F51)], 'Tonos dominicanos',
      'Tambora, merengue y acordeón para tus mensajes.'),
  _Perk(Icons.app_shortcut_rounded, [_oroClaro, _oroOscuro], 'Iconos de la app', 'Noche, Oro y Bandera.',
      iosOnly: true),
  _Perk(Icons.verified_rounded, [Color(0xFFFFD86B), Color(0xFFE0A030)], 'Insignia Plus', 'Sale al lado de tu nombre.'),
];


/// Cuadrito con el icono (como los de Ajustes del iPhone).
class _IconTile extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final double size;
  const _IconTile(this.icon, this.colors, {this.size = 40});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.28),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
          boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.35), blurRadius: size * 0.25, offset: Offset(0, size * 0.08))],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.56),
      );
}

/// Aviso cuando alguien sin Plus toca algo de Plus.
Future<void> showPlusRequired(BuildContext context, String what) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _IconTile(Icons.workspace_premium_rounded, [_oroClaro, _oroOscuro], size: 64),
            const SizedBox(height: 14),
            Text('$what es de KLK Plus',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Con KLK Plus tienes iconos, temas y stickers exclusivos, y tus fotos y vídeos se guardan un año.',
                textAlign: TextAlign.center),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: _oro, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(50)),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlusScreen()));
                },
                child: const Text('Ver KLK Plus', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ),
      ),
    );

/// Marca dorada de Plus (en Ajustes, stickers y tonos bloqueados…).
class PlusMark extends StatelessWidget {
  final double size;
  const PlusMark({super.key, this.size = 18});
  @override
  Widget build(BuildContext context) => size >= 30
      ? _IconTile(Icons.workspace_premium_rounded, const [_oroClaro, _oroOscuro], size: size)
      : Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, gradient: LinearGradient(colors: [_oroClaro, _oro])),
          child: Icon(Icons.workspace_premium_rounded, size: size * 0.7, color: Colors.black),
        );
}

/// Insignia Plus (al lado del nombre).
class PlusBadge extends StatelessWidget {
  final double size;
  const PlusBadge({super.key, this.size = 12});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(size * 0.45, size * 0.2, size * 0.7, size * 0.2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [_oroClaro, _oro]),
          borderRadius: BorderRadius.circular(size * 2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.workspace_premium_rounded, size: size * 1.25, color: Colors.black),
          SizedBox(width: size * 0.2),
          Text('Plus', style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: Colors.black)),
        ]),
      );
}

class PlusScreen extends ConsumerStatefulWidget {
  const PlusScreen({super.key});

  @override
  ConsumerState<PlusScreen> createState() => _PlusScreenState();
}

class _PlusScreenState extends ConsumerState<PlusScreen> {
  final _code = TextEditingController();
  final _pages = PageController(viewportFraction: 0.86);
  Timer? _auto;
  int _page = 0;
  bool _test = false;
  bool _busy = false;
  bool _loadingStore = true;
  String? _icon;
  List<Map<String, dynamic>> _products = const [];
  String? _chosen;

  List<_Perk> get _shownPerks => [for (final p in _perks) if (!p.iosOnly || KlkNative.supportsAppIcons) p];

  @override
  void initState() {
    super.initState();
    KlkNative.isTestBuild().then((v) => mounted ? setState(() => _test = v) : null);
    KlkNative.appIcon().then((v) => mounted ? setState(() => _icon = v) : null);
    ref.read(appProvider).refreshPlus();
    _loadStore();
    _auto = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_pages.hasClients) return;
      final next = (_page + 1) % _shownPerks.length;
      _pages.animateToPage(next, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    });
  }

  Future<void> _loadStore() async {
    final list = KlkNative.supportsStore ? await KlkNative.storeProducts(AppController.plusProducts) : const <Map<String, dynamic>>[];
    // Primero el anual (sale más barato al mes), luego el mensual.
    final sorted = [...list]..sort((a, b) => (b['unit'] == 'year' ? 1 : 0) - (a['unit'] == 'year' ? 1 : 0));
    if (!mounted) return;
    setState(() {
      _products = sorted;
      _chosen = sorted.isEmpty ? null : sorted.first['id'] as String;
      _loadingStore = false;
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    _pages.dispose();
    _code.dispose();
    super.dispose();
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } on KlkNativeException catch (e) {
      if (e.code != 'cancelled') _snack(e.message);
    } on ApiException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('No se pudo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buy() => _run(() async {
        final id = _chosen;
        if (id == null) return;
        await ref.read(appProvider).buyPlus(id);
        if (plusActive.value) _snack('¡Bienvenido a KLK Plus!');
      });

  Future<void> _restore() => _run(() async {
        final ok = await ref.read(appProvider).restorePlus();
        _snack(ok ? 'Listo: tu KLK Plus está activo' : 'No encontramos una suscripción con este Apple ID');
      });

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    await _run(() async {
      await ref.read(appProvider).redeemPlus(code);
      _code.clear();
      if (mounted) FocusScope.of(context).unfocus();
      _snack('¡KLK Plus activado!');
    });
  }

  Future<void> _setIcon(String? name) async {
    if (!plusActive.value) return showPlusRequired(context, 'Cambiar el icono');
    try {
      await KlkNative.setAppIcon(name);
      setState(() => _icon = name);
    } catch (e) {
      _snack(e.toString());
    }
  }

  static String _per(Map<String, dynamic> p) => switch (p['unit']) {
        'year' => 'año',
        'week' => 'semana',
        'day' => 'día',
        _ => 'mes',
      };

  static String? _trial(Map<String, dynamic> p) {
    final n = p['trialCount'] as int?;
    if (n == null) return null;
    final u = switch (p['trialUnit']) {
      'day' => n == 1 ? 'día' : 'días',
      'week' => n == 1 ? 'semana' : 'semanas',
      'month' => n == 1 ? 'mes' : 'meses',
      _ => 'días',
    };
    return '$n $u gratis';
  }

  void _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.6);
    final perks = _shownPerks;
    return ValueListenableBuilder<bool>(
      valueListenable: plusActive,
      builder: (context, plus, _) {
        final until = plusUntilNotifier.value;
        final chosen = _products.where((p) => p['id'] == _chosen).firstOrNull;
        final trial = chosen == null ? null : _trial(chosen);
        return Scaffold(
          appBar: AppBar(title: const Text('KLK Plus')),
          body: ListView(padding: const EdgeInsets.only(bottom: 36), children: [
            // ---------- Cabecera ----------
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _fondo),
              ),
              child: Row(children: [
                const _IconTile(Icons.workspace_premium_rounded, [_oroClaro, _oroOscuro], size: 58),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ShaderMask(
                      shaderCallback: (r) => const LinearGradient(colors: [_oroClaro, _oro]).createShader(r),
                      child: const Text('KLK Plus',
                          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      plus
                          ? 'Activo${until == null ? '' : ' hasta el ${DateFormat('d/M/y').format(until)}'}. ¡Gracias por apoyar KLK!'
                          : 'Lo de siempre sigue gratis y cifrado. Plus es para quien quiera más.',
                      style: const TextStyle(color: Colors.white70, fontSize: 14.5, height: 1.3),
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 18),

            // ---------- Carrusel de ventajas ----------
            SizedBox(
              height: 200,
              child: PageView.builder(
                controller: _pages,
                itemCount: perks.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => _PerkCard(perks[i]),
              ),
            ),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < perks.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? _oro : cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ]),
            const SizedBox(height: 18),

            // ---------- Planes y botón ----------
            if (!plus)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_loadingStore)
                    const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
                  else ...[
                    for (final p in _products)
                      _PlanCard(
                        title: p['unit'] == 'year' ? 'Anual' : 'Mensual',
                        price: '${p['price']} / ${_per(p)}',
                        note: _trial(p) ?? (p['unit'] == 'year' ? 'El que más ahorra' : null),
                        selected: p['id'] == _chosen,
                        onTap: () => setState(() => _chosen = p['id'] as String),
                      ),
                    const SizedBox(height: 6),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _oro,
                        foregroundColor: Colors.black,
                        disabledBackgroundColor: _oro.withValues(alpha: 0.35),
                        minimumSize: const Size.fromHeight(54),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _busy || chosen == null ? null : _buy,
                      child: _busy
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                          : Text(
                              chosen == null
                                  ? 'Suscribirse: muy pronto'
                                  : trial != null
                                      ? 'Probar $trial'
                                      : 'Probar KLK Plus',
                              style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
                    ),
                    if (chosen != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${trial != null ? 'Después, ' : ''}${chosen['price']} / ${_per(chosen)}. Se renueva solo y lo cobra Apple. '
                        'Cancela cuando quieras en Ajustes del iPhone → tu nombre → Suscripciones.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: muted, height: 1.35),
                      ),
                    ] else if (!KlkNative.supportsStore)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('Muy pronto podrás suscribirte desde aquí.',
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: muted)),
                      ),
                  ],
                ]),
              ),
            if (KlkNative.supportsStore)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(alignment: WrapAlignment.center, children: [
                  TextButton(onPressed: _busy ? null : _restore, child: const Text('Restaurar compras')),
                  if (plus) TextButton(onPressed: KlkNative.storeManage, child: const Text('Gestionar suscripción')),
                  TextButton(
                      onPressed: () => _open('https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'),
                      child: const Text('Términos')),
                  TextButton(
                      onPressed: () => _open('https://klk-server.onrender.com/privacidad'), child: const Text('Privacidad')),
                ]),
              ),
            const SizedBox(height: 12),

            // ---------- Icono de la app ----------
            if (KlkNative.supportsAppIcons) ...[
              const _Title('Icono de la app'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  for (final (name, label, asset) in const [
                    (null, 'Normal', 'assets/brand/klk_logo.png'),
                    ('KLK-Noche', 'Noche', 'assets/icon/alt/noche.png'),
                    ('KLK-Oro', 'Oro', 'assets/icon/alt/oro.png'),
                    ('KLK-Bandera', 'Bandera', 'assets/icon/alt/bandera.png'),
                  ])
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _setIcon(name),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Column(children: [
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: _icon == name ? _oro : Colors.transparent, width: 3),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(15),
                                child: Stack(children: [
                                  Image.asset(asset, width: 62, height: 62, fit: BoxFit.cover),
                                  if (!plus && name != null)
                                    Positioned.fill(
                                      child: Container(
                                        color: Colors.black38,
                                        child: const Icon(Icons.lock_rounded, color: Colors.white, size: 22),
                                      ),
                                    ),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(label, style: const TextStyle(fontSize: 12.5)),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // ---------- Todo lo que incluye ----------
            const _Title('Todo lo que incluye'),
            _Group(children: [
              for (final p in perks)
                ListTile(
                  leading: _IconTile(p.icon, p.colors, size: 36),
                  title: Text(p.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(p.sub),
                  trailing: p.icon == Icons.palette_rounded ? const Icon(Icons.chevron_right_rounded) : null,
                  onTap: p.icon == Icons.palette_rounded
                      ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemePickerScreen()))
                      : null,
                ),
            ]),
            // Solo en versiones de prueba (TestFlight / APK de pruebas): las tiendas
            // no permiten activar funciones de pago con códigos.
            if (_test) ...[
              const SizedBox(height: 20),
              const _Title('Código de prueba'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Solo aparece en las versiones de prueba.', style: TextStyle(fontSize: 13, color: muted)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _code,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        decoration: const InputDecoration(hintText: 'Escribe el código', border: OutlineInputBorder()),
                        onSubmitted: (_) => _redeem(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _oroOscuro, minimumSize: const Size(0, 54)),
                      onPressed: _busy ? null : _redeem,
                      child: const Text('Activar'),
                    ),
                  ]),
                ]),
              ),
            ],
          ]),
        );
      },
    );
  }
}

/// Tarjeta grande del carrusel.
class _PerkCard extends StatelessWidget {
  final _Perk perk;
  const _PerkCard(this.perk);

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: perk.colors),
        ),
        child: Stack(children: [
          Positioned(
            right: -18,
            bottom: -18,
            child: Icon(perk.icon, size: 130, color: Colors.white.withValues(alpha: 0.16)),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(15)),
              child: Icon(perk.icon, color: Colors.white, size: 28),
            ),
            const Spacer(),
            Text(perk.title, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(perk.sub, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3)),
          ]),
        ]),
      );
}

class _PlanCard extends StatelessWidget {
  final String title, price;
  final String? note;
  final bool selected;
  final VoidCallback onTap;
  const _PlanCard({required this.title, required this.price, this.note, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? _oro.withValues(alpha: 0.12) : cs.surfaceContainerHighest.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: selected ? _oro : Colors.transparent, width: 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? _oro : cs.onSurface.withValues(alpha: 0.4)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  if (note != null)
                    Text(note!, style: const TextStyle(fontSize: 12.5, color: _oroOscuro, fontWeight: FontWeight.w600)),
                ]),
              ),
              Text(price, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)));
}

class _Group extends StatelessWidget {
  final List<Widget> children;
  const _Group({required this.children});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      );
}
