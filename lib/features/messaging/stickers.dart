/// Stickers criollos incluidos en KLK (assets/stickers/<id>.png).
/// Viajan solo por su id: ambos móviles ya tienen las imágenes.
/// Las imágenes se generan con tool/make_stickers.py (la lista tiene que coincidir).
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
    KlkSticker('quelloque', '¡Qué lo que!'),
    KlkSticker('dimelo', 'Dímelo'),
    KlkSticker('tato', 'Tá to\''),
    KlkSticker('tamoactivo', 'Tamo\' activo'),
    KlkSticker('vamoarriba', 'Vamo\' arriba'),
    KlkSticker('tabuenoya', 'Ta\' bueno ya'),
    KlkSticker('diache', '¡Diache!'),
    KlkSticker('aymimadre', 'Ay mi madre'),
    KlkSticker('jajaja', '¡Jajajá!'),
    KlkSticker('tranquilo', 'Tranquilo'),
    KlkSticker('bendicion', 'Bendición'),
    KlkSticker('ombe', '¡Ombe!'),
    KlkSticker('wepa', '¡Wepa!'),
    KlkSticker('concho', '¡Concho!'),
    KlkSticker('eseasi', 'Eso e\' así'),
    KlkSticker('tutaloco', '¿Tú \'tá loco?'),
    KlkSticker('suave', '¡Suave!'),
    KlkSticker('ahorita', 'Ahorita'),
    KlkSticker('quevaina', '¡Qué vaina!'),
    KlkSticker('nio', '¡Ño!'),
    KlkSticker('palante', '¡Pa\' lante!'),
    KlkSticker('dale', '¡Dale!'),
    KlkSticker('mipana', 'Mi pana'),
    KlkSticker('tiguere', 'Tremendo tíguere'),
    KlkSticker('unchin', 'Un chin'),
    KlkSticker('quejevi', '¡Qué jevi!'),
    KlkSticker('tabrutal', '¡Tá brutal!'),
    KlkSticker('quechevere', '¡Qué chévere!'),
    KlkSticker('mevoamori', 'Me vo\' a morí'),
    KlkSticker('toyready', 'Toy ready'),
    KlkSticker('quillao', 'Toy quillao'),
    KlkSticker('arrancao', 'Toy arrancao'),
    KlkSticker('enolla', 'Toy en olla'),
    KlkSticker('asandobatata', 'Me cogiste asando batata'),
    KlkSticker('nipalla', 'Ni pa\'llá voy'),
    KlkSticker('jabladera', 'Deja la jabladera'),
    KlkSticker('bochinche', '¡Qué bochinche!'),
    KlkSticker('diosbendiga', 'Dios te bendiga'),
    KlkSticker('mamaben', 'Mamá, la bendición'),
  ]),
  StickerPack('Amor', '❤️', [
    KlkSticker('tequiero', 'Te quiero un montón'),
    KlkSticker('miamor', 'Mi amor'),
    KlkSticker('mivida', 'Mi vida'),
    KlkSticker('mireina', 'Mi reina'),
    KlkSticker('mirey', 'Mi rey'),
    KlkSticker('besito', 'Un besito'),
    KlkSticker('teextrano', 'Te extraño'),
    KlkSticker('quelindo', '¡Qué lindo!'),
  ]),
  StickerPack('Comida', '🍛', [
    KlkSticker('mangu', '¡Mangú!'),
    KlkSticker('tresgolpes', 'Los tres golpes'),
    KlkSticker('sancocho', 'Sancocho'),
    KlkSticker('habichuela', 'Habichuela con dulce'),
    KlkSticker('cafecito', 'Un cafecito'),
    KlkSticker('morirsonando', 'Morir soñando'),
    KlkSticker('unafria', 'Una fría'),
    KlkSticker('jambre', 'Tengo un jambre'),
    KlkSticker('jartura', '¡Qué jartura!'),
    KlkSticker('querico', '¡Qué rico!'),
  ]),
  StickerPack('Día a día', '💡', [
    KlkSticker('apagon', '¡Se fue la luz!'),
    KlkSticker('llegoluz', '¡Llegó la luz!'),
    KlkSticker('quecalor', '¡Qué calor!'),
    KlkSticker('playa', '¡Pa\' la playa!'),
    KlkSticker('janguear', 'Vamo\' a janguear'),
    KlkSticker('vengo', 'Voy en camino'),
    KlkSticker('orgullo', 'Orgullo dominicano'),
  ]),
  StickerPack('Pelota', '⚾', [
    KlkSticker('jonron', '¡Jonrón!'),
    KlkSticker('ponchao', '¡Ponchao!'),
    KlkSticker('safe', '¡Safe!'),
    KlkSticker('pelota', 'Vamo\' a la pelota'),
    KlkSticker('pafuera', '¡Pa\' fuera!'),
    KlkSticker('playball', '¡Play ball!'),
  ]),
  StickerPack('Música', '🎶', [
    KlkSticker('merengue', '¡Merengue!'),
    KlkSticker('abailar', '¡A bailar!'),
    KlkSticker('guiratambora', 'Güira y tambora'),
    KlkSticker('perico', 'Perico ripiao'),
    KlkSticker('bachata', '¡Bachata!'),
    KlkSticker('dembow', '¡Dembow!'),
  ]),
  StickerPack('Navidad', '🎄', [
    KlkSticker('navidad', '¡Feliz Navidad!'),
    KlkSticker('aguinaldo', '¡Aguinaldo!'),
    KlkSticker('nochebuena', '¡Noche buena!'),
    KlkSticker('anonuevo', '¡Feliz Año Nuevo!'),
  ]),
  StickerPack('Carnaval', '🎭', [
    KlkSticker('carnaval', '¡Carnaval!'),
    KlkSticker('cojuelo', 'Diablo cojuelo'),
    KlkSticker('vejigazo', '¡Vejigazo!'),
    KlkSticker('comparsa', '¡A la comparsa!'),
  ]),
  StickerPack('Cumpleaños', '🎂', [
    KlkSticker('feliz_cumple', '¡Feliz cumple!'),
    KlkSticker('muchos_mas', '¡Que cumplas muchos más!'),
    KlkSticker('bizcocho', '¡Bizcocho pa\' ti!'),
    KlkSticker('felicidades', '¡Felicidades!'),
  ]),
];

/// Todos los stickers, en orden.
final klkStickers = [for (final p in stickerPacks) ...p.stickers];

String stickerAsset(String? id) =>
    'assets/stickers/${klkStickers.any((s) => s.id == id) ? id : 'klk'}.png';
