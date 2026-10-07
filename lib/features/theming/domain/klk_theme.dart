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

  static const presets = [quisqueya, nocheCaribe, amoled];

  // ---------- Conversión a Material ----------

  ThemeData toThemeData() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
      primary: primary,
      secondary: accent,
      surface: background,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
    );
    return base.copyWith(
      textTheme: GoogleFonts.getTextTheme(fontFamily, base.textTheme),
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

  const BubbleStyle({
    required this.mine,
    required this.mineText,
    required this.theirs,
    required this.theirsText,
    required this.radius,
  });

  factory BubbleStyle.fromTheme(KlkTheme t) => BubbleStyle(
        mine: t.myBubble,
        mineText: t.myBubbleText,
        theirs: t.theirBubble,
        theirsText: t.theirBubbleText,
        radius: t.bubbleRadius,
      );

  @override
  BubbleStyle copyWith({
    Color? mine,
    Color? mineText,
    Color? theirs,
    Color? theirsText,
    double? radius,
  }) =>
      BubbleStyle(
        mine: mine ?? this.mine,
        mineText: mineText ?? this.mineText,
        theirs: theirs ?? this.theirs,
        theirsText: theirsText ?? this.theirsText,
        radius: radius ?? this.radius,
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
    );
  }
}
