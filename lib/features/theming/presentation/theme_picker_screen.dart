import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/presentation/message_bubble.dart';
import '../../messaging/models.dart';
import '../domain/klk_theme.dart';
import 'theme_provider.dart';

class ThemePickerScreen extends ConsumerWidget {
  const ThemePickerScreen({super.key});

  static const _fonts = ['Plus Jakarta Sans', 'Nunito', 'Poppins', 'Lora', 'JetBrains Mono'];

  static Message _sample(String id, MessageKind kind, String text) => Message(
        id: id,
        chatId: 'preview',
        kind: kind,
        body: text,
        status: MessageStatus.read,
        createdAt: DateTime(2026, 1, 1, 10, 0),
      );
  static const _bubbleColors = [
    Color(0xFF002D62), Color(0xFFCE1126), Color(0xFF0E4D64),
    Color(0xFF2E7D32), Color(0xFF6A1B9A), Color(0xFFFF8F00),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeProvider);
    final notifier = ref.read(themeProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Temas')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Vista previa en vivo
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: current.background,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Column(children: [
              MessageBubble(message: _sample('a', MessageKind.incoming, '¿Qué lo que? ¿Cómo quedó el tema?')),
              MessageBubble(message: _sample('b', MessageKind.outgoing, '¡Quedó brutal! 🔥')),
            ]),
          ),
          const SizedBox(height: 24),
          Text('Predeterminados', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: KlkTheme.presets
                .map((t) => ChoiceChip(
                      label: Text(t.name),
                      selected: current.id == t.id,
                      onSelected: (_) => notifier.apply(t),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),
          Text('Color de mis burbujas', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            children: _bubbleColors
                .map((c) => GestureDetector(
                      onTap: () => notifier.apply(current.copyWith(id: 'custom', name: 'Personalizado', myBubble: c)),
                      child: CircleAvatar(
                        backgroundColor: c,
                        radius: 18,
                        child: current.myBubble == c
                            ? const Icon(Icons.check, color: Colors.white, size: 18)
                            : null,
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),
          Text('Redondeo de burbujas', style: Theme.of(context).textTheme.titleMedium),
          Slider(
            min: 4,
            max: 28,
            value: current.bubbleRadius,
            onChanged: (v) => notifier.apply(current.copyWith(id: 'custom', name: 'Personalizado', bubbleRadius: v)),
          ),
          Text('Fuente', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: _fonts
                .map((f) => ChoiceChip(
                      label: Text(f),
                      selected: current.fontFamily == f,
                      onSelected: (_) => notifier.apply(current.copyWith(id: 'custom', name: 'Personalizado', fontFamily: f)),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}
