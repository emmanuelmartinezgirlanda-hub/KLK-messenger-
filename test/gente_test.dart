import 'package:flutter_test/flutter_test.dart';
import 'package:klk/features/gente/gente.dart';

void main() {
  test('publicación: se lee del servidor y limpia lo raro', () {
    final p = GentePost.tryParse({
      'id': 'p1',
      'author': {'id': 'a1', 'name': ' Ana ', 'photo': 'f1'},
      'country': 'DO',
      'text': '¡Klk!',
      'photos': ['x1', 2, '', 'x2', 'x3', 'x4', 'x5'],
      'createdAt': '2026-10-25T20:00:00Z',
      'likes': 3,
      'comments': 1,
      'liked': true,
    })!;
    expect(p.author.displayName, 'Ana');
    expect(p.photos, ['x1', 'x2']); // solo las 4 primeras posiciones y que sean texto
    expect(p.liked, isTrue);
    expect(p.copyWith(likes: 4, liked: false).likes, 4);
    expect(GentePost.tryParse({'id': 'x'}), isNull);
    expect(const GenteAuthor(id: 'z').displayName, 'Alguien de KLK');
  });

  test('hace cuánto', () {
    final now = DateTime(2026, 10, 25, 21);
    expect(genteAgo(now.subtract(const Duration(seconds: 20)), now: now), 'ahora');
    expect(genteAgo(now.subtract(const Duration(minutes: 5)), now: now), 'hace 5 min');
    expect(genteAgo(now.subtract(const Duration(hours: 3)), now: now), 'hace 3 h');
    expect(genteAgo(now.subtract(const Duration(days: 1, hours: 1)), now: now), 'ayer');
    expect(genteAgo(DateTime(2026, 10, 2), now: now), '2 oct');
    expect(genteAgo(DateTime(2025, 3, 9), now: now), '9 mar 2025');
  });

  test('banderas', () {
    expect(flagOf('DO'), '🇩🇴');
    expect(flagOf('ie'), '🇮🇪');
    expect(flagOf(''), '');
  });
}
