import 'package:flutter/material.dart';

import '../../core/util/phone.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import '../../core/l10n/l10n.dart';

/// ¿El chat todavía no tiene un nombre puesto por mí? (solo se ve el número)
bool isUnsavedContact(Chat chat) =>
    !chat.isGroup && (chat.title == 'Contacto nuevo' || chat.title == prettyPhone(chat.phone));

/// Poner o cambiar el nombre de un amigo (solo lo ves tú, como en la agenda).
Future<void> editContactName(BuildContext context, AppController app, Chat chat) async {
  final ctrl = TextEditingController(text: isUnsavedContact(chat) ? '' : chat.title);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(chat.isGroup ? tr('Nombre del grupo (solo para ti)') : (isUnsavedContact(chat) ? tr('Añadir a contactos') : tr('Editar contacto'))),
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
          decoration: InputDecoration(labelText: tr('Nombre'), hintText: tr('Ej.: Primo Juan')),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancelar'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('Guardar'))),
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

/// Vaciar un chat: borra todos los mensajes pero deja el chat y el contacto.
Future<bool> clearChatFlow(BuildContext context, AppController app, Chat chat) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(chat.isNotes ? '¿Vaciar tus notas?' : '¿Vaciar el chat con ${chat.title}?'),
      content: Text(tr('Se borrarán todos los mensajes de este chat en este móvil. El contacto no se borra.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Vaciar')),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await app.clearChat(chat.id);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Chat vaciado'))));
  }
  return true;
}

/// Eliminar a un amigo (o un grupo de la lista). Devuelve true si se borró.
Future<bool> deleteContactFlow(BuildContext context, AppController app, Chat chat) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(chat.isGroup ? '¿Eliminar el grupo ${chat.title}?' : '¿Eliminar el chat con ${chat.title}?'),
      content: Text(chat.isGroup
          ? 'Se borrarán el chat y todos sus mensajes de este móvil.'
          : 'Se borrarán el contacto, el chat y todos sus mensajes de este móvil. '
              'No se le avisa. Si te vuelve a escribir, aparecerá como contacto nuevo.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancelar'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCE1126)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Eliminar')),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await app.deleteContact(chat.id);
  return true;
}
