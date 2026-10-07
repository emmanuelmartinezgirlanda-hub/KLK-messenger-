import 'package:flutter/material.dart';

/// Identidad de marca de KLK.
/// Paleta inspirada en la bandera dominicana y el Caribe.
abstract final class KlkBrand {
  static const String name = 'KLK';
  static const String fullName = 'KLK messenger'; // nombre de la app en el móvil
  static const String slogan = 'Tu gente, donde tú estés.';
  static const String greeting = '¿Klk, mi gente?';

  // Colores base
  static const Color azulQuisqueya = Color(0xFF002D62); // azul bandera
  static const Color rojoPatria = Color(0xFFCE1126); // rojo bandera
  static const Color blancoPaz = Color(0xFFFFFFFF);
  static const Color mar = Color(0xFF00A6B4); // turquesa caribeño
  static const Color sol = Color(0xFFFFB627); // amarillo atardecer
  static const Color noche = Color(0xFF0B1320); // fondo modo oscuro
}
