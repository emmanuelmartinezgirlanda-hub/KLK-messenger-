import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../features/messaging/models.dart';

/// Saca el título y la descripción de una página web para la vista previa.
///
/// La pide quien ENVÍA el enlace (como WhatsApp) y viaja cifrada dentro del
/// mensaje, así quien lo recibe no visita la web hasta que toca el enlace.
abstract final class LinkPreviewFetcher {
  static const _timeout = Duration(seconds: 4);
  static const _maxBytes = 300 * 1024;

  static Future<LinkPreview?> fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
    final client = http.Client();
    try {
      final req = http.Request('GET', uri)
        ..followRedirects = true
        ..maxRedirects = 4
        ..headers['User-Agent'] = 'Mozilla/5.0 (compatible; KLKmessenger/1.0; +link-preview)'
        ..headers['Accept'] = 'text/html';
      final res = await client.send(req).timeout(_timeout);
      final type = res.headers['content-type'] ?? '';
      if (res.statusCode != 200 || !type.contains('html')) return null;
      final bytes = <int>[];
      await for (final chunk in res.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= _maxBytes) break;
      }
      final html = utf8.decode(bytes, allowMalformed: true);
      final p = parse(html, url);
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Lee las etiquetas Open Graph (og:title…) o, si no hay, el <title>.
  static LinkPreview parse(String html, String url) {
    final head = html.length > 200000 ? html.substring(0, 200000) : html;
    String meta(String key) {
      final metas = RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(head);
      for (final m in metas) {
        final tag = m.group(0)!;
        final name = RegExp(r'''(?:property|name)\s*=\s*["']([^"']+)["']''', caseSensitive: false).firstMatch(tag)?.group(1);
        if (name == null || name.toLowerCase() != key) continue;
        final content = RegExp(r'''content\s*=\s*["']([^"']*)["']''', caseSensitive: false).firstMatch(tag)?.group(1);
        if (content != null && content.trim().isNotEmpty) return _clean(content);
      }
      return '';
    }

    var title = meta('og:title');
    if (title.isEmpty) title = meta('twitter:title');
    if (title.isEmpty) {
      final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(head)?.group(1);
      if (t != null) title = _clean(t);
    }
    var desc = meta('og:description');
    if (desc.isEmpty) desc = meta('description');
    var site = meta('og:site_name');
    if (site.isEmpty) site = Uri.tryParse(url)?.host.replaceFirst(RegExp(r'^www\.'), '') ?? '';
    return LinkPreview.fromJson({'u': url, 't': title, 'd': desc, 's': site});
  }

  static String _clean(String s) => s
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .trim();
}
