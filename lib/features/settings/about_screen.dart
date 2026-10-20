import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/l10n.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';

/// Sugerencias de «Info», con su icono.
const aboutSuggestions = <(String, IconData, Color)>[
  ('Disponible', Icons.check_circle_rounded, Color(0xFF25C26E)),
  ('Ausente', Icons.nightlight_round, Color(0xFF7B61FF)),
  ('Durmiendo', Icons.bedtime_rounded, Color(0xFF4A6CF7)),
  ('En el trabajo', Icons.work_rounded, Color(0xFF8A6A12)),
  ('Ocupado, escríbeme', Icons.hourglass_bottom_rounded, Color(0xFFE76F51)),
  ('En una reunión', Icons.groups_rounded, Color(0xFF0077B6)),
  ('De viaje', Icons.flight_takeoff_rounded, Color(0xFF00B4D8)),
  ('En el gimnasio', Icons.fitness_center_rounded, Color(0xFFE63946)),
  ('Solo urgencias', Icons.priority_high_rounded, Color(0xFFD62828)),
  ('Viendo pelota', Icons.sports_baseball_rounded, Color(0xFF1F7A4D)),
  ('Tamo activo', Icons.local_fire_department_rounded, Color(0xFFF77F00)),
  ('En el colmado, ahorita vuelvo', Icons.storefront_rounded, Color(0xFF2EC4B6)),
];

/// Icono que va con un «Info» (si es una sugerencia).
IconData aboutIcon(String text) =>
    aboutSuggestions.where((s) => s.$1 == text).map((s) => s.$2).firstOrNull ?? Icons.chat_bubble_rounded;

/// Texto corto de cuándo se acaba: «hasta las 18:00», «hasta el lunes»…
String? aboutUntilLabel(About a, DateTime now) {
  final u = a.until;
  if (u == null) return null;
  final sameDay = u.year == now.year && u.month == now.month && u.day == now.day;
  if (sameDay) return 'hasta las ${DateFormat.Hm().format(u)}';
  if (u.difference(now).inDays < 6) return 'hasta el ${DateFormat('EEEE HH:mm', currentLanguageCode()).format(u)}';
  return 'hasta el ${DateFormat('d/M HH:mm').format(u)}';
}

/// Elegir mi «Info»: texto (o una sugerencia) y cuánto dura.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  static const _durations = <(String, Duration?)>[
    ('1 hora', Duration(hours: 1)),
    ('8 horas', Duration(hours: 8)),
    ('1 día', Duration(days: 1)),
    ('1 semana', Duration(days: 7)),
    ('Siempre', null),
  ];

  late final TextEditingController _text;
  Duration? _dur = const Duration(days: 1);

  @override
  void initState() {
    super.initState();
    final cur = ref.read(appProvider).profile.activeAbout(DateTime.now());
    _text = TextEditingController(text: cur?.text ?? '');
    if (cur != null && cur.until == null) _dur = null;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = _text.text.trim();
    final app = ref.read(appProvider);
    if (t.isEmpty) {
      await app.updateProfile(removeAbout: true);
    } else {
      final d = _dur;
      await app.updateProfile(about: About(t, until: d == null ? null : DateTime.now().add(d)));
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.6);
    final current = ref.watch(appProvider).profile.activeAbout(DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: const Text('Info'),
        actions: [TextButton(onPressed: _save, child: const Text('Guardar'))],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        TextField(
          controller: _text,
          maxLength: About.maxLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Escribe tu info',
            prefixIcon: Icon(aboutIcon(_text.text.trim())),
            suffixIcon: _text.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Borrar',
                    icon: const Icon(Icons.cancel_rounded),
                    onPressed: () => setState(_text.clear),
                  ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onChanged: (_) => setState(() {}),
        ),
        Text('Tus contactos lo verán en tu info y en los grupos.', style: TextStyle(fontSize: 13, color: muted)),
        const SizedBox(height: 18),
        const Text('Dura', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (label, d) in _durations)
            ChoiceChip(label: Text(label), selected: _dur == d, onSelected: (_) => setState(() => _dur = d)),
        ]),
        const SizedBox(height: 22),
        const Text('Sugerencias', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Material(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final (t, icon, color) in aboutSuggestions)
              ListTile(
                leading: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                title: Text(t),
                trailing: _text.text.trim() == t ? Icon(Icons.check_rounded, color: cs.primary) : null,
                onTap: () => setState(() => _text.text = t),
              ),
          ]),
        ),
        if (current != null) ...[
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () async {
              await ref.read(appProvider).updateProfile(removeAbout: true);
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Quitar mi info'),
            style: TextButton.styleFrom(foregroundColor: cs.error),
          ),
        ],
      ]),
    );
  }
}
