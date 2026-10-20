import 'package:flutter/material.dart';

import '../../core/notify/alerts.dart';
import '../../core/l10n/l10n.dart';
import '../plus/plus_screen.dart';
import '../plus/plus_state.dart';

/// Ajustes → Notificaciones: sonido, avisos, vista previa y vibración.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  static Future<void> _pickTone(BuildContext context, AlertSettings s) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Tono de los mensajes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Sonidos dominicanos hechos para KLK. Toca ▶ para oírlos.'),
            ),
            for (final t in klkTones)
              ListTile(
                leading: Text(t.emoji, style: const TextStyle(fontSize: 26)),
                title: Row(children: [
                  Flexible(child: Text(t.name)),
                  if (t.plus && !plusActive.value) ...[const SizedBox(width: 8), const PlusMark(size: 18)],
                ]),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Escuchar',
                    icon: const Icon(Icons.play_circle_outline),
                    onPressed: () => Alerts.instance.playTone(t.id),
                  ),
                  if (Alerts.instance.settings.value.tone == t.id) const Icon(Icons.check_circle, color: Colors.green),
                ]),
                onTap: () {
                  if (t.plus && !plusActive.value) {
                    Navigator.pop(ctx);
                    showPlusRequired(context, 'El tono ${t.name}');
                    return;
                  }
                  Alerts.instance.update(Alerts.instance.settings.value.copyWith(tone: t.id));
                  Alerts.instance.playTone(t.id);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final alerts = Alerts.instance;
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Notificaciones'))),
      body: ValueListenableBuilder<AlertSettings>(
        valueListenable: alerts.settings,
        builder: (context, s, _) => ListView(children: [
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: Text(tr('Sonido')),
            subtitle: Text(tr('Suena al llegar un mensaje')),
            value: s.sound,
            onChanged: (v) => alerts.update(s.copyWith(sound: v)),
          ),
          ListTile(
            leading: const Icon(Icons.music_note_outlined),
            title: const Text('Tono de los mensajes'),
            subtitle: Text(toneName(s.tone)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickTone(context, s),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: Text(tr('Avisos')),
            subtitle: Text(tr('Notificación cuando KLK está en segundo plano')),
            value: s.show,
            onChanged: (v) => alerts.update(s.copyWith(show: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_outlined),
            title: Text(tr('Mostrar el mensaje')),
            subtitle: Text(tr('Si lo apagas, el aviso solo dice "Mensaje nuevo"')),
            value: s.preview,
            onChanged: (v) => alerts.update(s.copyWith(preview: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vibration),
            title: Text(tr('Vibración')),
            value: s.vibrate,
            onChanged: (v) => alerts.update(s.copyWith(vibrate: v)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Text(
              'El número rojo en el icono de KLK indica los mensajes sin leer.\n\n'
              'Con KLK cerrado del todo, el iPhone solo entrega avisos mediante las notificaciones '
              'push de Apple, que requieren la cuenta de desarrollador de pago. Mientras tanto, '
              'KLK avisa con la app abierta o recién minimizada.',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
        ]),
      ),
    );
  }
}
