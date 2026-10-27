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

  test('ventas: precio escrito a mano y cómo se enseña', () {
    expect(parseSalePrice('1500'), 1500);
    expect(parseSalePrice('1.500'), 1500);
    expect(parseSalePrice('1,500'), 1500);
    expect(parseSalePrice('12,50'), 12.5);
    expect(parseSalePrice('12.5'), 12.5);
    expect(parseSalePrice('1.250.000'), 1250000);
    expect(parseSalePrice(''), isNull);
    expect(parseSalePrice('0'), isNull);
    expect(parseSalePrice('99999999'), isNull);
    expect(saleMoney(1500, 'RD\$'), 'RD\$ 1.500');
    expect(saleMoney(12.5, '€'), '12,50 €');
    expect(saleMoney(120, 'US\$'), 'US\$ 120');
    final p = GentePost.tryParse({
      'id': 'v1',
      'author': {'id': 'a'},
      'text': 'Vendo bici',
      'createdAt': '2026-10-27T09:00:00Z',
      'sale': true,
      'price': 120,
      'currency': '€',
    })!;
    expect(p.sale, isTrue);
    expect(p.priceLabel, '120 €');
    expect(p.copyWith(sold: true).sold, isTrue);
    expect(saleCurrencyFor('IE'), '€');
    expect(saleCurrencyFor('DO'), 'RD\$');
  });
}
