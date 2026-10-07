/// Stickers criollos incluidos en KLK (assets/stickers/<id>.png).
/// Viajan solo por su id: ambos móviles ya tienen las imágenes.
class KlkSticker {
  final String id;
  final String label;
  const KlkSticker(this.id, this.label);

  String get asset => 'assets/stickers/$id.png';
}

const klkStickers = [
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
];

String stickerAsset(String? id) =>
    'assets/stickers/${klkStickers.any((s) => s.id == id) ? id : 'klk'}.png';
