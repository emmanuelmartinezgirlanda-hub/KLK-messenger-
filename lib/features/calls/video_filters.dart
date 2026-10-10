import 'package:flutter/widgets.dart';

/// Filtros de color para las videollamadas.
///
/// El filtro que eliges se aplica a tu cámara en tu pantalla y se le comunica
/// al otro móvil (por la señalización cifrada) para que vea tu vídeo con el mismo filtro.
class VideoFilter {
  final String name;
  final List<double>? matrix; // null = sin filtro
  const VideoFilter(this.name, this.matrix);
}

const videoFilters = <VideoFilter>[
  VideoFilter('Normal', null),
  VideoFilter('Blanco y negro', [
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]),
  VideoFilter('Sepia', [
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0,
    0.272, 0.534, 0.131, 0, 0,
    0, 0, 0, 1, 0,
  ]),
  VideoFilter('Cálido', [
    1.12, 0, 0, 0, 8, //
    0, 1.02, 0, 0, 4,
    0, 0, 0.86, 0, 0,
    0, 0, 0, 1, 0,
  ]),
  VideoFilter('Frío', [
    0.88, 0, 0, 0, 0, //
    0, 1.0, 0, 0, 4,
    0, 0, 1.15, 0, 10,
    0, 0, 0, 1, 0,
  ]),
  VideoFilter('Vívido', [
    1.35, -0.18, -0.17, 0, 0, //
    -0.15, 1.33, -0.18, 0, 0,
    -0.15, -0.18, 1.33, 0, 0,
    0, 0, 0, 1, 0,
  ]),
  VideoFilter('Atardecer', [
    1.1, 0.1, 0, 0, 20, //
    0, 0.95, 0.05, 0, 0,
    0, 0, 0.7, 0, -10,
    0, 0, 0, 1, 0,
  ]),
  VideoFilter('Brillo', [
    1.1, 0, 0, 0, 22, //
    0, 1.1, 0, 0, 22,
    0, 0, 1.1, 0, 22,
    0, 0, 0, 1, 0,
  ]),
];

/// Envuelve un vídeo con el filtro indicado (índice de [videoFilters]).
Widget withVideoFilter(int index, Widget child) {
  if (index <= 0 || index >= videoFilters.length) return child;
  final m = videoFilters[index].matrix;
  if (m == null) return child;
  return ColorFiltered(colorFilter: ColorFilter.matrix(m), child: child);
}
