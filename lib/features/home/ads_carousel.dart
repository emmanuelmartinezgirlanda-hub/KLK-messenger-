import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/l10n.dart';
import '../../core/ui/link_text.dart';
import '../chat/presentation/chat_screen.dart';
import '../messaging/app_controller.dart';
import '../messaging/models.dart';
import '../plus/plus_screen.dart';
import '../plus/plus_state.dart';
import 'my_ad_screen.dart';

/// Anuncios que pasan solos arriba de la lista de chats: negocios (los pone el
/// dueño desde su panel), cosas de KLK Plus (para quien no lo tiene) y
/// «Anuncia tu negocio aquí».
class AdsCarousel extends ConsumerStatefulWidget {
  const AdsCarousel({super.key});

  @override
  ConsumerState<AdsCarousel> createState() => _AdsCarouselState();
}

class _Slide {
  final String tag, title, body, cta;
  final Color bg, fg;
  final String? imageUrl;
  final IconData? icon;
  final String? emoji;
  final ImageProvider? logo;
  final VoidCallback onTap;
  const _Slide({
    required this.tag,
    required this.title,
    required this.body,
    required this.cta,
    required this.bg,
    required this.onTap,
    this.fg = Colors.white,
    this.imageUrl,
    this.icon,
    this.emoji,
    this.logo,
  });
}

const _adColors = {
  'red': Color(0xFFD7263D),
  'blue': Color(0xFF1E6FE8),
  'navy': Color(0xFF14213D),
  'green': Color(0xFF1F7A4D),
  'purple': Color(0xFF5F3DC4),
  'orange': Color(0xFFC2410C),
  'black': Color(0xFF16181D),
};

const _gold = Color(0xFF2C220E);

class _AdsCarouselState extends ConsumerState<AdsCarousel> {
  final _page = PageController(viewportFraction: 0.93);
  Timer? _timer;
  int _index = 0;
  bool _touching = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _next());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  void _next() {
    if (!mounted || _touching || !_page.hasClients) return;
    final n = _count;
    if (n < 2) return;
    final to = (_index + 1) % n;
    if (to == 0) {
      _page.jumpToPage(0);
    } else {
      _page.animateToPage(to, duration: const Duration(milliseconds: 550), curve: Curves.easeOutCubic);
    }
  }

  int _count = 0;

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Al tocar un anuncio: su web (o teléfono), su @usuario de KLK, o un chat
  /// con el negocio dentro de KLK. Si no tiene nada, se enseña el anuncio entero.
  Future<void> _tapAd(AppController app, KlkAd a) async {
    final url = a.url.trim();
    try {
      if (url.startsWith('@')) {
        final id = await app.startChatWithUsername(url.substring(1));
        if (id != null && mounted) _openChat(id);
        return;
      }
      if (url.isNotEmpty) {
        await _open(url);
        return;
      }
      if (a.chat.isNotEmpty && a.chat != app.session?.accountId) {
        final id = await app.startChatWithAccount(a.chat, a.title);
        if (mounted) _openChat(id);
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            LinkText(a.body, style: const TextStyle(fontSize: 16)),
          ]),
        ),
      ),
    );
  }

  void _openChat(String chatId) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));

  List<_Slide> _slides(AppController app, bool plus) {
    void plusScreen() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PlusScreen()));
    final out = <_Slide>[
      for (final a in app.ads)
        _Slide(
          tag: tr('Anuncio'),
          title: a.title,
          body: a.body,
          cta: a.cta,
          bg: _adColors[a.color] ?? _adColors['red']!,
          imageUrl: app.adImageUrl(a),
          onTap: () {
            app.adClicked(a.id);
            _tapAd(app, a);
          },
        ),
    ];
    if (kPlusFeatures && !plus) {
      final promos = [
        _Slide(
          tag: 'KLK Plus',
          title: tr('Stickers con movimiento'),
          body: tr('Paquetes animados que solo tiene la gente Plus'),
          cta: tr('Ver Plus'),
          bg: _gold,
          emoji: '✨',
          onTap: plusScreen,
        ),
        _Slide(
          tag: 'KLK Plus',
          title: tr('Subtítulos en las llamadas'),
          body: tr('Lee en tu idioma lo que te dicen, en directo'),
          cta: tr('Ver Plus'),
          bg: _gold,
          emoji: '🌎',
          onTap: plusScreen,
        ),
        _Slide(
          tag: 'KLK Plus',
          title: tr('Temas, iconos y tonos'),
          body: tr('Pon KLK a tu manera, con colores exclusivos'),
          cta: tr('Ver Plus'),
          bg: _gold,
          emoji: '👑',
          onTap: plusScreen,
        ),
      ];
      // Los de Plus van intercalados con los negocios.
      for (var i = 0; i < promos.length; i++) {
        out.insert((i * 2 + 1).clamp(0, out.length), promos[i]);
      }
    }
    out.add(_Slide(
      tag: tr('KLK Negocios'),
      title: tr('¿Tienes un negocio?'),
      body: tr('Pon tu anuncio aquí y que lo vea todo el mundo en KLK'),
      cta: tr('Anunciar'),
      bg: const Color(0xFFF1F3F7),
      fg: const Color(0xFF14213D),
      icon: Icons.storefront_rounded,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyAdScreen())),
    ));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: plusActive,
      builder: (context, plus, _) {
        final slides = _slides(app, plus);
        _count = slides.length;
        if (_index >= slides.length) _index = 0;
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 6),
          child: Column(children: [
            SizedBox(
              height: 104,
              child: Listener(
                onPointerDown: (_) => _touching = true,
                onPointerUp: (_) => _touching = false,
                onPointerCancel: (_) => _touching = false,
                child: PageView.builder(
                  controller: _page,
                  itemCount: slides.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _AdCard(slide: slides[i]),
                  ),
                ),
              ),
            ),
            if (slides.length > 1) ...[
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _index ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _index
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ]),
            ],
          ]),
        );
      },
    );
  }
}

class _AdCard extends StatelessWidget {
  final _Slide slide;
  const _AdCard({required this.slide});

  /// Vista previa de un anuncio (para «Mi anuncio»).
  static Widget preview({
    required String title,
    required String body,
    required String cta,
    required String color,
    ImageProvider? logo,
  }) =>
      _AdCard(
          slide: _Slide(
        tag: 'Anuncio',
        title: title.isEmpty ? 'Tu negocio' : title,
        body: body.isEmpty ? 'Tu mensaje aquí' : body,
        cta: cta.isEmpty ? 'Ver' : cta,
        bg: _adColors[color] ?? _adColors['red']!,
        logo: logo,
        onTap: () {},
      ));

  @override
  Widget build(BuildContext context) {
    final s = slide;
    final dark = s.fg == Colors.white;
    Widget tile;
    if (s.logo != null) {
      tile = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image(image: s.logo!, width: 64, height: 64, fit: BoxFit.cover),
      );
    } else if (s.imageUrl != null) {
      tile = ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.network(s.imageUrl!,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _initial(s, dark)),
      );
    } else if (s.emoji != null) {
      tile = Container(
        width: 64,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFFFFD86B), Color(0xFFE0B54A)]),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(s.emoji!, style: const TextStyle(fontSize: 32)),
      );
    } else if (s.icon != null) {
      tile = Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(color: const Color(0xFFD7263D), borderRadius: BorderRadius.circular(16)),
        child: Icon(s.icon, color: Colors.white, size: 34),
      );
    } else {
      tile = _initial(s, dark);
    }
    final isPlus = s.tag == 'KLK Plus';
    return Material(
      color: s.bg,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          s.onTap();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(children: [
            tile,
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(s.tag.toUpperCase(),
                    style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w800,
                        color: isPlus ? const Color(0xFFFFD86B) : s.fg.withValues(alpha: 0.75))),
                const SizedBox(height: 2),
                Text(s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: s.fg)),
                const SizedBox(height: 2),
                Text(s.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, height: 1.25, color: s.fg.withValues(alpha: 0.88))),
              ]),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isPlus
                    ? const Color(0xFFFFD86B)
                    : dark
                        ? Colors.white
                        : const Color(0xFFD7263D),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(s.cta,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                      color: isPlus
                          ? const Color(0xFF2C220E)
                          : dark
                              ? s.bg
                              : Colors.white)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _initial(_Slide s, bool dark) => Container(
        width: 64,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: dark ? Colors.white : const Color(0xFF14213D),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          s.title.isEmpty ? '?' : s.title.characters.first.toUpperCase(),
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: dark ? s.bg : Colors.white),
        ),
      );
}

/// Vista previa pública del anuncio (la usa «Mi anuncio»).
Widget adPreview({required String title, required String body, required String cta, required String color, ImageProvider? logo}) =>
    _AdCard.preview(title: title, body: body, cta: cta, color: color, logo: logo);

/// Colores que puede elegir un negocio (mismos nombres que en el servidor).
const adColorChoices = _adColors;
