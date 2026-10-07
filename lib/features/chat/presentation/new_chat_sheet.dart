import 'package:flutter/material.dart';

import '../../contacts/new_chat_screen.dart';

/// Abre la pantalla "Nuevo chat" (contactos en KLK, nuevo contacto, invitar…).
Future<void> showNewChatSheet(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewChatScreen()));
