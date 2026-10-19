import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:klk_native/klk_native.dart';

import '../../core/network/api_client.dart';
import '../messaging/app_controller.dart';
import '../theming/presentation/theme_picker_screen.dart';
import 'plus_state.dart';

const _oro = Color(0xFFE0B54A);
const _oroOscuro = Color(0xFF8A6A12);

/// Aviso cuando alguien sin Plus toca algo de Plus.
Future<void> showPlusRequired(BuildContext context, String what) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('💎', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 8),
            Text('$what es de KLK Plus',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('Con KLK Plus tienes iconos, temas y stickers exclusivos, y tus fotos y vídeos se guardan un año.',
                textAlign: TextAlign.center),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _oro, foregroundColor: Colors.black),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlusScreen()));
                },
                child: const Text('Ver KLK Plus'),
              ),
            ),
          ]),
        ),
      ),
    );

/// Insignia 💎 Plus (al lado del nombre).
class PlusBadge extends StatelessWidget {
  final double size;
  const PlusBadge({super.key, this.size = 12});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: size * 0.6, vertical: size * 0.2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFFFFD86B), _oro]),
          borderRadius: BorderRadius.circular(size * 2),
        ),
        child: Text('💎 Plus', style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: Colors.black)),
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
  String? _icon;

  @override
  void initState() {
    super.initState();
    KlkNative.isTestBuild().then((v) => mounted ? setState(() => _test = v) : null);
    KlkNative.appIcon().then((v) => mounted ? setState(() => _icon = v) : null);
    ref.read(appProvider).refreshPlus();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(appProvider).redeemPlus(code);
      _code.clear();
      if (mounted) FocusScope.of(context).unfocus();
      _snack('¡KLK Plus activado! 💎');
    } on ApiException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('No se pudo activar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  @override
  Widget build(BuildContext context) {
    ref.watch(appProvider);
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: plusActive,
      builder: (context, plus, _) {
        final until = plusUntilNotifier.value;
        return Scaffold(
          appBar: AppBar(title: const Text('KLK Plus')),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            // Cabecera
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1B1405), Color(0xFF3A2E12)]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('💎', style: TextStyle(fontSize: 34)),
                  const SizedBox(width: 10),
                  Text('KLK Plus',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.amber.shade200)),
                ]),
                const SizedBox(height: 10),
                Text(
                  plus
                      ? 'Tienes KLK Plus${until == null ? '' : ' hasta el ${DateFormat('d/M/y').format(until)}'}. ¡Gracias por apoyar KLK!'
                      : 'Lo de siempre sigue gratis y cifrado. Plus añade extras para quien quiera más.',
                  style: const TextStyle(color: Colors.white, fontSize: 15.5, height: 1.35),
                ),
              ]),
            ),
            const SizedBox(height: 20),

            if (KlkNative.supportsAppIcons) ...[
              const _Title('Icono de la app'),
              const SizedBox(height: 8),
              Row(children: [
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
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: _icon == name ? _oro : Colors.transparent, width: 3),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(13),
                              child: Stack(children: [
                                Image.asset(asset, width: 64, height: 64, fit: BoxFit.cover),
                                if (!plus && name != null)
                                  Positioned.fill(
                                    child: Container(
                                      color: Colors.black38,
                                      child: const Icon(Icons.lock, color: Colors.white, size: 22),
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
              const SizedBox(height: 20),
            ],

            const _Title('Ya incluido'),
            _Feature('🌈', '4 temas exclusivos', 'Punta Cana, Zona Colonial, Carnaval y Oro.', onTap: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemePickerScreen()));
            }),
            const _Feature('😎', '12 stickers exclusivos', 'Pack 💎 en el selector de stickers: ¡El jefe!, ¡Tá en fuego!…'),
            const _Feature('🗂️', 'Tus fotos y vídeos, 1 año', 'Se guardan cifrados en el servidor un año en vez de 30 días.'),
            const _Feature('🥁', 'Tonos dominicanos', 'Tambora, merengue y acordeón para tus mensajes (Ajustes → Notificaciones).'),
            const _Feature('💎', 'Insignia Plus', 'Sale al lado de tu nombre en tu perfil.'),
            const _Feature('💬', 'Subtítulos traducidos en llamadas (beta)',
                'Toca «Subtítulos» en una llamada y lee en tu idioma lo que dice el otro. Su móvil pasa su voz a texto sin internet. De momento entre iPhones.'),
            if (KlkNative.supportsAppIcons) const _Feature('📱', 'Iconos de la app', 'Noche, Oro y Bandera.'),
            const SizedBox(height: 16),
            const _Title('Muy pronto en Plus'),
            for (final (e, t) in const [
              ('📝', 'Resumen de chats largos'),
              ('💻', 'Varios dispositivos a la vez'),
              ('☁️', 'Copia de seguridad automática'),
              ('👨‍👩‍👧', 'Plan Familia (hasta 5 personas)'),
              ('💸', 'Menos comisión en remesas y recargas'),
              ('⚾', 'Pelota en vivo con avisos de tu equipo'),
            ])
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Text(e, style: const TextStyle(fontSize: 22)),
                title: Text(t),
                trailing: Text('Pronto', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5))),
              ),
            const SizedBox(height: 20),

            if (!plus)
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: _oro, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(50)),
                onPressed: null,
                child: const Text('Suscribirse: muy pronto'),
              ),

            // Solo en versiones de prueba (TestFlight / APK de pruebas): las tiendas
            // no permiten activar funciones de pago con códigos.
            if (_test) ...[
              const SizedBox(height: 24),
              const _Title('Código de prueba'),
              const Text('Solo aparece en las versiones de prueba.', style: TextStyle(fontSize: 13)),
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
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Activar'),
                ),
              ]),
            ],
          ]),
        );
      },
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)));
}

class _Feature extends StatelessWidget {
  final String emoji, title, sub;
  final VoidCallback? onTap;
  const _Feature(this.emoji, this.title, this.sub, {this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Text(emoji, style: const TextStyle(fontSize: 26)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(sub),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}
