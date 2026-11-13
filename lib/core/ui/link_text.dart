import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Busca páginas web en un texto: https://…, www.… y dominios sueltos
/// (klkmessenger.com, colmado.do…).
final linkPattern = RegExp(
  r'(https?://[^\s<>"]+|www\.[^\s<>"]+|\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.(?:com|net|org|do|app|io|es|ie|co|us|me|info|shop|store|tv|biz|mx|ar|cl|pe|ve|pr|eu|uk|online|site|xyz)\b(?:/[^\s<>"]*)?)',
  caseSensitive: false,
);

/// Convierte lo que escribió la gente en un enlace que se puede abrir.
Uri? linkUri(String raw) {
  var s = raw.trim();
  // Quita la puntuación pegada al final («mira klk.com.»).
  while (s.isNotEmpty && '.,;:!?)»"\''.contains(s[s.length - 1])) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return null;
  if (!s.toLowerCase().startsWith('http')) s = 'https://$s';
  return Uri.tryParse(s);
}

Future<void> openLink(String raw) async {
  final u = linkUri(raw);
  if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
}

/// Texto con páginas web que se pueden tocar (y menciones @ en negrita).
class LinkText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Color? linkColor;
  final Color? mentionColor;
  final bool mentions;
  const LinkText(this.text, {super.key, this.style, this.linkColor, this.mentionColor, this.mentions = false});

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final _taps = <TapGestureRecognizer>[];

  void _clear() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final text = widget.text;
    final re = widget.mentions
        ? RegExp('(?<![^\\s])(@[^\\s@]{1,40})|${linkPattern.pattern}', caseSensitive: false)
        : linkPattern;
    if (!re.hasMatch(text)) return Text(text, style: widget.style);
    final spans = <InlineSpan>[];
    var i = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      final s = m.group(0)!;
      if (s.startsWith('@')) {
        spans.add(TextSpan(text: s, style: TextStyle(fontWeight: FontWeight.w700, color: widget.mentionColor)));
      } else {
        final tap = TapGestureRecognizer()..onTap = () => openLink(s);
        _taps.add(tap);
        spans.add(TextSpan(
          text: s,
          recognizer: tap,
          style: TextStyle(
            decoration: TextDecoration.underline,
            color: widget.linkColor,
            fontWeight: FontWeight.w600,
          ),
        ));
      }
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
