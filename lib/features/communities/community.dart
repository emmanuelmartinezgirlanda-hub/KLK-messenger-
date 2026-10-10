/// Comunidad por país (la lista y los miembros vienen del servidor).
class Community {
  final String id; // código del país: DO, US, ES…
  final String name;
  final String flag;
  final int members;
  final bool joined;

  const Community({required this.id, required this.name, required this.flag, this.members = 0, this.joined = false});

  factory Community.fromJson(Map<String, dynamic> j) => Community(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        flag: j['flag'] as String? ?? '',
        members: (j['members'] as num?)?.toInt() ?? 0,
        joined: j['joined'] == true,
      );

  Community copyWith({int? members, bool? joined}) =>
      Community(id: id, name: name, flag: flag, members: members ?? this.members, joined: joined ?? this.joined);

  /// Id del chat de la comunidad dentro de KLK.
  String get chatId => communityChatId(id);

  String get title => id == 'DO' ? '$flag República Dominicana' : '$flag Dominicanos en $name';
}

String communityChatId(String code) => 'community:$code';
bool isCommunityChat(String chatId) => chatId.startsWith('community:');

/// Lista para el modo demo (sin servidor). Los números de miembros son 0: no se inventan.
const demoCommunities = <Community>[
  Community(id: 'DO', name: 'República Dominicana', flag: '🇩🇴'),
  Community(id: 'US', name: 'Estados Unidos', flag: '🇺🇸'),
  Community(id: 'ES', name: 'España', flag: '🇪🇸'),
  Community(id: 'PR', name: 'Puerto Rico', flag: '🇵🇷'),
  Community(id: 'IT', name: 'Italia', flag: '🇮🇹'),
  Community(id: 'CA', name: 'Canadá', flag: '🇨🇦'),
  Community(id: 'IE', name: 'Irlanda', flag: '🇮🇪'),
  Community(id: 'GB', name: 'Reino Unido', flag: '🇬🇧'),
  Community(id: 'FR', name: 'Francia', flag: '🇫🇷'),
  Community(id: 'DE', name: 'Alemania', flag: '🇩🇪'),
  Community(id: 'CH', name: 'Suiza', flag: '🇨🇭'),
  Community(id: 'NL', name: 'Países Bajos', flag: '🇳🇱'),
  Community(id: 'BE', name: 'Bélgica', flag: '🇧🇪'),
  Community(id: 'PT', name: 'Portugal', flag: '🇵🇹'),
  Community(id: 'PA', name: 'Panamá', flag: '🇵🇦'),
  Community(id: 'CO', name: 'Colombia', flag: '🇨🇴'),
  Community(id: 'VE', name: 'Venezuela', flag: '🇻🇪'),
  Community(id: 'MX', name: 'México', flag: '🇲🇽'),
  Community(id: 'CL', name: 'Chile', flag: '🇨🇱'),
  Community(id: 'AR', name: 'Argentina', flag: '🇦🇷'),
  Community(id: 'CR', name: 'Costa Rica', flag: '🇨🇷'),
  Community(id: 'HT', name: 'Haití', flag: '🇭🇹'),
  Community(id: 'AW', name: 'Aruba', flag: '🇦🇼'),
  Community(id: 'CW', name: 'Curazao', flag: '🇨🇼'),
];

/// País probable según el prefijo del teléfono (para sugerir "tu país").
String? countryOfPhone(String phone) {
  const prefixes = <String, String>{
    '+1809': 'DO', '+1829': 'DO', '+1849': 'DO', '+1787': 'PR', '+1939': 'PR',
    '+353': 'IE', '+351': 'PT', '+507': 'PA', '+506': 'CR', '+509': 'HT', '+297': 'AW', '+599': 'CW',
    '+34': 'ES', '+39': 'IT', '+44': 'GB', '+33': 'FR', '+49': 'DE', '+41': 'CH', '+31': 'NL', '+32': 'BE',
    '+57': 'CO', '+58': 'VE', '+52': 'MX', '+56': 'CL', '+54': 'AR', '+1': 'US',
  };
  final keys = prefixes.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final k in keys) {
    if (phone.startsWith(k)) return prefixes[k];
  }
  return null;
}
