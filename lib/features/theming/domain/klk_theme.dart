import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/brand/klk_brand.dart';

/// Tema de KLK serializable a JSON.
/// Permite temas globales, temas por chat y compartir temas entre usuarios.
@immutable
class KlkTheme {
  final String id;
  final String name;
  final Brightness brightness;
  final Color primary;
  final Color accent;
  final Color background;
  final Color myBubble;
  final Color myBubbleText;
  final Color theirBubble;
  final Color theirBubbleText;
  final double bubbleRadius;
  final String fontFamily; // nombre de Google Fonts

  const KlkTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required this.primary,
    required this.accent,
    required this.background,
    required this.myBubble,
    required this.myBubbleText,
    required this.theirBubble,
    required this.theirBubbleText,
    this.bubbleRadius = 18,
    this.fontFamily = 'Plus Jakarta Sans',
  });

  // ---------- Temas predeterminados ----------

  /// KLK claro: limpio como WhatsApp, con el azul y el rojo de la bandera.
  static const klkClaro = KlkTheme(
    id: 'klk_claro',
    name: 'KLK claro',
    brightness: Brightness.light,
    primary: KlkBrand.azulQuisqueya,
    accent: KlkBrand.rojoPatria,
    background: Color(0xFFEAEFF5), // fondo del chat
    myBubble: Color(0xFFD3E4FD),
    myBubbleText: Color(0xFF0B1B33),
    theirBubble: KlkBrand.blancoPaz,
    theirBubbleText: Color(0xFF111B21),
    bubbleRadius: 12,
    fontFamily: 'Inter',
  );

  /// KLK oscuro: para la noche, como el modo oscuro de WhatsApp.
  static const klkOscuro = KlkTheme(
    id: 'klk_oscuro',
    name: 'KLK oscuro',
    brightness: Brightness.dark,
    primary: Color(0xFF6EA8FF),
    accent: Color(0xFFFF5A6A),
    background: Color(0xFF0B141B),
    myBubble: Color(0xFF16406F),
    myBubbleText: Color(0xFFE9EDF2),
    theirBubble: Color(0xFF1F2C34),
    theirBubbleText: Color(0xFFE9EDEF),
    bubbleRadius: 12,
    fontFamily: 'Inter',
  );

  /// Sigue el modo claro/oscuro del móvil (por defecto).
  static const auto = KlkTheme(
    id: 'auto',
    name: 'Automático',
    brightness: Brightness.light,
    primary: KlkBrand.azulQuisqueya,
    accent: KlkBrand.rojoPatria,
    background: Color(0xFFEAEFF5),
    myBubble: Color(0xFFD3E4FD),
    myBubbleText: Color(0xFF0B1B33),
    theirBubble: KlkBrand.blancoPaz,
    theirBubbleText: Color(0xFF111B21),
    bubbleRadius: 12,
    fontFamily: 'Inter',
  );

  bool get isAuto => id == 'auto';

  static const quisqueya = KlkTheme(
    id: 'quisqueya',
    name: 'Quisqueya',
    brightness: Brightness.light,
    primary: KlkBrand.azulQuisqueya,
    accent: KlkBrand.rojoPatria,
    background: Color(0xFFF5F7FA),
    myBubble: KlkBrand.azulQuisqueya,
    myBubbleText: KlkBrand.blancoPaz,
    theirBubble: KlkBrand.blancoPaz,
    theirBubbleText: Color(0xFF1A1A1A),
  );

  static const nocheCaribe = KlkTheme(
    id: 'noche_caribe',
    name: 'Noche Caribeña',
    brightness: Brightness.dark,
    primary: KlkBrand.mar,
    accent: KlkBrand.sol,
    background: KlkBrand.noche,
    myBubble: Color(0xFF0E4D64),
    myBubbleText: KlkBrand.blancoPaz,
    theirBubble: Color(0xFF1B2433),
    theirBubbleText: Color(0xFFE6EAF0),
  );

  static const amoled = KlkTheme(
    id: 'amoled',
    name: 'Apagón (AMOLED)',
    brightness: Brightness.dark,
    primary: KlkBrand.rojoPatria,
    accent: KlkBrand.sol,
    background: Color(0xFF000000),
    myBubble: Color(0xFF2A0A10),
    myBubbleText: KlkBrand.blancoPaz,
    theirBubble: Color(0xFF111111),
    theirBubbleText: Color(0xFFDDDDDD),
  );

  static const presets = [auto, klkClaro, klkOscuro, quisqueya, nocheCaribe, amoled];

  // ---------- Conversión a Material ----------

  /// Color de las pantallas (listas, ajustes). El fondo del chat es [background].
  Color get surface => brightness == Brightness.light
      ? KlkBrand.blancoPaz
      : Color.lerp(background, const Color(0xFF8696A0), 0.06)!;

  ThemeData toThemeData() {
    final light = brightness == Brightness.light;
    final surf = surface;
    final onSurf = light ? const Color(0xFF111B21) : const Color(0xFFE9EDEF);
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
      primary: primary,
      secondary: accent,
      surface: surf,
      onSurface: onSurf,
    );
    final muted = onSurf.withValues(alpha: light ? 0.6 : 0.65);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: surf,
      splashFactory: InkSparkle.splashFactory,
    );
    TextTheme text;
    try {
      text = GoogleFonts.getTextTheme(fontFamily, base.textTheme);
    } catch (_) {
      text = GoogleFonts.interTextTheme(base.textTheme);
    }
    return base.copyWith(
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: surf,
        foregroundColor: onSurf,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        shadowColor: Colors.black26,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(color: onSurf, fontWeight: FontWeight.w700, fontSize: 19),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surf,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: primary.withValues(alpha: light ? 0.12 : 0.22),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 12.5,
              fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
              color: s.contains(WidgetState.selected) ? onSurf : muted,
            )),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              size: 25,
              color: s.contains(WidgetState.selected) ? (light ? primary : onSurf) : muted,
            )),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: light ? Colors.white : const Color(0xFF0B141B),
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: DividerThemeData(color: onSurf.withValues(alpha: 0.08), thickness: 0.6, space: 0.6),
      listTileTheme: ListTileThemeData(iconColor: muted),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: light ? const Color(0xFFF0F2F5) : const Color(0xFF233138),
        selectedColor: primary.withValues(alpha: light ? 0.14 : 0.3),
        labelStyle: TextStyle(color: onSurf, fontWeight: FontWeight.w600, fontSize: 13.5),
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: light ? const Color(0xFFF0F2F5) : const Color(0xFF233138),
        hintStyle: TextStyle(color: muted),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      extensions: [BubbleStyle.fromTheme(this)],
    );
  }

  // ---------- Serialización ----------

  KlkTheme copyWith({
    String? id,
    String? name,
    Brightness? brightness,
    Color? primary,
    Color? accent,
    Color? background,
    Color? myBubble,
    Color? myBubbleText,
    Color? theirBubble,
    Color? theirBubbleText,
    double? bubbleRadius,
    String? fontFamily,
  }) =>
      KlkTheme(
        id: id ?? this.id,
        name: name ?? this.name,
        brightness: brightness ?? this.brightness,
        primary: primary ?? this.primary,
        accent: accent ?? this.accent,
        background: background ?? this.background,
        myBubble: myBubble ?? this.myBubble,
        myBubbleText: myBubbleText ?? this.myBubbleText,
        theirBubble: theirBubble ?? this.theirBubble,
        theirBubbleText: theirBubbleText ?? this.theirBubbleText,
        bubbleRadius: bubbleRadius ?? this.bubbleRadius,
        fontFamily: fontFamily ?? this.fontFamily,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'brightness': brightness.name,
        'primary': _hex(primary),
        'accent': _hex(accent),
        'background': _hex(background),
        'myBubble': _hex(myBubble),
        'myBubbleText': _hex(myBubbleText),
        'theirBubble': _hex(theirBubble),
        'theirBubbleText': _hex(theirBubbleText),
        'bubbleRadius': bubbleRadius,
        'fontFamily': fontFamily,
      };

  factory KlkTheme.fromJson(Map<String, dynamic> j) => KlkTheme(
        id: j['id'] as String,
        name: j['name'] as String,
        brightness: j['brightness'] == 'dark' ? Brightness.dark : Brightness.light,
        primary: _color(j['primary']),
        accent: _color(j['accent']),
        background: _color(j['background']),
        myBubble: _color(j['myBubble']),
        myBubbleText: _color(j['myBubbleText']),
        theirBubble: _color(j['theirBubble']),
        theirBubbleText: _color(j['theirBubbleText']),
        bubbleRadius: (j['bubbleRadius'] as num?)?.toDouble() ?? 18,
        fontFamily: j['fontFamily'] as String? ?? 'Plus Jakarta Sans',
      );

  String encode() => jsonEncode(toJson());
  factory KlkTheme.decode(String s) =>
      KlkTheme.fromJson(jsonDecode(s) as Map<String, dynamic>);

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static Color _color(Object? v) {
    final s = (v as String).replaceFirst('#', '');
    return Color(int.parse(s.length == 6 ? 'FF$s' : s, radix: 16));
  }
}

/// Extensión de tema con el estilo de las burbujas de chat.
@immutable
class BubbleStyle extends ThemeExtension<BubbleStyle> {
  final Color mine, mineText, theirs, theirsText;
  final double radius;

  /// Fondo detrás de los mensajes.
  final Color chatBg;

  const BubbleStyle({
    required this.mine,
    required this.mineText,
    required this.theirs,
    required this.theirsText,
    required this.radius,
    this.chatBg = const Color(0xFFEAEFF5),
  });

  factory BubbleStyle.fromTheme(KlkTheme t) => BubbleStyle(
        mine: t.myBubble,
        mineText: t.myBubbleText,
        theirs: t.theirBubble,
        theirsText: t.theirBubbleText,
        radius: t.bubbleRadius,
        chatBg: t.background,
      );

  @override
  BubbleStyle copyWith({
    Color? mine,
    Color? mineText,
    Color? theirs,
    Color? theirsText,
    double? radius,
    Color? chatBg,
  }) =>
      BubbleStyle(
        mine: mine ?? this.mine,
        mineText: mineText ?? this.mineText,
        theirs: theirs ?? this.theirs,
        theirsText: theirsText ?? this.theirsText,
        radius: radius ?? this.radius,
        chatBg: chatBg ?? this.chatBg,
      );

  @override
  BubbleStyle lerp(BubbleStyle? other, double t) {
    if (other == null) return this;
    return BubbleStyle(
      mine: Color.lerp(mine, other.mine, t)!,
      mineText: Color.lerp(mineText, other.mineText, t)!,
      theirs: Color.lerp(theirs, other.theirs, t)!,
      theirsText: Color.lerp(theirsText, other.theirsText, t)!,
      radius: radius + (other.radius - radius) * t,
      chatBg: Color.lerp(chatBg, other.chatBg, t)!,
    );
  }
}
