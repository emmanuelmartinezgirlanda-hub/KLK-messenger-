import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Comunidades por ciudad. En esta versión los datos son de ejemplo;
/// el servidor de comunidades (grupos públicos verificados) es la siguiente fase.
class CommunitiesView extends StatefulWidget {
  const CommunitiesView({super.key});

  @override
  State<CommunitiesView> createState() => _CommunitiesViewState();
}

class _Community {
  final String code, name, members;
  final Color color;
  bool joined;
  _Community(this.code, this.name, this.members, this.color, {this.joined = false});
}

class _CommunitiesViewState extends State<CommunitiesView> {
  final _items = [
    _Community('NY', 'Dominicanos en Nueva York', '48.210', const Color(0xFF002D62)),
    _Community('MAD', 'Dominicanos en Madrid', '21.904', const Color(0xFF6A2C91), joined: true),
    _Community('MIA', 'Dominicanos en Miami', '17.336', const Color(0xFF00A6B4)),
    _Community('PR', 'Dominicanos en Puerto Rico', '12.078', const Color(0xFFCE1126)),
    _Community('BCN', 'Dominicanos en Barcelona', '6.412', const Color(0xFFC46A00)),
    _Community('DUB', 'Dominicanos en Irlanda', '1.287', const Color(0xFF1F7A4D)),
    _Community('MIL', 'Dominicanos en Milán', '3.950', const Color(0xFF7A3B2E)),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('TU GENTE POR CIUDAD',
              style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: cs.secondary)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Vista previa con datos de ejemplo. Las comunidades llegan en la próxima versión.',
              style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
        ),
        const SizedBox(height: 8),
        const _NewsSection(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text('COMUNIDADES',
              style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: cs.secondary)),
        ),
        for (final c in _items)
          ListTile(
            leading: Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.color, borderRadius: BorderRadius.circular(14)),
              child: Text(c.code, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            ),
            title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${c.members} miembros'),
            trailing: c.joined
                ? FilledButton(onPressed: () => setState(() => c.joined = false), child: const Text('Dentro'))
                : OutlinedButton(onPressed: () => setState(() => c.joined = true), child: const Text('Unirme')),
          ),
      ],
    );
  }
}


/// Pelota y noticias de RD: accesos directos a las webs oficiales.
/// (Los resultados en vivo dentro de KLK necesitan un proveedor de datos deportivos.)
class _NewsSection extends StatelessWidget {
  const _NewsSection();

  static const _links = [
    ('⚾', 'Pelota invernal (LIDOM)', 'Calendario, resultados y posiciones', 'https://www.lidom.com'),
    ('⚾', 'Dominicanos en Grandes Ligas', 'MLB en español', 'https://www.mlb.com/es'),
    ('📰', 'Diario Libre', 'Noticias de RD', 'https://www.diariolibre.com'),
    ('📰', 'Listín Diario', 'Noticias de RD', 'https://listindiario.com'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(children: [
        const ListTile(
          title: Text('Pelota y noticias de RD', style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('Se abren en tu navegador. Los resultados en vivo dentro de KLK llegarán más adelante.'),
        ),
        for (final (icon, title, sub, url) in _links)
          ListTile(
            leading: CircleAvatar(backgroundColor: cs.surfaceContainerHighest, child: Text(icon)),
            title: Text(title),
            subtitle: Text(sub),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          ),
      ]),
    );
  }
}
