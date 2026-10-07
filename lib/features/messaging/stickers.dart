/// Stickers criollos incluidos en KLK (assets/stickers/<id>.png).
/// Viajan solo por su id: ambos móviles ya tienen las imágenes.
/// Los packs nuevos se generan con tool/make_stickers.py.
class KlkSticker {
  final String id;
  final String label;
  const KlkSticker(this.id, this.label);

  String get asset => 'assets/stickers/$id.png';
}

class StickerPack {
  final String name;
  final String icon; // emoji de la pestaña
  final List<KlkSticker> stickers;
  const StickerPack(this.name, this.icon, this.stickers);
}

const stickerPacks = [
  StickerPack('Criollos', '🇩🇴', [
    KlkSticker('klk', '¡Klk!'),
    KlkSticker('tato', "Tá to'"),
    KlkSticker('dimelo', 'Dímelo'),
    KlkSticker('aymimadre', 'Ay mi madre'),
    KlkSticker('quelloque', '¡Qué lo que!'),
    KlkSticker('diache', '¡Diache!'),
    KlkSticker('vamoarriba', "Vamo' arriba"),
    KlkSticker('tranquilo', 'Tranquilo'),
    KlkSticker('jajaja', '¡Jajajá!'),
    KlkSticker('bendicion', 'Bendición'),
    KlkSticker('tamoactivo', "Tamo' activo"),
    KlkSticker('tabuenoya', "Ta' bueno ya"),
  ]),
  StickerPack('Pelota', '⚾', [
    KlkSticker('jonron', '¡Jonrón!'),
    KlkSticker('ponchao', '¡Ponchao!'),
    KlkSticker('safe', '¡Safe!'),
    KlkSticker('pelota', "Vamo' a la pelota"),
  ]),
  StickerPack('Navidad', '🎄', [
    KlkSticker('navidad', '¡Feliz Navidad!'),
    KlkSticker('aguinaldo', '¡Aguinaldo!'),
    KlkSticker('nochebuena', '¡Nochebuena!'),
    KlkSticker('anonuevo', '¡Feliz Año Nuevo!'),
  ]),
  StickerPack('Carnaval', '🎭', [
    KlkSticker('carnaval', '¡Carnaval!'),
    KlkSticker('cojuelo', 'Diablo cojuelo'),
    KlkSticker('vejigazo', '¡Vejigazo!'),
    KlkSticker('comparsa', '¡A la comparsa!'),
  ]),
  StickerPack('Merengue', '🎶', [
    KlkSticker('merengue', '¡Merengue!'),
    KlkSticker('abailar', '¡A bailar!'),
    KlkSticker('guiratambora', 'Güira y tambora'),
    KlkSticker('perico', 'Perico ripiao'),
  ]),
  StickerPack('Cumpleaños', '🎂', [
    KlkSticker('feliz_cumple', '¡Feliz cumple!'),
    KlkSticker('muchos_mas', '¡Que cumplas muchos más!'),
    KlkSticker('bizcocho', "¡Bizcocho pa' ti!"),
    KlkSticker('felicidades', '¡Felicidades!'),
  ]),
];

/// Todos los stickers, en orden.
final klkStickers = [for (final p in stickerPacks) ...p.stickers];

String stickerAsset(String? id) =>
    'assets/stickers/${klkStickers.any((s) => s.id == id) ? id : 'klk'}.png';
