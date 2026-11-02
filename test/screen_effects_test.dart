import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klk/features/effects/screen_effects.dart';

void main() {
  test('los efectos tienen ids únicos y grupo conocido', () {
    final ids = screenEffects.map((e) => e.id).toSet();
    expect(ids.length, screenEffects.length);
    expect(screenEffects.length, greaterThanOrEqualTo(30));
    for (final e in screenEffects) {
      expect(fxGroups, contains(e.group), reason: e.id);
      expect(effectById(e.id), same(e));
    }
    expect(effectById('no-existe'), isNull);
  });

  test('cada efecto se construye en móviles grandes y pequeños', () {
    for (final size in const [Size(390, 640), Size(320, 480), Size(800, 900)]) {
      for (final e in screenEffects) {
        final fx = Fx(size, math.Random(7));
        e.build(fx);
        expect(fx.tracks, isNotEmpty, reason: e.id);
        expect(fx.total, inInclusiveRange(1000, 8000), reason: e.id);
        for (final t in fx.tracks) {
          expect(t.kf, isNotEmpty, reason: e.id);
          expect(t.dur, greaterThan(0), reason: e.id);
          for (final ms in [t.start, t.start + t.dur / 2, t.end]) {
            final k = t.at(ms);
            for (final v in [k.x, k.y, k.r, k.s, k.o]) {
              expect(v.isFinite, isTrue, reason: '${e.id} @ $ms');
            }
          }
        }
      }
    }
  });

  testWidgets('la capa dibuja cada efecto sin errores', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: SizedBox(width: 390, height: 700, child: ScreenEffectLayer(chatId: 'c'))),
    ));
    for (final e in screenEffects) {
      playScreenEffect('c', e.id);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(seconds: 6));
      expect(tester.takeException(), isNull, reason: e.id);
    }
  });
}
