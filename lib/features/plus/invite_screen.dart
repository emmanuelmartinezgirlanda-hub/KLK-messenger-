import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/network/api_client.dart';
import '../contacts/invite.dart';
import '../messaging/app_controller.dart';

/// «Invita a tus amigos y gana Plus»: cada 3 amigos que entran con tu código,
/// 1 mes de KLK Plus gratis. Ellos se llevan 7 días.
class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key});

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  Map<String, dynamic>? _v;
  bool _loading = true;
  final _code = TextEditingController();
  bool _claiming = false;
  String? _claimMsg;
  bool _claimOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final v = await ref.read(appProvider).inviteStatus();
    if (v != null) {
      myInviteCode = v['code'] as String?;
      final api = ref.read(appProvider).serverApi;
      if (api != null && myInviteCode != null) myInviteLink = api.base.replace(path: '/i/$myInviteCode').toString();
    }
    if (mounted) {
      setState(() {
        _v = v;
        _loading = false;
      });
    }
  }

  Future<void> _claim() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _claiming = true;
      _claimMsg = null;
    });
    try {
      final j = await ref.read(appProvider).claimInvite(code);
      final inv = j['invite'];
      setState(() {
        if (inv is Map<String, dynamic>) _v = inv;
        _claimOk = true;
        _claimMsg = tr('¡Listo! Tienes 7 días de KLK Plus de regalo 🎁');
      });
    } on ApiException catch (e) {
      setState(() {
        _claimOk = false;
        _claimMsg = e.message;
      });
    } catch (_) {
      setState(() {
        _claimOk = false;
        _claimMsg = tr('No se pudo. Revisa tu internet.');
      });
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = _v;
    final code = v?['code'] as String?;
    final count = (v?['count'] as num?)?.toInt() ?? 0;
    final per = (v?['perReward'] as num?)?.toInt() ?? 3;
    final months = (v?['months'] as num?)?.toInt() ?? 0;
    final done = count % per;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Invita y gana Plus'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(20), children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF002D62), Color(0xFFCE1126)]),
                ),
                child: Column(children: [
                  const Text('🎁', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 6),
                  Text(tr('3 amigos = 1 mes de KLK Plus gratis'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 6),
                  Text(tr('Y ellos se llevan 7 días de Plus al entrar con tu código.'),
                      textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 18),
                  if (code != null)
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: code));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(tr('Código copiado'))));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(code,
                              style: const TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 2, color: Color(0xFF002D62))),
                          const SizedBox(width: 10),
                          const Icon(Icons.copy_rounded, color: Color(0xFF002D62)),
                        ]),
                      ),
                    )
                  else
                    Text(tr('Conéctate a internet para ver tu código.'), style: const TextStyle(color: Colors.white)),
                ]),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => inviteFriends(context),
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(tr('Compartir mi invitación')),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              ),
              if (v != null) ...[
                const SizedBox(height: 24),
                Text(tr('Tu progreso'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < per; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: CircleAvatar(
                        radius: 26,
                        backgroundColor: i < done ? cs.primary : cs.surfaceContainerHighest,
                        child: Icon(i < done ? Icons.person : Icons.person_outline,
                            color: i < done ? cs.onPrimary : cs.onSurfaceVariant),
                      ),
                    ),
                ]),
                const SizedBox(height: 10),
                Text(
                  '${tr('Amigos que se unieron')}: $count · ${tr('Te faltan')} ${per - done} ${tr('para el próximo mes')}',
                  textAlign: TextAlign.center,
                ),
                if (months > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('🏆 ${tr('Has ganado')} $months ${months == 1 ? tr('mes') : tr('meses')} ${tr('de Plus')}',
                        textAlign: TextAlign.center, style: TextStyle(color: cs.primary, fontWeight: FontWeight.w800)),
                  ),
                if (v['canClaim'] == true && !_claimOk) ...[
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 12),
                  Text(tr('¿Te invitó un amigo?'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(tr('Pon su código y te llevas 7 días de Plus (él suma un amigo).'),
                      style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _code,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(hintText: 'KLK…'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _claiming ? null : _claim,
                      child: _claiming
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(tr('Usar')),
                    ),
                  ]),
                ],
                if (_claimMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_claimMsg!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _claimOk ? cs.primary : cs.error, fontWeight: FontWeight.w600)),
                  ),
              ],
            ]),
    );
  }
}
