import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../plus/plus_state.dart';
import '../../core/l10n/l10n.dart';
import '../plus/invite_screen.dart';
import '../../core/util/share.dart';

/// Página para descargar KLK (lleva al App Store, Google Play o Windows).
const kInviteUrl = 'https://klkmessenger.com/';

/// Mi código de invitación (se guarda al abrir «Invita y gana Plus»).
String? myInviteCode;

/// Enlace de mi invitación (página con vista previa bonita en WhatsApp).
String? myInviteLink;

String inviteMessage() {
  final base = '${tr('¡Klk! Estoy usando KLK messenger, la app de los dominicanos en el mundo: '
      'privada, gratis y con llamadas cifradas. Descárgala y escríbeme')} 🇩🇴\n$kInviteUrl';
  final code = myInviteCode;
  if (code == null) return base;
  final link = myInviteLink;
  if (link != null) {
    return '${tr('¡Klk! Te invito a KLK messenger, la app de los dominicanos en el mundo')} 🇩🇴 '
        '${tr('Con mi código te llevas 7 días de KLK Plus gratis')} 🎁\n$link';
  }
  return '$base\n\n${tr('Pon mi código al entrar y te llevas 7 días de KLK Plus gratis')}: $code';
}

/// Abre «Compartir» con la invitación lista (WhatsApp, Instagram, SMS…).
Future<void> inviteFriends(BuildContext context) async {
  HapticFeedback.selectionClick();
  await shareText(context, inviteMessage(), subject: 'KLK messenger');
}

/// Tarjeta «Invita a tu gente» para la lista de chats y la pestaña «Tú».
class InviteCard extends StatelessWidget {
  const InviteCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Material(
        color: cs.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => kPlusFeatures
              ? Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InviteScreen()))
              : inviteFriends(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [Color(0xFF002D62), Color(0xFFCE1126)]),
                ),
                child: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Invita a tu gente'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                  const SizedBox(height: 2),
                  Text(kPlusFeatures ? tr('3 amigos = 1 mes de KLK Plus gratis') : tr('Manda KLK por WhatsApp, Instagram o SMS'),
                      style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.65))),
                ]),
              ),
              Icon(Icons.ios_share_rounded, color: cs.primary),
            ]),
          ),
        ),
      ),
    );
  }
}
