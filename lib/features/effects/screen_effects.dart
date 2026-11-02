import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'effect_art.dart';

// Efectos de pantalla de KLK Plus: dibujos animados que cruzan el chat al
// enviar un mensaje. El id del efecto viaja cifrado dentro del mensaje («fx»);
// quien lo recibe lo ve al abrir el chat.

const _red = Color(0xFFE8283E);
const _navy = Color(0xFF0D2A66);
const _blue = Color(0xFF2E6BFF);
const _sky = Color(0xFF3D8BFF);
const _gold = Color(0xFFFFC531);
const _green = Color(0xFF3CB371);
const _orange = Color(0xFFE86A10);
const _purple = Color(0xFF6A2C91);

double _rad(double deg) => deg * math.pi / 180;

/// Un momento clave de un dibujo: posición (arriba-izquierda), giro, tamaño y opacidad.
class Kf {
  final double t, x, y, r, s, o;
  const Kf(this.t, this.x, this.y, {this.r = 0, this.s = 1, this.o = 1});
}

/// Un dibujo que se mueve entre momentos clave durante [dur] ms desde [start].
class Track {
  final Widget child;
  final double w, h, start, dur;
  final List<Kf> kf;
  final Curve curve;
  final Alignment origin;
  final int z;
  const Track(this.child, this.w, this.h, this.start, this.dur, this.kf,
      {this.curve = Curves.linear, this.origin = Alignment.center, this.z = 3});

  double get end => start + dur;

  Kf at(double ms) {
    final p = curve.transform(((ms - start) / dur).clamp(0.0, 1.0));
    if (p <= kf.first.t) return kf.first;
    for (var i = 1; i < kf.length; i++) {
      final b = kf[i];
      if (p <= b.t) {
        final a = kf[i - 1];
        final u = b.t == a.t ? 1.0 : (p - a.t) / (b.t - a.t);
        double l(double x, double y) => x + (y - x) * u;
        return Kf(p, l(a.x, b.x), l(a.y, b.y), r: l(a.r, b.r), s: l(a.s, b.s), o: l(a.o, b.o));
      }
    }
    return kf.last;
  }
}

/// Construye la animación para un tamaño de pantalla.
class Fx {
  final Size size;
  final math.Random rnd;
  final tracks = <Track>[];
  Fx(this.size, this.rnd);

  double get W => size.width;
  double get H => size.height;
  double r(double a, double b) => a + rnd.nextDouble() * (b - a);
  double get total => tracks.fold(0.0, (m, t) => math.max(m, t.end));

  Track add(Widget child, double w, double h, double start, double dur, List<Kf> kf,
      {Curve curve = Curves.linear, Alignment origin = Alignment.center, int z = 3}) {
    final t = Track(child, w, h, start, dur, kf, curve: curve, origin: origin, z: z);
    tracks.add(t);
    return t;
  }

  Track art(String svg, double w, double h, double start, double dur, List<Kf> kf,
          {Curve curve = Curves.linear, Alignment origin = Alignment.center, int z = 3}) =>
      add(SvgPicture.string(svg, width: w, height: h, fit: BoxFit.fill), w, h, start, dur, kf,
          curve: curve, origin: origin, z: z);

  /// Momentos clave en milisegundos (más fácil de escribir).
  Track artMs(String svg, double w, double h, List<(double, Kf)> steps, {Alignment origin = Alignment.center, int z = 3}) {
    final s0 = steps.first.$1, d = math.max(1.0, steps.last.$1 - s0);
    return art(svg, w, h, s0, d, [for (final (ms, k) in steps) Kf((ms - s0) / d, k.x, k.y, r: k.r, s: k.s, o: k.o)],
        origin: origin, z: z);
  }

  /// Texto grande con borde que aparece de golpe («¡Klk!»).
  void shout(String text, double y, {double size = 30, double at = 0, Color stroke = _red, double? x, int z = 8}) {
    final w = x == null ? W : W - x;
    final x0 = x ?? 0;
    add(
      Align(alignment: x == null ? Alignment.center : Alignment.centerLeft, child: _Outlined(text, size, stroke)),
      w, size * 1.4, at, 1600,
      [
        Kf(0, x0, y, s: .3, r: _rad(-8), o: 0),
        Kf(.25, x0, y, s: 1.15, r: _rad(3)),
        Kf(.4, x0, y, r: _rad(-2)),
        Kf(.85, x0, y - 10),
        Kf(1, x0, y - 24, s: .9, o: 0),
      ],
      curve: Curves.easeOut,
      origin: x == null ? Alignment.center : Alignment.centerLeft,
      z: z,
    );
  }

  /// Texto pequeño que sale volando (notas de música…).
  void floatText(String text, double x, double y, double dx, double dy, double at,
      {double size = 32, Color stroke = _blue, double dur = 1300}) {
    add(_Outlined(text, size, stroke), size * 1.4, size * 1.4, at, dur,
        [Kf(0, x, y), Kf(1, x + dx, y + dy, r: _rad(r(-30, 30)), o: 0)],
        curve: Curves.easeOut, z: 7);
  }

  /// Bolita que se expande y se desvanece (humo, confeti, chispas).
  void puff(double x, double y, Color c, double dx, double dy, double size, double at, {double dur = 900, int z = 3}) {
    add(DecoratedBox(decoration: BoxDecoration(color: c, shape: BoxShape.circle)), size, size, at, dur,
        [Kf(0, x, y, s: .4, o: .9), Kf(1, x + dx, y + dy, s: 1.4, o: 0)],
        curve: Curves.easeOut, z: z);
  }

  /// Confeti rectangular que cae.
  void confetti(double x, double at, Color c, {double dur = 2000}) {
    add(ColoredBox(color: c), 10, 6, at, dur,
        [Kf(0, x, -10), Kf(1, x + r(-40, 40), H + 10, r: _rad(r(200, 700)))],
        curve: Curves.easeIn, z: 2);
  }

  /// Hace algo cada [every] ms entre [from] y [to].
  void each(double from, double to, double every, void Function(double t) f) {
    for (var t = from; t < to; t += every) {
      f(t);
    }
  }
}

class _Outlined extends StatelessWidget {
  final String text;
  final double size;
  final Color stroke;
  const _Outlined(this.text, this.size, this.stroke);
  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: size, fontWeight: FontWeight.w900, height: 1, letterSpacing: .5);
    return Stack(children: [
      Text(text,
          maxLines: 1,
          softWrap: false,
          style: base.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = size * .2
                ..strokeJoin = StrokeJoin.round
                ..color = stroke)),
      Text(text, maxLines: 1, softWrap: false, style: base.copyWith(color: Colors.white)),
    ]);
  }
}

/// Un efecto de pantalla.
class ScreenEffect {
  final String id, name, msg, group, thumb;
  final void Function(Fx f) build;
  const ScreenEffect(this.id, this.name, this.msg, this.group, this.thumb, this.build);
}

const fxGroups = ['Dominicanos', 'Navidad y Reyes', 'Halloween', 'Celebrar'];

ScreenEffect? effectById(String? id) {
  if (id == null) return null;
  for (final e in screenEffects) {
    if (e.id == id) return e;
  }
  return null;
}

final screenEffects = <ScreenEffect>[
  // ---------------- Dominicanos ----------------
  ScreenEffect('moto', 'Motoconcho', '¡Voy pa\' allá!', 'Dominicanos', artMoto, (f) {
    const w = 150.0, h = 104.0;
    final y = f.H * .52;
    final d = f.art(artMoto, w, h, 0, 2400, [
      Kf(0, -w, y),
      Kf(.45, f.W * .35, y - 6, r: _rad(-6)),
      Kf(.65, f.W * .6, y, r: _rad(2)),
      Kf(1, f.W + 20, y - 4, r: _rad(-3)),
    ], curve: Curves.easeInOut);
    f.each(0, 2400, 90, (t) => f.puff(d.at(t).x + 4, y + h * .62, const Color(0xCCC8D2E6), -30, -14, 18, t));
    f.shout('¡PIIIP PIIIP!', y - 70, at: 500);
  }),
  ScreenEffect('guagua', 'La guagua', '¡Súbete que hay espacio!', 'Dominicanos', artGuagua, (f) {
    const w = 200.0, h = 118.0;
    final y = f.H * .5;
    f.art(artGuagua, w, h, 0, 3000, [
      for (var i = 0; i <= 12; i++)
        Kf(i / 12, f.W - (f.W + w + 20) * i / 12, y - (i.isOdd ? 14 : 0), r: _rad(i.isOdd ? -3 : 2)),
    ]);
    f.shout('¡Hay espacio!', y - 64, size: 28, at: 400, stroke: _navy);
  }),
  ScreenEffect('platano', 'Plátano bailador', '¡Eso e\' así!', 'Dominicanos', artPlatano, (f) {
    const w = 110.0, h = 132.0;
    final y = f.H * .42;
    f.art(artPlatano, w, h, 0, 3200, [
      for (var i = 0; i <= 16; i++)
        Kf(i / 16, -w + (f.W + w * 2) * i / 16, y - (i.isOdd ? 22 : 0), r: _rad(i.isOdd ? 14 : -14)),
    ]);
    f.shout('¡A gozar!', y - 50, at: 600);
    for (var i = 0; i < 5; i++) {
      f.floatText('♪', f.r(20, f.W - 40), y + f.r(-40, 40), f.r(-40, 40), -80, 400 + i * 450.0, stroke: _sky);
    }
  }),
  ScreenEffect('mangos', 'Lluvia de mangos', '¡Cayeron mangos!', 'Dominicanos', artMango, (f) {
    for (var i = 0; i < 14; i++) {
      final s = f.r(38, 62), x = f.r(-10, f.W - 40), fl = f.H - s * 1.6 - f.r(0, 30);
      f.art(artMango, s, s * 1.1, i * 110.0, 2600, [
        Kf(0, x, -80),
        Kf(.55, x, fl, r: _rad(f.r(-90, 90))),
        Kf(.7, x + f.r(-20, 20), fl - 40, r: _rad(f.r(-120, 120))),
        Kf(.85, x + f.r(-30, 30), fl, r: _rad(f.r(-160, 160))),
        Kf(1, x + f.r(-30, 30), fl, o: 0),
      ], curve: Curves.easeIn);
    }
  }),
  ScreenEffect('tambora', 'Tambora y güira', '¡Prende el merengue!', 'Dominicanos', artTambora, (f) {
    const w = 150.0, h = 112.0;
    final x = (f.W - w) / 2, y = f.H * .45;
    f.art(artTambora, w, h, 0, 2600, [
      for (var i = 0; i <= 14; i++)
        Kf(i / 14, x, y - (i.isOdd ? 16 : 0), s: i.isOdd ? 1.08 : 1, r: _rad(i % 4 == 1 ? -5 : i % 4 == 3 ? 5 : 0)),
    ]);
    for (var i = 0; i < 10; i++) {
      f.floatText(['♪', '♫', '♬'][i % 3], x + f.r(0, w), y, f.r(-80, 80), -160, i * 220.0);
    }
    f.shout('¡Tan tan tan!', y - 80, size: 28, at: 200);
  }),
  ScreenEffect('diablo', 'Diablo cojuelo', '¡Llegó el carnaval!', 'Dominicanos', artDiablo, (f) {
    const w = 110.0, h = 130.0;
    final y = f.H * .45;
    f.art(artDiablo, w, h, 0, 2800, [
      for (var i = 0; i <= 8; i++) Kf(i / 8, f.W - (f.W + w) * i / 8, y - (i.isOdd ? 60 : 0), r: _rad(i.isOdd ? -10 : 6)),
    ]);
    f.shout('¡Carnaval!', y - 70, size: 32, at: 400, stroke: _blue);
    const cols = [_red, _gold, _sky, _green];
    f.each(0, 2800, 70, (t) => f.puff(f.r(0, f.W), f.r(0, f.H * .4), cols[f.rnd.nextInt(4)], f.r(-30, 30), 80, 10, t, dur: 1200));
  }),
  ScreenEffect('avion', 'Avión KLK', 'Te mando un abrazo ✈️', 'Dominicanos', artAvion, (f) {
    const w = 70.0, h = 50.0;
    final cx = f.W * .5, cy = f.H * .4;
    final ks = <Kf>[];
    for (var i = 0; i <= 40; i++) {
      final t = i / 40;
      if (t < .35) {
        final u = t / .35;
        ks.add(Kf(t, -w + (cx + w) * u, f.H * .7 - (f.H * .7 - cy - 60) * u, r: _rad(-10)));
      } else if (t < .75) {
        final u = (t - .35) / .4 * math.pi * 2;
        ks.add(Kf(t, cx + math.sin(u) * 70, cy - 10 + math.cos(u) * 70, r: -u));
      } else {
        final u = (t - .75) / .25;
        ks.add(Kf(t, cx + (f.W + w - cx) * u, cy + 60 - f.H * .4 * u, r: _rad(-25)));
      }
    }
    final d = f.art(artAvion, w, h, 0, 3000, ks);
    f.each(0, 3000, 60, (t) {
      final k = d.at(t);
      f.puff(k.x + 8, k.y + h * .6, Colors.white, 0, 0, 7, t);
    });
    f.shout('¡Klk!', f.H * .18, size: 40, at: 900);
  }),
  ScreenEffect('corazones', 'Corazones', 'Te quiero mucho ❤️', 'Celebrar', artCorazon, (f) {
    const s = 130.0;
    final x = (f.W - s) / 2, y = (f.H - s) / 2 - 20;
    f.art(artCorazon, s, s * .9, 0, 1500, [
      Kf(0, x, y, s: 0),
      Kf(.3, x, y, s: 1.1),
      Kf(.45, x, y, s: .9),
      Kf(.6, x, y, s: 1.2),
      Kf(.75, x, y, s: .95),
      Kf(1, x, y, s: 1.35),
    ], curve: Curves.easeInOut);
    for (var i = 0; i < 22; i++) {
      final a = i / 22 * math.pi * 2, rr = f.r(90, 190), z = f.r(22, 40);
      final ox = x + s / 2 - z / 2, oy = y + s / 2 - z / 2;
      f.art(artCorazon, z, z * .9, 1500, 1200, [
        Kf(0, ox, oy, s: .3),
        Kf(1, ox + math.cos(a) * rr, oy + math.sin(a) * rr + 40, r: _rad(f.r(-40, 40)), o: 0),
      ], curve: Curves.easeOut);
    }
  }),
  ScreenEffect('gallo', 'El gallo', '¡Buenos días, mi gente!', 'Dominicanos', artGallo, (f) {
    const w = 110.0, h = 120.0;
    final y = f.H - h - 90, x0 = f.W * .45 - w;
    f.art(artGallo, w, h, 0, 1300, [
      for (var i = 0; i <= 6; i++) Kf(i / 6, -w + (f.W * .45) * i / 6, y - (i.isOdd ? 8 : 0), r: _rad(i.isOdd ? -4 : 3)),
    ]);
    f.art(artGallo, w, h, 1300, 1400, [
      Kf(0, x0, y),
      Kf(.3, x0, y - 10, s: 1.12, r: _rad(-12)),
      Kf(.7, x0, y - 10, s: 1.12, r: _rad(-12)),
      Kf(1, x0, y),
    ]);
    f.art(artGallo, w, h, 2700, 900, [Kf(0, x0, y), Kf(1, f.W + 20, y)], curve: Curves.easeIn);
    f.shout('¡KIKIRIKÍ!', y - 60, size: 36, at: 1300);
  }),
  ScreenEffect('jonron', '¡Jonrón!', '¡La sacaste del play!', 'Dominicanos', artPelota, (f) {
    final by = f.H * .62, bx = f.W * .05;
    f.art(artBate, 150, 32, 0, 700, [Kf(0, bx, by, r: _rad(70)), Kf(1, bx, by, r: _rad(70))], origin: Alignment.centerLeft);
    f.art(artBate, 150, 32, 700, 900, [
      Kf(0, bx, by, r: _rad(70)),
      Kf(.4, bx, by, r: _rad(-60)),
      Kf(.8, bx, by, r: _rad(-60)),
      Kf(1, bx, by, r: _rad(-60), o: 0),
    ], curve: Curves.easeOut, origin: Alignment.centerLeft);
    f.art(artPelota, 36, 36, 0, 700, [Kf(0, f.W + 10, by - 30), Kf(1, f.W * .4, by - 6, r: _rad(-300))], curve: Curves.easeIn);
    f.art(artPelota, 36, 36, 700, 1300, [Kf(0, f.W * .4, by - 6), Kf(1, f.W * .85, -60, s: .35, r: _rad(720))],
        curve: const Cubic(.2, .7, .4, 1));
    for (var i = 0; i < 8; i++) {
      f.puff(f.W * .4 + 10, by, _gold, f.r(-50, 50), f.r(-50, 50), 14, 700, dur: 500);
    }
    f.shout('¡JONRÓN!', f.H * .3, size: 40, at: 850);
  }),
  ScreenEffect('fuegos', 'Fuegos artificiales', '¡Felicidades! 🎉', 'Celebrar', artFuegos, (f) {
    const cols = [_red, _gold, _sky, Colors.white, _green];
    for (var b = 0; b < 6; b++) {
      final cx = f.r(50, f.W - 50), cy = f.r(80, f.H * .5), at = b * 380.0;
      f.add(ColoredBox(color: cols[b % 5]), 4, 24, at, 500, [Kf(0, cx, f.H), Kf(1, cx, cy)], curve: Curves.easeOut);
      for (var i = 0; i < 18; i++) {
        final a = i / 18 * math.pi * 2;
        f.puff(cx - 5, cy - 5, cols[(b + i) % 5], math.cos(a) * f.r(60, 100), math.sin(a) * f.r(60, 100) + 20, 10, at + 500,
            dur: 1100);
      }
    }
    f.shout('¡Felicidades!', f.H * .62, size: 32, at: 900, stroke: _navy);
  }),
  ScreenEffect('bandera', 'Bandera dominicana', '¡Orgullo dominicano! 🇩🇴', 'Dominicanos', artBandera, (f) {
    final w = math.min(220.0, f.W * .7), h = w * .66, x = (f.W - w) / 2, y = f.H * .3;
    f.art(artBandera, w, h, 0, 3200, [
      Kf(0, x, y, s: 0),
      for (var i = 1; i <= 10; i++) Kf(i / 10 * .87, x, y, r: _rad(i.isOdd ? 4 : -4)),
      Kf(1, x, y, o: 0),
    ], curve: Curves.easeInOut);
    const cols = [_red, _navy, Colors.white];
    f.each(0, 2800, 45, (t) => f.confetti(f.r(0, f.W), t, cols[f.rnd.nextInt(3)], dur: f.r(1600, 2400)));
    f.shout('¡Quisqueya!', y + h + 24, size: 32, at: 500);
  }),
  ScreenEffect('coco', 'Coco loco', 'Aquí relajao en la playa 🏝️', 'Dominicanos', artCoco, (f) {
    const s = 100.0;
    final y = f.H - s - 100;
    f.art(artCoco, s, s, 0, 3000, [
      Kf(0, -s, y),
      Kf(.45, f.W * .4, y, r: _rad(400)),
      Kf(.6, f.W * .4, y, r: _rad(380)),
      Kf(1, f.W + 20, y, r: _rad(820)),
    ], curve: Curves.easeInOut);
    f.shout('¡Relax!', y - 60, size: 32, at: 700, stroke: _green);
  }),
  ScreenEffect('cangrejo', 'Cangrejito', 'Ando de lado hoy 🦀', 'Dominicanos', artCangrejo, (f) {
    const w = 120.0, h = 84.0;
    final y = f.H - h - 90;
    f.art(artCangrejo, w, h, 0, 3000, [
      for (var i = 0; i <= 20; i++) Kf(i / 20, f.W - (f.W + w) * i / 20, y - (i.isOdd ? 6 : 0), r: _rad(i.isOdd ? 4 : -4)),
    ]);
    f.shout('¡Chiqui chiqui!', y - 58, size: 26, at: 500);
  }),
  ScreenEffect('chichigua', 'Chichigua', '¡Volando alto!', 'Dominicanos', artChichigua, (f) {
    const w = 80.0, h = 130.0;
    f.art(artChichigua, w, h, 0, 3200, [
      for (var i = 0; i <= 10; i++)
        Kf(i / 10, -w + (f.W + w) * i / 10, f.H - (f.H + h) * i / 10 + math.sin(i / 10 * 9) * 30,
            r: _rad(math.sin(i / 10 * 12) * 14)),
    ], curve: Curves.easeInOut);
    f.shout('¡Fiuuuu!', f.H * .3, size: 30, at: 600, stroke: _sky);
  }),
  ScreenEffect('ballena', 'Ballena de Samaná', '¡Saludos desde Samaná! 🐋', 'Dominicanos', artBallena, (f) {
    f.art(artMar, f.W, 90, 0, 3600, [
      Kf(0, 0, f.H),
      Kf(.11, 0, f.H - 90),
      Kf(.89, 0, f.H - 90),
      Kf(1, 0, f.H),
    ], z: 2);
    f.art(artBallena, 190, 130, 400, 1900, [
      Kf(0, f.W * .05, f.H, r: _rad(30)),
      Kf(.45, f.W * .25, f.H * .28, r: _rad(-20)),
      Kf(1, f.W * .45, f.H, r: _rad(-60)),
    ], curve: Curves.easeOut);
    for (var i = 0; i < 16; i++) {
      f.puff(f.W * .55, f.H - 90, const Color(0xFFBFE1FF), f.r(-100, 100), f.r(-180, -80), 16, 2300);
    }
    f.shout('¡SPLASH!', f.H * .2, size: 36, at: 1900, stroke: const Color(0xFF1D6FD6));
  }),
  ScreenEffect('apagon', 'Apagón', 'Se fue la luz otra vez 😩', 'Dominicanos', artVela, (f) {
    const total = 3700.0;
    f.add(const ColoredBox(color: Colors.black), f.W, f.H, 0, total, [
      const Kf(0, 0, 0, o: 0),
      const Kf(250 / total, 0, 0),
      const Kf(3450 / total, 0, 0),
      const Kf(1, 0, 0, o: 0),
    ], z: 5);
    final vx = (f.W - 60) / 2, vy = f.H * .42;
    f.add(
        const DecoratedBox(
            decoration: BoxDecoration(
                gradient: RadialGradient(colors: [Color(0x59FFC531), Color(0x00FFC531)], stops: [0, .65]))),
        240, 240, 250, 3200, [Kf(0, (f.W - 240) / 2, vy - 110), Kf(1, (f.W - 240) / 2, vy - 110)], z: 6);
    f.art(artVela, 60, 110, 250, 3200, [Kf(0, vx, vy), Kf(1, vx, vy)], z: 6);
    f.art(artLlama, 22, 38, 250, 3200, [
      for (var i = 0; i <= 16; i++) Kf(i / 16, vx + 19, vy - 2 - (i.isOdd ? 2 : 0), s: i.isOdd ? .9 : 1.05),
    ], origin: Alignment.bottomCenter, z: 7);
    f.shout('Se fue la luz…', vy + 130, size: 28, at: 450, stroke: const Color(0xFF333333));
    f.shout('¡LLEGÓ LA LUZ!', f.H * .3, size: 34, at: 3450);
  }),
  ScreenEffect('domino', 'Dominó', '¡Capicúa, papá!', 'Dominicanos', artDomino, (f) {
    const n = 7;
    final s = math.min(36.0, (f.W - 40) / n * .8), gap = (f.W - 40) / n, y = f.H * .5;
    final end = 800 + n * 150 + 1700.0;
    for (var i = 0; i < n; i++) {
      final x = 20 + i * gap, fall = 800 + i * 150.0;
      f.artMs(artDomino, s, s * 2, [
        (i * 60.0, Kf(0, x, y - 200, o: 0)),
        (i * 60.0 + 300, Kf(0, x, y)),
        (fall, Kf(0, x, y)),
        (fall + 260, Kf(0, x, y, r: _rad(78))),
        (end, Kf(0, x, y, r: _rad(78))),
      ], origin: Alignment.bottomRight);
    }
    f.shout('¡CAPICÚA!', y - 110, size: 40, at: n * 150 + 1000.0);
  }),
  ScreenEffect('chancleta', 'La chancleta', '¡Ven acá ahora mismo!', 'Dominicanos', artChancleta, (f) {
    f.shout('¡VEN ACÁ!', f.H * .22, size: 36);
    const w = 110.0, h = 56.0;
    final y = f.H * .5;
    f.art(artChancleta, w, h, 0, 1500, [
      Kf(0, f.W, y - 40),
      Kf(.5, f.W * .3, y - 100, r: _rad(-540)),
      Kf(1, -w - 20, y + 20, r: _rad(-1080)),
    ], curve: Curves.easeIn);
    f.shout('¡Ay!', y, size: 34, at: 1500, stroke: _blue, x: 30);
  }),
  ScreenEffect('cohete', 'Tamo activo', '¡Tamo activo! 🚀', 'Celebrar', artCohete, (f) {
    const w = 70.0, h = 130.0;
    final x = (f.W - w) / 2, top = f.H - h - 40;
    final steps = <(double, Kf)>[
      (0, Kf(0, x, f.H)),
      (500, Kf(0, x, top)),
      for (var i = 1; i <= 8; i++) (500 + i * 62.5, Kf(0, x + (i.isOdd ? 3 : -3), top)),
      (1000, Kf(0, x, top)),
      (2300, Kf(0, x, -h - 80)),
    ];
    final d = f.artMs(artCohete, w, h, steps);
    f.artMs(artLlama, 30, 52, [for (final (t, k) in steps) (t, Kf(0, k.x + 20, k.y + h - 6))], z: 2);
    f.each(1000, 2300, 50, (t) {
      final k = d.at(t);
      f.puff(k.x + w / 2 - 14, k.y + h, const Color(0xE6E6EBF5), f.r(-40, 40), 60, 28, t, dur: 1000);
    });
    f.shout('¡TAMO ACTIVO!', f.H * .45, size: 34, at: 1200);
  }),

  // ---------------- Navidad y Reyes ----------------
  ScreenEffect('santa', 'Santa Claus', '¡Jo jo jo! Feliz Navidad 🎅', 'Navidad y Reyes', artSanta, (f) {
    const w = 220.0, h = 99.0;
    final d = f.art(artSanta, w, h, 0, 3400, [
      for (var i = 0; i <= 12; i++)
        Kf(i / 12, -w + (f.W + w * 2) * i / 12, f.H * .28 - i * 4 + math.sin(i / 12 * math.pi * 3) * 24,
            r: _rad(math.cos(i / 12 * math.pi * 3) * -6)),
    ], curve: Curves.easeInOut);
    f.each(0, 3400, 70, (t) {
      final k = d.at(t);
      f.puff(k.x + 10, k.y + h * .7, _gold, f.r(-20, 0), f.r(0, 20), 8, t, dur: 900);
    });
    for (var i = 0; i < 3; i++) {
      final at = 900 + i * 600.0, k = d.at(at), x = k.x + 40;
      f.art(artRegalo, 34, 34, at, 1300, [Kf(0, x, k.y + 50), Kf(1, x - 20, f.H + 20, r: _rad(f.r(-200, 200)))],
          curve: Curves.easeIn);
    }
    f.shout('¡JO JO JO!', f.H * .55, size: 36, at: 1000, stroke: const Color(0xFFC8102E));
  }),
  ScreenEffect('nieve', 'Nieve', '¡Feliz Navidad! ❄️', 'Navidad y Reyes', artCopo, (f) {
    for (var i = 0; i < 42; i++) {
      final s = f.r(12, 28), x = f.r(-10, f.W), at = f.r(0, 2200), sway = f.r(20, 50);
      f.art(artCopo, s, s, at, f.r(2400, 3400), [
        for (var k = 0; k <= 6; k++)
          Kf(k / 6, x + math.sin(k / 6 * math.pi * 2) * sway, -30 + (f.H + 60) * k / 6, r: _rad(k * 40.0), o: k == 6 ? 0 : 1),
      ], z: 2);
    }
    f.shout('¡Feliz Navidad!', f.H * .38, size: 34, at: 700, stroke: const Color(0xFF1F8F4E));
  }),
  ScreenEffect('arbolito', 'Arbolito', '¡Ya llegó la Navidad! 🎄', 'Navidad y Reyes', artArbol, (f) {
    const w = 160.0, h = 208.0;
    final x = (f.W - w) / 2, y = f.H * .62 - h;
    f.art(artArbol, w, h, 0, 3600, [
      Kf(0, x, y, s: 0),
      Kf(.18, x, y, s: 1.08),
      Kf(.25, x, y),
      Kf(.9, x, y),
      Kf(1, x, y, o: 0),
    ], origin: Alignment.bottomCenter, curve: Curves.easeOut);
    f.art(artEstrella, 50, 50, 700, 2900, [
      Kf(0, x + w / 2 - 25, y - 30, s: 0, r: _rad(-180)),
      Kf(.15, x + w / 2 - 25, y - 30, s: 1.3),
      Kf(.25, x + w / 2 - 25, y - 30),
      Kf(.6, x + w / 2 - 25, y - 30, s: 1.12),
      Kf(.9, x + w / 2 - 25, y - 30),
      Kf(1, x + w / 2 - 25, y - 30, o: 0),
    ]);
    const cols = [_red, _gold, _sky, Colors.white];
    f.each(800, 3200, 120, (t) {
      final u = f.r(.15, .95);
      f.puff(x + w / 2 + f.r(-w / 2, w / 2) * u - 5, y + h * u * .78, cols[f.rnd.nextInt(4)], 0, 0, 10, t, dur: 700);
    });
    f.shout('¡Feliz Navidad!', y + h + 20, size: 32, at: 900, stroke: const Color(0xFF1F8F4E));
  }),
  ScreenEffect('regalo', 'Regalo sorpresa', '¡Te tengo un regalito! 🎁', 'Navidad y Reyes', artRegalo, (f) {
    const w = 130.0, h = 104.0;
    final x = (f.W - w) / 2, y = f.H * .45;
    f.art(artRegaloCaja, w, h, 0, 3200, [
      Kf(0, x, -h),
      Kf(.18, x, y),
      for (var i = 1; i <= 6; i++) Kf(.18 + i * .05, x, y - (i.isOdd ? 8 : 0), r: _rad(i.isOdd ? -4 : 4)),
      Kf(.5, x, y),
      Kf(.9, x, y),
      Kf(1, x, y, o: 0),
    ], origin: Alignment.bottomCenter, curve: Curves.easeOut);
    const lw = 143.0, lh = 65.0;
    final lx = x - 6.5, ly = y - lh + 18;
    f.artMs(artRegaloTapa, lw, lh, [
      (0, Kf(0, lx, -h - lh + 18)),
      (580, Kf(0, lx, ly)),
      (1600, Kf(0, lx, ly)),
      (2600, Kf(0, lx + 120, -lh - 80, r: _rad(160))),
    ]);
    const cols = [_red, _gold, _sky, _green, Colors.white];
    for (var i = 0; i < 26; i++) {
      final a = -math.pi * f.r(.1, .9);
      f.puff(f.W / 2 - 6, y, cols[i % 5], math.cos(a) * f.r(60, 150), math.sin(a) * f.r(120, 220), 12, 1650, dur: 1200);
    }
    f.art(artCorazon, 60, 54, 1650, 1300, [Kf(0, f.W / 2 - 30, y, s: .2), Kf(1, f.W / 2 - 30, y - 170, s: 1.3, o: 0)],
        curve: Curves.easeOut);
    f.shout('¡SORPRESA!', f.H * .2, size: 38, at: 1650);
  }),
  ScreenEffect('reyes', 'Reyes Magos', '¡Llegaron los Reyes! 👑', 'Navidad y Reyes', artRey1, (f) {
    const w = 120.0, h = 112.0;
    final y = f.H * .6 - h;
    final arts = [artRey1, artRey2, artRey3];
    for (var i = 0; i < 3; i++) {
      final at = i * 450.0;
      f.art(arts[i], w, h, at, 3800, [
        for (var k = 0; k <= 16; k++) Kf(k / 16, -w - 10 + (f.W + w * 1.3) * k / 16, y - (k.isOdd ? 6 : 0) + i * 14,
            r: _rad(k.isOdd ? -2 : 2)),
      ], z: 3 + i);
    }
    f.art(artEstrella, 54, 54, 0, 4700, [
      Kf(0, f.W * .75, f.H * .1, s: 0),
      Kf(.1, f.W * .75, f.H * .1, s: 1.2),
      for (var i = 1; i <= 8; i++) Kf(.1 + i * .1, f.W * .75 - i * 6, f.H * .1, s: i.isOdd ? .9 : 1.1, r: _rad(i * 12.0)),
      Kf(1, f.W * .6, f.H * .1, o: 0),
    ]);
    f.each(200, 4400, 140, (t) => f.puff(f.W * .75 + f.r(-30, 50), f.H * .1 + f.r(10, 60), _gold, f.r(-20, 20), 30, 7, t));
    f.shout('¡Llegaron los Reyes!', f.H * .66, size: 28, at: 1300, stroke: _purple);
  }),

  // ---------------- Halloween ----------------
  ScreenEffect('calabaza', 'Calabaza', '¡Feliz Halloween! 🎃', 'Halloween', artCalabaza, (f) {
    const w = 120.0, h = 110.0;
    final y = f.H - h - 100;
    f.art(artCalabaza, w, h, 0, 3000, [
      for (var i = 0; i <= 8; i++)
        Kf(i / 8, -w + (f.W + w * 2) * i / 8, y - (i.isOdd ? 90 : 0), s: i.isOdd ? 1 : 1.05, r: _rad(i * 45.0)),
    ]);
    f.shout('¡BUUU!', f.H * .3, size: 42, at: 700, stroke: _orange);
  }),
  ScreenEffect('fantasma', 'Fantasma', 'Buuu… ¿te asusté? 👻', 'Halloween', artFantasma, (f) {
    const w = 120.0, h = 144.0;
    final x = (f.W - w) / 2, y = f.H * .32;
    f.art(artFantasma, w, h, 0, 3400, [
      Kf(0, f.W * .1, f.H, s: .5, o: 0),
      Kf(.2, f.W * .05, y + 40, s: .8, o: .7),
      Kf(.35, f.W * .55, y, s: .9, o: .8),
      Kf(.5, x, y - 20, s: 1.5),
      Kf(.6, x, y - 10, s: 1.4),
      Kf(.75, x, y - 20, s: 1.5, o: .9),
      Kf(.82, x, y - 20, s: 1.5, o: .3),
      Kf(.88, x, y - 20, s: 1.5, o: .9),
      Kf(1, x, y - 120, s: .6, o: 0),
    ], curve: Curves.easeInOut);
    f.shout('¡BUUU!', y + h + 30, size: 44, at: 1600, stroke: _purple);
  }),
  ScreenEffect('murcielagos', 'Murciélagos', '¡Qué miedo! 🦇', 'Halloween', artMurcielago, (f) {
    for (var i = 0; i < 11; i++) {
      final s = f.r(56, 96), y0 = f.r(20, f.H * .7), at = i * 160.0, wave = f.r(20, 60);
      f.art(artMurcielago, s, s / 2, at, f.r(1700, 2300), [
        for (var k = 0; k <= 14; k++)
          Kf(k / 14, f.W + 20 - (f.W + s + 40) * k / 14, y0 + math.sin(k / 14 * math.pi * 3) * wave, s: k.isOdd ? .7 : 1),
      ]);
    }
    f.shout('¡Qué miedo!', f.H * .42, size: 34, at: 900, stroke: _purple);
  }),
  ScreenEffect('bruja', 'Bruja voladora', '¡Je je je! 🧹', 'Halloween', artBruja, (f) {
    final m = math.min(150.0, f.W * .42);
    f.art(artLuna, m, m, 0, 3600, [
      Kf(0, f.W - m - 20, 60, s: 0),
      Kf(.12, f.W - m - 20, 60, s: 1),
      Kf(.88, f.W - m - 20, 60, s: 1),
      Kf(1, f.W - m - 20, 60, s: 1, o: 0),
    ], z: 2);
    const w = 170.0, h = 117.0;
    final d = f.art(artBruja, w, h, 500, 2600, [
      for (var i = 0; i <= 10; i++)
        Kf(i / 10, -w + (f.W + w * 2) * i / 10, 60 + m * .5 - h / 2 + math.sin(i / 10 * math.pi * 2) * 30, r: _rad(-6)),
    ], curve: Curves.easeInOut);
    f.each(500, 3100, 60, (t) {
      final k = d.at(t);
      f.puff(k.x + 6, k.y + h * .7, const Color(0xFFB388FF), f.r(-20, 0), f.r(-6, 12), 9, t);
    });
    f.shout('¡Je je je!', f.H * .55, size: 36, at: 1100, stroke: _purple);
  }),

  // ---------------- Celebrar ----------------
  ScreenEffect('pastel', 'Cumpleaños', '¡Feliz cumpleaños! 🎂', 'Celebrar', artPastel, (f) {
    const w = 170.0, h = 170.0;
    final x = (f.W - w) / 2, y = f.H * .62 - h;
    f.art(artPastel, w, h, 0, 3800, [
      Kf(0, x, f.H),
      Kf(.15, x, y - 10),
      Kf(.2, x, y),
      Kf(.9, x, y),
      Kf(1, x, y, o: 0),
    ], curve: Curves.easeOut);
    final k = w / 120;
    for (final cx in [39.5, 60.5, 81.5]) {
      final top = cx == 60.5 ? 12.0 : 16.0;
      f.art(artLlama, 12 * k, 21 * k, 700, 3100, [
        for (var i = 0; i <= 14; i++)
          Kf(i / 14, x + cx * k - 6 * k, y + top * k - 20 * k, s: i.isOdd ? .85 : 1.05, o: i == 14 ? 0 : 1),
      ], origin: Alignment.bottomCenter, z: 4);
    }
    const cols = [_red, _gold, _sky, _green, Colors.white];
    f.each(900, 3200, 40, (t) => f.confetti(f.r(0, f.W), t, cols[f.rnd.nextInt(5)], dur: f.r(1600, 2400)));
    f.shout('¡Feliz cumpleaños!', f.H * .18, size: 32, at: 900);
  }),
];

/// Pide reproducir un efecto en un chat.
class FxPlay {
  final String chatId, id;
  final int nonce;
  const FxPlay(this.chatId, this.id, this.nonce);
}

/// Canal para pedir efectos (desde el controlador o al tocar ✨ en un mensaje).
final fxBus = ValueNotifier<FxPlay?>(null);
int _fxNonce = 0;
void playScreenEffect(String chatId, String id) {
  if (effectById(id) == null) return;
  fxBus.value = FxPlay(chatId, id, ++_fxNonce);
}

/// Capa que dibuja los efectos encima del chat (no bloquea los toques).
class ScreenEffectLayer extends StatefulWidget {
  final String chatId;
  const ScreenEffectLayer({super.key, required this.chatId});
  @override
  State<ScreenEffectLayer> createState() => _ScreenEffectLayerState();
}

class _ScreenEffectLayerState extends State<ScreenEffectLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  String? _id;
  Size? _size;
  List<Track> _tracks = const [];

  @override
  void initState() {
    super.initState();
    fxBus.addListener(_onBus);
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _tracks = const []);
    });
  }

  void _onBus() {
    final p = fxBus.value;
    if (p == null || p.chatId != widget.chatId || !mounted) return;
    _id = p.id;
    _start();
  }

  void _start() {
    final e = effectById(_id), size = _size;
    if (e == null || size == null || size.isEmpty) return;
    final fx = Fx(size, math.Random());
    e.build(fx);
    fx.tracks.sort((a, b) => a.z.compareTo(b.z));
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    setState(() => _tracks = fx.tracks);
    _c.duration = Duration(milliseconds: (fx.total * (reduce ? 1.0 : 1.0)).round());
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    fxBus.removeListener(_onBus);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, box) {
        _size = box.biggest;
        if (_tracks.isEmpty) return const SizedBox.expand();
        return ClipRect(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final ms = _c.value * (_c.duration?.inMilliseconds ?? 0);
              return Stack(clipBehavior: Clip.hardEdge, children: [
                for (final t in _tracks)
                  if (ms >= t.start && ms <= t.end) _place(t, t.at(ms)),
              ]);
            },
          ),
        );
      }),
    );
  }

  Widget _place(Track t, Kf k) => Positioned(
        left: k.x,
        top: k.y,
        width: t.w,
        height: t.h,
        child: Opacity(
          opacity: k.o.clamp(0.0, 1.0),
          child: Transform(
            alignment: t.origin,
            transform: Matrix4.identity()
              ..rotateZ(k.r)
              ..scaleByDouble(k.s, k.s, 1, 1),
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: SizedBox(width: t.w, height: t.h, child: t.child),
            ),
          ),
        ),
      );
}

/// Hoja para elegir el efecto (se abre manteniendo pulsado «Enviar» o con ✨).
Future<String?> pickScreenEffect(BuildContext context) => showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .72,
        maxChildSize: .95,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const Text('Enviar con efecto',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('El dibujo cruza la pantalla de los dos al enviar el mensaje.',
                style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            for (final g in fxGroups) ...[
              Padding(
                padding: const EdgeInsets.only(top: 18, bottom: 8),
                child: Text(g, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: .86,
                children: [
                  for (final e in screenEffects)
                    if (e.group == g) _EffectTile(e, onTap: () => Navigator.pop(ctx, e.id)),
                ],
              ),
            ],
          ],
        ),
      ),
    );

class _EffectTile extends StatelessWidget {
  final ScreenEffect e;
  final VoidCallback onTap;
  const _EffectTile(this.e, {required this.onTap});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF13295C), Color(0xFF0B1730)]),
                ),
                padding: const EdgeInsets.all(8),
                child: SvgPicture.string(e.thumb, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 6),
            Text(e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}
