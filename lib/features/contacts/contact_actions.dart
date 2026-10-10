import 'package:flutter/material.dart';

import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';

/// ¿El chat todavía no tiene un nombre puesto por mí? (solo se ve el número)
bool isUnsavedContact(Chat chat) =>
    !chat.isGroup && (chat.title == 'Contacto nuevo' || chat.title == prettyPhone(chat.phone));

/// Poner o cambiar el nombre de un amigo (solo lo ves tú, como en la agenda).
Future<void> editContactName(BuildContext context, AppController app, Chat chat) async {
  final ctrl = TextEditingController(text: isUnsavedContact(chat) ? '' : chat.title);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(chat.isGroup ? 'Nombre del grupo (solo para ti)' : (isUnsavedContact(chat) ? 'Añadir a contactos' : 'Editar contacto')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!chat.isGroup && chat.phone.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(prettyPhone(chat.phone), style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ),
        TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej.: Primo Juan'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
      ],
    ),
  );
  ctrl.dispose();
  if (name == null || name.trim().isEmpty) return;
  await app.renameChat(chat.id, name);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Guardado como ${name.trim()}')));
  }
}

/// Eliminar a un amigo (o un grupo de la lista). Devuelve true si se borró.
Future<bool> deleteContactFlow(BuildContext context, AppController app, Chat chat) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(chat.isGroup ? '¿Eliminar el grupo ${chat.title}?' : '¿Eliminar a ${chat.title}?'),
      content: Text(chat.isGroup
          ? 'Se borrarán el chat y todos sus mensajes de este móvil.'
          : 'Se borrarán el contacto, el chat y todos sus mensajes de este móvil. '
              'No se le avisa. Si te vuelve a escribir, aparecerá como contacto nuevo.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Eliminar'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await app.deleteContact(chat.id);
  return true;
}
