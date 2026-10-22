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
  _Perk(Icons.handshake_rounded, [Color(0xFF2FAE6B), Color(0xFF1F7A4D)], 'San Plus',
      'Varios sanes a la vez, recordatorios solos e historial en PDF.'),
  _Perk(Icons.graphic_eq_rounded, [Color(0xFFFF5C8A), Color(0xFFD81B60)], 'Sonidos y «Con mi voz»',
      'Todos los stickers con audio y graba los tuyos.'),
  _Perk(Icons.palette_rounded, [Color(0xFF9C8BFF), Color(0xFF7B61FF)], 'Temas exclusivos',
      'Punta Cana, Zona Colonial, Carnaval y Oro.'),
  _Perk(Icons.closed_caption_rounded, [Color(0xFF2EC4B6), Color(0xFF0E7A8A)], 'Subtítulos traducidos',
      'En llamadas: lee lo que te dicen, en tu idioma.'),
  _Perk(Icons.app_shortcut_rounded, [_oroClaro, _oroOscuro], 'Iconos de la app', 'Noche, Oro y Bandera.',
      iosOnly: true),
  _Perk(Icons.emoji_emotions_rounded, [Color(0xFFFF7A59), Color(0xFFE63946)], 'Stickers exclusivos',
      '12 stickers criollos: ¡El jefe!, ¡Tá en fuego!…'),
  _Perk(Icons.music_note_rounded, [Color(0xFFF4A261), Color(0xFFE76F51)], 'Tonos dominicanos',
      'Tambora, merengue y acordeón para tus mensajes.'),
  _Perk(Icons.cloud_done_rounded, [Color(0xFF8E7BFF), Color(0xFF4A3AFF)], 'Fotos y vídeos, 1 año',
      'Se guardan cifrados un año en vez de 30 días.'),
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
            const Text('KLK Plus: más sanes, sonidos y «Con mi voz», temas e iconos exclusivos y subtítulos traducidos.',
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

  /// Ahorro del plan anual frente a 12 meses del mensual (con los precios reales de la tienda).
  int? _yearSaving() {
    double? price(String unit) {
      final p = _products.where((x) => x['unit'] == unit).firstOrNull;
      final a = p?['amount'];
      return a is num ? a.toDouble() : null;
    }

    final m = price('month'), y = price('year');
    if (m == null || y == null || m <= 0) return null;
    final pct = ((1 - y / (m * 12)) * 100).round();
    return pct >= 5 ? pct : null;
  }

  String? _perMonth(Map<String, dynamic> p) {
    final a = p['amount'];
    if (p['unit'] != 'year' || a is! num) return null;
    final price = p['price'] as String? ?? '';
    // Mismo formato que el precio de la tienda: cambia solo el número.
    final m = RegExp(r'[\d.,]+').firstMatch(price);
    if (m == null) return null;
    final comma = m.group(0)!.contains(',');
    final v = (a / 12);
    var n = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    if (comma) n = n.replaceAll('.', ',');
    return '${price.replaceRange(m.start, m.end, n)} al mes';
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appProvider);
    const muted = Color(0xFFA9B1BE);
    final perks = _shownPerks;
    return ValueListenableBuilder<bool>(
      valueListenable: plusActive,
      builder: (context, plus, _) {
        final until = plusUntilNotifier.value;
        final chosen = _products.where((p) => p['id'] == _chosen).firstOrNull;
        final trial = chosen == null ? null : _trial(chosen);
        final saving = _yearSaving();
        return Theme(
          data: Theme.of(context).copyWith(
            brightness: Brightness.dark,
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  brightness: Brightness.dark,
                  onSurface: const Color(0xFFF2F5F9),
                  surfaceContainerHighest: const Color(0xFF1C1A14),
                ),
            textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: const Color(0xFFC9B382))),
          ),
          child: Scaffold(
            backgroundColor: const Color(0xFF0A0E14),
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              foregroundColor: Colors.white,
              elevation: 0,
              scrolledUnderElevation: 0,
              actions: [
                if (KlkNative.supportsStore && !plus)
                  TextButton(onPressed: _busy ? null : _restore, child: const Text('Restaurar compras')),
              ],
            ),
            body: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -1.1),
                  radius: 1.3,
                  colors: [Color(0xFF3B2A06), Color(0xFF120E05), Color(0xFF0A0E14)],
                  stops: [0, 0.45, 0.8],
                ),
              ),
              child: ListView(
                padding: EdgeInsets.fromLTRB(18, MediaQuery.paddingOf(context).top + kToolbarHeight - 8, 18, 36),
                children: [
                  // ---------- Cabecera ----------
                  Center(
                    child: Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(25),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFFE59A), Color(0xFFE8A71C), Color(0xFFB87A0B)],
                        ),
                        boxShadow: [BoxShadow(color: const Color(0xFFE8A71C).withValues(alpha: 0.45), blurRadius: 34, offset: const Offset(0, 10))],
                      ),
                      child: const Icon(Icons.workspace_premium_rounded, size: 46, color: Color(0xFF3A2A00)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'KLK '),
                      TextSpan(text: 'Plus', style: TextStyle(color: _oroClaro)),
                    ]),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.6),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    plus
                        ? 'Activo${until == null ? '' : ' hasta el ${DateFormat('d/M/y').format(until)}'}. ¡Gracias por apoyar KLK!'
                        : 'Más sabor dominicano. Lo básico sigue gratis.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFFC9B382), fontSize: 14.5),
                  ),
                  const SizedBox(height: 18),

                  // ---------- Ventajas ----------
                  for (final p in perks)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: Colors.white.withValues(alpha: 0.05),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: _oroClaro.withValues(alpha: 0.14)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: p.icon == Icons.palette_rounded
                              ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemePickerScreen()))
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(children: [
                              _IconTile(p.icon, p.colors, size: 38),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(p.title,
                                      style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 1),
                                  Text(p.sub, style: const TextStyle(color: muted, fontSize: 12.5)),
                                ]),
                              ),
                              if (plus) const Icon(Icons.check_circle_rounded, color: _oroClaro, size: 20),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),

                  // ---------- Planes y botón ----------
                  if (!plus) ...[
                    if (_loadingStore)
                      const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(color: _oro)))
                    else if (_products.isNotEmpty)
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        // Mensual a la izquierda, anual a la derecha (como en el diseño)
                        for (final (i, p) in ([..._products]
                              ..sort((a, b) => (a['unit'] == 'year' ? 1 : 0) - (b['unit'] == 'year' ? 1 : 0)))
                            .indexed) ...[
                          if (i > 0) const SizedBox(width: 10),
                          Expanded(
                            child: _PlanCard(
                              title: p['unit'] == 'year' ? 'Anual' : 'Mensual',
                              price: p['price'] as String? ?? '',
                              per: _perMonth(p) ?? 'al ${_per(p)}',
                              badge: p['unit'] == 'year' && saving != null ? 'AHORRA $saving%' : null,
                              trial: _trial(p),
                              selected: p['id'] == _chosen,
                              onTap: () => setState(() => _chosen = p['id'] as String),
                            ),
                          ),
                        ],
                      ]),
                    const SizedBox(height: 12),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        gradient: LinearGradient(
                          colors: _busy || chosen == null
                              ? [const Color(0xFFFFE59A).withValues(alpha: 0.35), const Color(0xFFE8A71C).withValues(alpha: 0.35)]
                              : const [Color(0xFFFFE59A), Color(0xFFE8A71C)],
                        ),
                        boxShadow: chosen == null
                            ? null
                            : [BoxShadow(color: const Color(0xFFE8A71C).withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8))],
                      ),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          disabledBackgroundColor: Colors.transparent,
                          foregroundColor: const Color(0xFF2A1E00),
                          disabledForegroundColor: const Color(0xFF2A1E00).withValues(alpha: 0.6),
                          shadowColor: Colors.transparent,
                          minimumSize: const Size.fromHeight(54),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
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
                                style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w900)),
                      ),
                    ),
                    if (chosen != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${trial != null ? 'Después, ' : ''}${chosen['price']} / ${_per(chosen)}. Se renueva solo y lo cobra Apple. '
                        'Cancela cuando quieras en Ajustes del iPhone → tu nombre → Suscripciones.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: muted, height: 1.35),
                      ),
                    ] else if (!_loadingStore)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('Muy pronto podrás suscribirte desde aquí.',
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: muted)),
                      ),
                  ],

                  // ---------- Siempre gratis ----------
                  Container(
                    margin: const EdgeInsets.only(top: 14),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF25C26E).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF25C26E).withValues(alpha: 0.25)),
                    ),
                    child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.verified_user_rounded, color: Color(0xFF5FD39A), size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(text: 'Siempre gratis: ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                            TextSpan(
                                text: 'mensajes, llamadas y videollamadas, cifrado, el san (uno a la vez), '
                                    'botón de pánico y privacidad.'),
                          ]),
                          style: TextStyle(fontSize: 12.5, color: Color(0xFFBFE9D2), height: 1.4),
                        ),
                      ),
                    ]),
                  ),

                  if (KlkNative.supportsStore)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(alignment: WrapAlignment.center, children: [
                        if (plus) TextButton(onPressed: KlkNative.storeManage, child: const Text('Gestionar suscripción')),
                        if (plus) TextButton(onPressed: _busy ? null : _restore, child: const Text('Restaurar compras')),
                        TextButton(
                            onPressed: () => _open('https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'),
                            child: const Text('Términos')),
                        TextButton(
                            onPressed: () => _open('https://klk-server.onrender.com/privacidad'),
                            child: const Text('Privacidad')),
                      ]),
                    ),
                  const SizedBox(height: 12),

                  // ---------- Icono de la app ----------
                  if (KlkNative.supportsAppIcons) ...[
                    const _Title('Icono de la app'),
                    Row(children: [
                      for (final (name, label, asset) in const [
                        (null, 'Normal', 'assets/brand/klk_app_icon.png'),
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
                                Text(label, style: const TextStyle(fontSize: 12.5, color: Colors.white)),
                              ]),
                            ),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 16),
                  ],

                  // Solo en versiones de prueba (TestFlight / APK de pruebas): las tiendas
                  // no permiten activar funciones de pago con códigos.
                  if (_test) ...[
                    const SizedBox(height: 8),
                    const _Title('Código de prueba'),
                    const Text('Solo aparece en las versiones de prueba.', style: TextStyle(fontSize: 13, color: muted)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _code,
                          style: const TextStyle(color: Colors.white),
                          textCapitalization: TextCapitalization.characters,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            hintText: 'Escribe el código',
                            hintStyle: TextStyle(color: muted),
                            border: OutlineInputBorder(),
                          ),
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
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String title, price, per;
  final String? badge, trial;
  final bool selected;
  final VoidCallback onTap;
  const _PlanCard({
    required this.title,
    required this.price,
    required this.per,
    this.badge,
    this.trial,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Stack(clipBehavior: Clip.none, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: selected
                  ? LinearGradient(colors: [_oroClaro.withValues(alpha: 0.20), _oro.withValues(alpha: 0.08)])
                  : null,
              color: selected ? null : Colors.white.withValues(alpha: 0.05),
              border: Border.all(color: selected ? _oroClaro : Colors.white.withValues(alpha: 0.12), width: selected ? 2 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700, color: selected ? const Color(0xFFFFE3A3) : const Color(0xFFA9B1BE))),
              const SizedBox(height: 2),
              Text(price, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, color: Colors.white)),
              Text(per, style: TextStyle(fontSize: 12, color: selected ? const Color(0xFFC9B382) : const Color(0xFFA9B1BE))),
              if (trial != null)
                Text(trial!, style: const TextStyle(fontSize: 11.5, color: _oroClaro, fontWeight: FontWeight.w700)),
            ]),
          ),
          if (badge != null)
            Positioned(
              top: -10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: _oroClaro, borderRadius: BorderRadius.circular(999)),
                child: Text(badge!,
                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: Color(0xFF3A2A00))),
              ),
            ),
        ]),
      );
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
      child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)));
}
