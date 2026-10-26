import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/security/secure_store.dart';
import '../communities/community.dart';
import '../messaging/app_controller.dart';

/// KLK Mi Gente: el muro público dentro de KLK. Las publicaciones son públicas
/// para la gente de KLK (no van cifradas como los chats).

String _s(Object? v) => v is String ? v : '';

class GenteAuthor {
  final String id;
  final String name;
  final String photo; // id de la foto ('' = sin foto)
  const GenteAuthor({required this.id, this.name = '', this.photo = ''});

  factory GenteAuthor.fromJson(Object? j) {
    final m = j is Map ? j : const {};
    return GenteAuthor(id: _s(m['id']), name: _s(m['name']).trim(), photo: _s(m['photo']));
  }

  String get displayName => name.isEmpty ? 'Alguien de KLK' : name;
}

class GentePost {
  final String id;
  final GenteAuthor author;
  final String country;
  final String text;
  final List<String> photos;
  final DateTime createdAt;
  final int likes;
  final int comments;
  final bool liked;

  const GentePost({
    required this.id,
    required this.author,
    this.country = '',
    this.text = '',
    this.photos = const [],
    required this.createdAt,
    this.likes = 0,
    this.comments = 0,
    this.liked = false,
  });

  static GentePost? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']);
    final at = DateTime.tryParse(_s(j['createdAt']));
    if (id.isEmpty || at == null) return null;
    return GentePost(
      id: id,
      author: GenteAuthor.fromJson(j['author']),
      country: _s(j['country']),
      text: _s(j['text']),
      photos: [
        if (j['photos'] is List)
          for (final p in (j['photos'] as List).take(4))
            if (p is String && p.isNotEmpty) p
      ],
      createdAt: at,
      likes: (j['likes'] as num?)?.toInt() ?? 0,
      comments: (j['comments'] as num?)?.toInt() ?? 0,
      liked: j['liked'] == true,
    );
  }

  GentePost copyWith({int? likes, bool? liked, int? comments}) => GentePost(
        id: id,
        author: author,
        country: country,
        text: text,
        photos: photos,
        createdAt: createdAt,
        likes: likes ?? this.likes,
        comments: comments ?? this.comments,
        liked: liked ?? this.liked,
      );
}

class GenteComment {
  final String id;
  final GenteAuthor author;
  final String text;
  final DateTime createdAt;
  const GenteComment({required this.id, required this.author, required this.text, required this.createdAt});

  static GenteComment? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _s(j['id']);
    final at = DateTime.tryParse(_s(j['createdAt']));
    if (id.isEmpty || at == null) return null;
    return GenteComment(id: id, author: GenteAuthor.fromJson(j['author']), text: _s(j['text']), createdAt: at);
  }
}

/// "ahora", "hace 5 min", "hace 3 h", "ayer", "12 oct"…
String genteAgo(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.inMinutes < 1) return 'ahora';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  if (d.inHours < 24) return 'hace ${d.inHours} h';
  if (d.inDays == 1) return 'ayer';
  if (d.inDays < 7) return 'hace ${d.inDays} días';
  const months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  final l = t.toLocal();
  return '${l.day} ${months[l.month - 1]}${l.year == n.year ? '' : ' ${l.year}'}';
}

/// Bandera de un país ("DO" → 🇩🇴).
String flagOf(String country) {
  if (country.length != 2) return '';
  final c = country.toUpperCase().codeUnits;
  return String.fromCharCodes([0x1F1E6 + c[0] - 65, 0x1F1E6 + c[1] - 65]);
}

/// Publicaciones de ejemplo para el modo demo (no existen de verdad).
List<GentePost> demoGentePosts() {
  final now = DateTime.now();
  return [
    GentePost(
      id: 'demo-1',
      author: const GenteAuthor(id: 'demo-rosa', name: 'Rosa Martínez'),
      country: 'DO',
      text: '¡Klk mi gente! 🇩🇴 Hoy hay sancocho en casa de mami. ¿Quién viene? 🍲',
      createdAt: now.subtract(const Duration(minutes: 12)),
      likes: 24,
      comments: 6,
    ),
    GentePost(
      id: 'demo-2',
      author: const GenteAuthor(id: 'demo-juan', name: 'Juan Pérez'),
      country: 'IE',
      text: 'Los dominicanos en Dublín: este sábado hay bachata en el centro. ¡Pasen la voz! 💃🕺',
      createdAt: now.subtract(const Duration(hours: 3)),
      likes: 41,
      comments: 13,
    ),
    GentePost(
      id: 'demo-3',
      author: const GenteAuthor(id: 'demo-colmado', name: 'Colmado La Esquina'),
      country: 'DO',
      text: 'Llegó el aguacate bueno 🥑 y la cerveza está vestida de novia 🍺. Delivery hasta las 11.',
      createdAt: now.subtract(const Duration(days: 1, hours: 2)),
      likes: 57,
      comments: 9,
    ),
  ];
}

const _hiddenKey = 'klk.gente.hidden';
const _meKey = 'klk.gente.me';
const _rulesKey = 'klk.gente.rules';

/// Estado de Mi Gente: el muro, los filtros y mi perfil público.
class GenteController extends ChangeNotifier {
  GenteController(this._ref) {
    _restore();
  }

  final Ref _ref;
  AppController get app => _ref.read(appProvider);
  ApiClient? get _api => app.serverApi;
  SecureStore get _store => _ref.read(secureStoreProvider);

  /// '' = todos los países; si no, el código del país ("DO").
  String country = '';
  List<GentePost> _posts = [];
  bool loading = false;
  bool hasMore = true;
  bool loadedOnce = false;
  String? error;
  /// Gente que he bloqueado en Mi Gente (copia local de lo que guarda el servidor).
  Set<String> hiddenAuthors = {};

  /// ¿Acepté ya las normas de Mi Gente en esta cuenta?
  bool rulesAccepted = false;

  bool get isDemo => _api == null;

  /// Mi país según mi número (para el filtro "Mi país").
  String get myCountry => countryOfPhone(app.session?.phone ?? '') ?? '';

  String? imageUrl(String id) => id.isEmpty ? null : _api?.genteImageUrl(id);

  bool hides(String authorId) {
    if (hiddenAuthors.contains(authorId)) return true;
    return app.chats.any((c) => c.id == authorId && c.blocked);
  }

  List<GentePost> get posts => [for (final p in _posts) if (!hides(p.author.id)) p];

  Future<void> _restore() async {
    try {
      final v = jsonDecode(await _store.read(_hiddenKey) ?? '[]');
      if (v is List) hiddenAuthors = {for (final x in v) if (x is String) x};
      rulesAccepted = (await _store.read(_rulesKey)) == app.myId;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveHidden() async {
    try {
      await _store.write(_hiddenKey, jsonEncode(hiddenAuthors.toList()));
    } catch (_) {}
  }

  /// Trae del servidor a quién he bloqueado (por si cambié de móvil).
  Future<void> syncBlocks() async {
    final api = _api;
    if (api == null) return;
    try {
      final list = await api.genteBlocks();
      hiddenAuthors = {for (final j in list) if (GenteAuthor.fromJson(j).id.isNotEmpty) GenteAuthor.fromJson(j).id};
      notifyListeners();
      await _saveHidden();
    } catch (_) {}
  }

  /// Acepto las normas: se avisa al servidor la próxima vez que suba mi perfil.
  Future<void> acceptRules() async {
    rulesAccepted = true;
    notifyListeners();
    try {
      await _store.write(_rulesKey, app.myId);
      await _store.delete(_meKey); // fuerza a subir el perfil con la aceptación
    } catch (_) {}
  }

  Future<void> setCountry(String c) async {
    if (c == country) return;
    country = c;
    _posts = [];
    hasMore = true;
    notifyListeners();
    await refresh();
  }

  Future<void> refresh() async {
    if (!loadedOnce) unawaited(syncBlocks());
    if (isDemo) {
      _posts = [for (final p in demoGentePosts()) if (country.isEmpty || p.country == country) p];
      hasMore = false;
      loadedOnce = true;
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final list = await _api!.genteFeed(country: country);
      _posts = [for (final j in list) if (GentePost.tryParse(j) != null) GentePost.tryParse(j)!];
      hasMore = list.length >= 20;
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      loadedOnce = true;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (loading || !hasMore || isDemo || _posts.isEmpty) return;
    loading = true;
    notifyListeners();
    try {
      final list = await _api!.genteFeed(country: country, before: _posts.last.createdAt);
      final have = {for (final p in _posts) p.id};
      _posts = [
        ..._posts,
        for (final j in list)
          if (GentePost.tryParse(j) case final p? when !have.contains(p.id)) p
      ];
      hasMore = list.length >= 20;
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Las publicaciones de una persona (para su perfil).
  Future<List<GentePost>> postsBy(String authorId) async {
    if (isDemo) return [for (final p in demoGentePosts()) if (p.author.id == authorId) p];
    final list = await _api!.genteFeed(author: authorId);
    return [for (final j in list) if (GentePost.tryParse(j) != null) GentePost.tryParse(j)!];
  }

  void _replace(GentePost p) {
    _posts = [for (final x in _posts) x.id == p.id ? p : x];
    notifyListeners();
  }

  GentePost? byId(String id) => _posts.where((p) => p.id == id).firstOrNull;

  /// Me gusta / quitar me gusta (se ve al momento; si falla, se deshace).
  Future<GentePost> toggleLike(GentePost p) async {
    final on = !p.liked;
    final next = p.copyWith(liked: on, likes: (p.likes + (on ? 1 : -1)).clamp(0, 1 << 30));
    _replace(next);
    if (isDemo) return next;
    try {
      final n = await _api!.genteLike(p.id, on);
      final done = next.copyWith(likes: n);
      _replace(done);
      return done;
    } catch (e) {
      _replace(p);
      rethrow;
    }
  }

  void setCommentCount(String postId, int n) {
    final p = byId(postId);
    if (p != null) _replace(p.copyWith(comments: n));
  }

  /// Sube mi nombre y mi foto de perfil para que salgan en lo que publico.
  /// Solo vuelve a subir la foto si la cambié.
  Future<void> ensureProfile() async {
    final api = _api;
    if (api == null) return;
    final name = app.profile.name.trim().isEmpty ? 'Alguien de KLK' : app.profile.name.trim();
    final path = app.profile.photoPath;
    var photoKey = '';
    File? file;
    if (path != null) {
      final f = File(path);
      if (f.existsSync()) {
        final st = f.statSync();
        photoKey = '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
        file = f;
      }
    }
    Map<String, dynamic> saved = {};
    try {
      final v = jsonDecode(await _store.read(_meKey) ?? '{}');
      if (v is Map<String, dynamic>) saved = v;
    } catch (_) {}
    if (saved['name'] == name && saved['key'] == photoKey && saved['acc'] == app.myId && saved['rules'] == rulesAccepted) {
      return;
    }
    var photo = '';
    if (file != null) {
      photo = saved['key'] == photoKey && saved['acc'] == app.myId ? (saved['photo'] as String? ?? '') : '';
      if (photo.isEmpty) {
        try {
          photo = await api.uploadGenteImage(await file.readAsBytes());
        } catch (_) {
          photo = ''; // sin foto: sale la inicial
        }
      }
    }
    await api.genteSetProfile(name, photo, rules: rulesAccepted);
    await _store.write(
        _meKey, jsonEncode({'name': name, 'key': photoKey, 'photo': photo, 'acc': app.myId, 'rules': rulesAccepted}));
  }

  /// Publica [text] con hasta 4 fotos (ya reducidas). Sale arriba del todo.
  Future<GentePost> publish(String text, List<Uint8List> photos, {void Function(int done)? onPhoto}) async {
    final api = _api;
    if (api == null) throw const ApiException(0, 'demo', 'En el modo demo no se puede publicar.');
    await ensureProfile();
    final ids = <String>[];
    for (final b in photos.take(4)) {
      ids.add(await api.uploadGenteImage(b));
      onPhoto?.call(ids.length);
    }
    final j = await api.genteCreatePost(text.trim(), ids, myCountry);
    final p = GentePost.tryParse(j)!;
    if (country.isEmpty || country == p.country) {
      _posts = [p, ..._posts];
      notifyListeners();
    }
    return p;
  }

  Future<void> delete(GentePost p) async {
    if (!isDemo) await _api!.genteDeletePost(p.id);
    _posts = _posts.where((x) => x.id != p.id).toList();
    notifyListeners();
  }

  Future<void> report(GentePost p, String reason) async {
    if (!isDemo) await _api!.genteReport(postId: p.id, reason: reason);
  }

  Future<void> reportComment(GenteComment c, String reason) async {
    if (!isDemo) await _api!.genteReport(commentId: c.id, reason: reason);
  }

  /// Bloqueo a alguien en Mi Gente: no veo lo suyo, no ve lo mío y no puede
  /// comentar ni dar me gusta a lo mío. Se guarda en el servidor.
  Future<void> block(String id) async {
    if (!isDemo) await _api!.genteBlock(id, true);
    hiddenAuthors = {...hiddenAuthors, id};
    notifyListeners();
    await _saveHidden();
  }

  Future<void> unblock(String id) async {
    if (!isDemo) await _api!.genteBlock(id, false);
    hiddenAuthors = {...hiddenAuthors}..remove(id);
    notifyListeners();
    await _saveHidden();
  }

  /// Desbloquea a todos los que bloqueé en Mi Gente.
  Future<void> unhideAll() async {
    for (final id in [...hiddenAuthors]) {
      try {
        await unblock(id);
      } catch (_) {}
    }
    await refresh();
  }

  Future<List<GenteComment>> comments(String postId) async {
    if (isDemo) return const [];
    final list = await _api!.genteComments(postId);
    return [
      for (final j in list)
        if (GenteComment.tryParse(j) case final c? when !hides(c.author.id)) c
    ];
  }

  Future<GenteComment> addComment(String postId, String text) async {
    final api = _api;
    if (api == null) throw const ApiException(0, 'demo', 'En el modo demo no se puede comentar.');
    await ensureProfile();
    return GenteComment.tryParse(await api.genteAddComment(postId, text.trim()))!;
  }

  Future<void> deleteComment(GenteComment c) async {
    if (!isDemo) await _api!.genteDeleteComment(c.id);
  }
}

final genteProvider = ChangeNotifierProvider<GenteController>((ref) => GenteController(ref));
