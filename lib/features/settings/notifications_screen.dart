import 'package:flutter/material.dart';

import '../../core/notify/alerts.dart';
import '../../core/l10n/l10n.dart';
import '../plus/plus_screen.dart';
import '../plus/plus_state.dart';

/// Ajustes → Notificaciones: sonido, avisos, vista previa y vibración.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  /// Hoja para elegir un tono (de mensaje o de llamada) con ▶ para oírlo.
  static Future<void> _pick(
    BuildContext context, {
    required String title,
    required String subtitle,
    required List<KlkTone> tones,
    required String current,
    required void Function(String id) play,
    required void Function(String id) choose,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        maxChildSize: .92,
        builder: (ctx, scroll) => ListView(controller: scroll, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(subtitle)),
          for (final t in tones)
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
                  onPressed: () => play(t.id),
                ),
                if (current == t.id) const Icon(Icons.check_circle, color: Colors.green),
              ]),
              onTap: () {
                if (t.plus && !plusActive.value) {
                  Navigator.pop(ctx);
                  showPlusRequired(context, 'El tono ${t.name}');
                  return;
                }
                choose(t.id);
                play(t.id);
                Navigator.pop(ctx);
              },
            ),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }

  static Future<void> _pickTone(BuildContext context, AlertSettings s) => _pick(
        context,
        title: 'Tono de los mensajes',
        subtitle: 'Sonidos grabados con instrumentos de verdad. Toca ▶ para oírlos.',
        tones: klkTones,
        current: s.tone,
        play: Alerts.instance.playTone,
        choose: (id) => Alerts.instance.update(Alerts.instance.settings.value.copyWith(tone: id)),
      );

  static Future<void> _pickRing(BuildContext context, AlertSettings s) async {
    await _pick(
      context,
      title: 'Tono de llamada',
      subtitle: 'Bachata, merengue, dembow, salsa y más. Toca ▶ para oírlos.',
      tones: klkRings,
      current: s.ring,
      play: Alerts.instance.playRing,
      choose: (id) => Alerts.instance.update(Alerts.instance.settings.value.copyWith(ring: id)),
    );
    // Al cerrar la hoja se para la canción de prueba (salvo el tono recién elegido, que suena un poco).
    Future<void>.delayed(const Duration(seconds: 4), Alerts.instance.stopPreview);
  }

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
          ListTile(
            leading: const Icon(Icons.ring_volume_outlined),
            title: const Text('Tono de llamada'),
            subtitle: Text(ringName(s.ring)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickRing(context, s),
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
              'Los avisos llegan aunque KLK esté cerrado. Por privacidad, el aviso solo dice '
              '«Tienes un mensaje nuevo»: el mensaje se descifra al abrir KLK.',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ),
        ]),
      ),
    );
  }
}
