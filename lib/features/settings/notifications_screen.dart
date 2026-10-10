import 'package:flutter/material.dart';

import '../../core/notify/alerts.dart';

/// Ajustes → Notificaciones: sonido, avisos, vista previa y vibración.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final alerts = Alerts.instance;
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones')),
      body: ValueListenableBuilder<AlertSettings>(
        valueListenable: alerts.settings,
        builder: (context, s, _) => ListView(children: [
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Sonido'),
            subtitle: const Text('Suena al llegar un mensaje'),
            value: s.sound,
            onChanged: (v) => alerts.update(s.copyWith(sound: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Avisos'),
            subtitle: const Text('Notificación cuando KLK está en segundo plano'),
            value: s.show,
            onChanged: (v) => alerts.update(s.copyWith(show: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_outlined),
            title: const Text('Mostrar el mensaje'),
            subtitle: const Text('Si lo apagas, el aviso solo dice "Mensaje nuevo"'),
            value: s.preview,
            onChanged: (v) => alerts.update(s.copyWith(preview: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vibration),
            title: const Text('Vibración'),
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
