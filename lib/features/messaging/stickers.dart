// Sin KLK Plus (App Store) no se nombra Plus en ningún sitio.
const bool _kPlus = bool.fromEnvironment('KLK_PLUS');

/// Stickers criollos incluidos en KLK (assets/stickers/<id>.png).
/// Viajan solo por su id: ambos móviles ya tienen las imágenes.
/// Las imágenes se generan con tool/make_stickers.py (la lista tiene que coincidir).
class KlkSticker {
  final String id;
  final String label;
  /// Sticker con movimiento (WebP animado en assets/stickers/anim/).
  final bool animated;
  const KlkSticker(this.id, this.label, {this.animated = false});

  String get asset => animated ? 'assets/stickers/anim/$id.webp' : 'assets/stickers/$id.png';
}

class StickerPack {
  final String name;
  final String icon; // emoji de la pestaña
  final List<KlkSticker> stickers;
  /// Solo se pueden enviar con KLK Plus (todos los ven al recibirlos).
  final bool plus;
  /// Stickers con sonido: la imagen de siempre y una voz (assets/sounds/stickers/<id>.m4a).
  final bool sound;
  const StickerPack(this.name, this.icon, this.stickers, {this.plus = false, this.sound = false});
}

/// Así viaja un sticker con sonido: el mismo sticker (las versiones viejas
/// ven la imagen) y este «mime» para que suene.
const soundStickerMime = 'klk/sound';

String soundStickerAsset(String id) => 'assets/sounds/stickers/$id.m4a';

/// Stickers con sonido: imagen del pack Criollos + nuestra voz.
const soundStickers = StickerPack('Con sonido', '🔊', [
  KlkSticker('klk', '¡Qué lo que, mi gente!'),
  KlkSticker('quelloque', '¡Qué lo que, manito!'),
  KlkSticker('diache', '¡Diache!'),
  KlkSticker('tamoactivo', '¡Tamo activo!'),
  KlkSticker('aymimadre', '¡Ay mi madre!'),
  KlkSticker('ombe', '¡Ombe, no!'),
  KlkSticker('wepa', '¡Wepa!'),
  KlkSticker('tutaloco', '¿Tú \'tá loco?'),
  KlkSticker('eseasi', '¡Eso e\' así!'),
  KlkSticker('tabuenoya', 'Ta\' bueno ya'),
  KlkSticker('concho', '¡Concho!'),
  KlkSticker('bendicion', '¡Bendiciones!'),
  KlkSticker('jajaja', '¡Jajajá!'),
  KlkSticker('tranquilo', 'Tranquilo, eso se resuelve'),
  KlkSticker('dimelo', '¡Dímelo, cantante!'),
  KlkSticker('suave', '¡Suave, suave!'),
], sound: true);

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
  StickerPack('Con movimiento', '✨', [
    KlkSticker('a_wepa', '¡Wepa!', animated: true),
    KlkSticker('a_jajaja', '¡Jajajá!', animated: true),
    KlkSticker('a_fuego', '¡Tá en fuego!', animated: true),
    KlkSticker('a_klk', '¡Klk!', animated: true),
    KlkSticker('a_dimelo', 'Dímelo', animated: true),
    KlkSticker('a_diache', '¡Diache!', animated: true),
    KlkSticker('a_tequiero', 'Te quiero un montón', animated: true),
    KlkSticker('a_besito', 'Un besito', animated: true),
    KlkSticker('a_bendiciones', '¡Bendiciones!', animated: true),
    KlkSticker('a_tamoactivo', 'Tamo\' activo', animated: true),
    KlkSticker('a_aymimadre', 'Ay mi madre', animated: true),
    KlkSticker('a_apagon', '¡Se fue la luz!', animated: true),
    KlkSticker('a_jonron', '¡Jonrón!', animated: true),
    KlkSticker('a_merengue', '¡Merengue!', animated: true),
    KlkSticker('a_cumple', '¡Feliz cumple!', animated: true),
    KlkSticker('a_navidad', '¡Feliz Navidad!', animated: true),
    KlkSticker('a_buenosdias', '¡Buenos días!', animated: true),
    KlkSticker('a_buenasnoches', 'Buenas noches', animated: true),
    KlkSticker('a_quecalor', '¡Qué calor!', animated: true),
    KlkSticker('a_toyready', 'Toy ready', animated: true),
  ], plus: true),
  StickerPack('Jerga dominicana', '🗣️', [
    KlkSticker('klkmiloco', 'Klk, mi loco'),
    KlkSticker('tamoeneso', 'Tamo\' en eso'),
    KlkSticker('tatobien', 'Ta\' to\' bien'),
    KlkSticker('ytuque', '¿Y tú qué?'),
    KlkSticker('dique', '¿Dique?'),
    KlkSticker('esavaina', '¡Esa vaina!'),
    KlkSticker('nitido', '¡Nítido!'),
    KlkSticker('pariguayo', '¡Pariguayo!'),
    KlkSticker('tigueraje', 'Puro tigueraje'),
    KlkSticker('mijeva', 'Mi jeva'),
    KlkSticker('mijevo', 'Mi jevo'),
    KlkSticker('guagua', 'Me dejó la guagua'),
    KlkSticker('quechulo', '¡Qué chulo!'),
    KlkSticker('dejaelbulto', 'Deja el bulto'),
    KlkSticker('palcoro', 'Vamo\' pa\'l coro'),
    KlkSticker('dejatripear', 'Deja de tripear'),
    KlkSticker('dameunabola', '¿Me da\' una bola?'),
    KlkSticker('quechercha', '¡Qué chercha!'),
    KlkSticker('embullao', 'Toy embullao'),
    KlkSticker('conyapa', '¡Con ñapa!'),
    KlkSticker('panafull', 'Pana full'),
    KlkSticker('manito', '¡Manito!'),
    KlkSticker('unapila', 'Una pila de gente'),
    KlkSticker('palzafacon', 'Pa\'l zafacón'),
    KlkSticker('palcolmado', 'Voy pa\'l colmado'),
    KlkSticker('concon', '¡Dame el concón!'),
    KlkSticker('moro', 'Moro de guandules'),
    KlkSticker('tostones', '¡Tostones!'),
    KlkSticker('chimi', 'Vamo\' por un chimi'),
    KlkSticker('yaroa', '¡Una yaroa!'),
    KlkSticker('inversor', 'Prende el inversor'),
    KlkSticker('motoconcho', 'Coge un motoconcho'),
    KlkSticker('quetapon', '¡Qué tapón!'),
    KlkSticker('yamismo', 'Ya mismo'),
    KlkSticker('ahoramismito', 'Ahora mismito'),
    KlkSticker('arrebatao', 'Tá arrebatao'),
    KlkSticker('tapegao', 'Tá pegao'),
    KlkSticker('jablador', '¡Jablador!'),
    KlkSticker('lambon', '¡Lambón!'),
    KlkSticker('nomefunas', 'No me fuña'),
    KlkSticker('fucu', '¡Fucú!'),
    KlkSticker('ojopelao', 'Ojo pela\'o'),
    KlkSticker('temangue', '¡Te mangué!'),
    KlkSticker('cogiendolucha', 'Cogiendo lucha'),
    KlkSticker('bregando', 'Aquí, bregando'),
    KlkSticker('atoloqueda', 'A to\' lo que da'),
    KlkSticker('notoyeneso', 'Yo no toy en eso'),
    KlkSticker('dimelomenor', 'Dímelo, menor'),
    KlkSticker('miloco', '¡Mi loco!'),
    KlkSticker('hermanazo', '¡Hermanazo!'),
    KlkSticker('biengracias', 'Bien, gracias a Dios'),
    KlkSticker('sidiosquiere', 'Si Dios quiere'),
    KlkSticker('aydiosmio', '¡Ay, Dios mío!'),
    KlkSticker('llegopapa', '¡Llegó papá!'),
    KlkSticker('tunove', '¿Tú no ve\'?'),
    KlkSticker('yentonce', '¿Y entonce\'?'),
    KlkSticker('tunumero', 'Ponte pa\' tu número'),
    KlkSticker('tadificil', 'Tá difícil'),
    KlkSticker('noesfacil', '¡No e\' fácil!'),
    KlkSticker('avemaria', '¡Avemaría!'),
    KlkSticker('jesu', '¡Jesú!'),
    KlkSticker('miramuchacho', 'Mira, muchacho'),
    KlkSticker('telojuro', 'Te lo juro'),
    KlkSticker('hablaclaro', 'Habla claro'),
    KlkSticker('quebulla', '¡Qué bulla!'),
    KlkSticker('aguanta', '¡Aguanta!'),
    KlkSticker('yatusabe', 'Ya tú sabe\''),
    KlkSticker('asimismoe', 'Así mismo e\''),
    KlkSticker('bendito', '¡Bendito!'),
  ]),
  StickerPack('Saludos', '👋', [
    KlkSticker('buenosdias', '¡Buenos días!'),
    KlkSticker('buenasnoches', 'Buenas noches'),
    KlkSticker('gracias', '¡Gracias!'),
    KlkSticker('deacuerdo', 'De acuerdo'),
    KlkSticker('felizfinde', '¡Feliz fin de semana!'),
    KlkSticker('diadelasmadres', '¡Feliz día, mamá!'),
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
  StickerPack(_kPlus ? 'Plus' : 'Extras', '💎', [
    KlkSticker('p_vuelvo', '¡Vuelvo pa\' RD!'),
    KlkSticker('p_extrano', 'Extraño mi tierra'),
    KlkSticker('p_jefa', '¡La jefa!'),
    KlkSticker('p_jefe', '¡El jefe!'),
    KlkSticker('p_fuego', '¡Tá en fuego!'),
    KlkSticker('p_estrella', '¡Tú ere\' una estrella!'),
    KlkSticker('p_solazo', '¡Qué solazo!'),
    KlkSticker('p_corazon', 'Con el corazón'),
    KlkSticker('p_gracias', '¡Gracia\' mi gente!'),
    KlkSticker('p_cool', 'Tranquilo y relajao'),
    KlkSticker('p_guino', 'Tú sabe\' cómo e\''),
    KlkSticker('p_risa', '¡Me muero de la risa!'),
  ], plus: true),
];

/// ¿Este sticker es del pack de KLK Plus?
bool isPlusSticker(String id) => stickerPacks.any((p) => p.plus && p.stickers.any((s) => s.id == id));

/// Todos los stickers, en orden.
final klkStickers = [for (final p in stickerPacks) ...p.stickers];

String stickerAsset(String? id) {
  for (final s in klkStickers) {
    if (s.id == id) return s.asset;
  }
  return 'assets/stickers/klk.png';
}
