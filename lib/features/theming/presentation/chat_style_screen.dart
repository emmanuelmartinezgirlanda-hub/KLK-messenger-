import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../wallpapers.dart';
import 'theme_picker_screen.dart';
import 'theme_provider.dart';

/// «Estilo del chat» (como en WhatsApp): combinaciones listas de fondo + color
/// de tus burbujas, por categorías. Un toque y queda puesto.
class _Preset {
  final String wallpaper;
  final Color bubble;
  const _Preset(this.wallpaper, this.bubble);
}

const _sections = <(String, List<_Preset>)>[
  ('Destacados', [
    _Preset('klk', Color(0xFFCE1126)),
    _Preset('g:0', Color(0xFF0072FF)),
    _Preset('g:6', Color(0xFF0E4D64)),
    _Preset('g:2', Color(0xFF002D62)),
    _Preset('g:10', Color(0xFF6A1B9A)),
  ]),
  ('República Dominicana', [
    _Preset('malecon', Color(0xFFC2410C)),
    _Preset('samana', Color(0xFF0E7490)),
    _Preset('pico', Color(0xFF2E7D32)),
    _Preset('bandera', Color(0xFF002D62)),
    _Preset('colonial', Color(0xFF8B4513)),
    _Preset('palmeras', Color(0xFF1F7A4D)),
    _Preset('constanza', Color(0xFF4D7C0F)),
    _Preset('carnaval', Color(0xFFCE1126)),
    _Preset('noche', Color(0xFF3730A3)),
    _Preset('lluvia', Color(0xFF475569)),
  ]),
  ('Degradados', [
    _Preset('g:1', Color(0xFFE8590C)),
    _Preset('g:3', Color(0xFFB45309)),
    _Preset('g:4', Color(0xFF7E22CE)),
    _Preset('g:5', Color(0xFF0F766E)),
    _Preset('g:7', Color(0xFFBE185D)),
    _Preset('g:8', Color(0xFF6B4423)),
    _Preset('g:9', Color(0xFF3F6212)),
    _Preset('g:11', Color(0xFF4B5563)),
  ]),
  ('Minimalista', [
    _Preset('c:6', Color(0xFF4B5563)),
    _Preset('c:1', Color(0xFF1E40AF)),
    _Preset('c:3', Color(0xFF9F1239)),
    _Preset('c:0', Color(0xFF15803D)),
    _Preset('c:8', Color(0xFF92400E)),
    _Preset('c:10', Color(0xFF1D4ED8)),
    _Preset('c:11', Color(0xFFBE123C)),
    _Preset('c:13', Color(0xFF6D28D9)),
  ]),
  ('Dibujo', [
    _Preset('klk', Color(0xFF2E7D32)),
    _Preset('klk', Color(0xFF6A1B9A)),
    _Preset('klk', Color(0xFF1E6FE8)),
    _Preset('puntos', Color(0xFFFF8F00)),
    _Preset('olas', Color(0xFF0E4D64)),
  ]),
];

class ChatStyleScreen extends ConsumerWidget {
  const ChatStyleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wall = ref.watch(wallpaperProvider);
    final theme = ref.watch(themeProvider);
    final cs = Theme.of(context).colorScheme;

    Future<void> apply(_Preset p) async {
      HapticFeedback.selectionClick();
      await ref.read(wallpaperProvider.notifier).set(p.wallpaper);
      await ref.read(themeProvider.notifier).apply(theme.copyWith(id: 'custom', name: 'Personalizado', myBubble: p.bubble, myBubbleText: Colors.white));
    }

    Widget topButton(IconData icon, String label, VoidCallback onTap, {Widget? art}) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Container(
                  width: 76,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: art ?? Icon(icon, size: 26),
                ),
                const SizedBox(height: 8),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Estilo del chat'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(0, 8, 0, 32), children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            topButton(
              Icons.chat_bubble,
              tr('Burbuja de chat'),
              () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemePickerScreen())),
              art: Icon(Icons.chat_bubble_rounded, size: 30, color: theme.myBubble),
            ),
            topButton(Icons.wallpaper_rounded, tr('Fondo'), () => showWallpaperPicker(context)),
            topButton(Icons.photo_library_rounded, tr('Mi foto'), () => showWallpaperPicker(context)),
          ]),
        ),
        for (final (title, presets) in _sections) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
            child: Text(tr(title), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: cs.onSurface.withValues(alpha: 0.75))),
          ),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: presets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) {
                final p = presets[i];
                final on = wall == p.wallpaper && theme.myBubble.toARGB32() == p.bubble.toARGB32();
                return GestureDetector(
                  onTap: () => apply(p),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 116,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: on ? cs.onSurface : Colors.transparent, width: 3),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(19),
                      child: Stack(fit: StackFit.expand, children: [
                        ChatWallpaper(id: p.wallpaper, dim: false),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 26, 8, 8),
                          child: Column(children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: _MiniBubble(color: cs.surfaceContainerHighest, mine: false),
                            ),
                            const SizedBox(height: 10),
                            Align(alignment: Alignment.centerRight, child: _MiniBubble(color: p.bubble, mine: true)),
                            const Spacer(),
                            if (on)
                              Container(
                                width: 30,
                                height: 30,
                                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                child: const Icon(Icons.check_rounded, color: Colors.black),
                              ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ]),
    );
  }
}

class _MiniBubble extends StatelessWidget {
  final Color color;
  final bool mine;
  const _MiniBubble({required this.color, required this.mine});

  @override
  Widget build(BuildContext context) => Container(
        width: 62,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(mine ? 14 : 3),
            bottomRight: Radius.circular(mine ? 3 : 14),
          ),
        ),
      );
}
