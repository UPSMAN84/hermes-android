// Disk cache for ComfyUI-served media (images/videos referenced by URL from
// tool results) so the app doesn't re-fetch the same generated file from the
// gateway's LAN every time a chat is reopened or the gallery is revisited.
//
// Only network-served (http/https) URLs go through this — user-attached
// images are `data:` URIs, already fully in-memory with no network round
// trip, so there's nothing to cache for those.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class MediaCacheService {
  MediaCacheService._();

  static Directory? _dir;
  static final http.Client _http = http.Client();

  static Future<Directory> _cacheDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/media_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// A filesystem-safe cache key for [url]. ComfyUI view URLs always carry a
  /// `filename` query param (see ComfyUi.viewUrl) which is already a safe,
  /// stable, human-meaningful key; anything else falls back to a sanitized
  /// version of the whole URL so a lookup never throws on a weird input.
  static String _keyFor(String url) {
    final filename = Uri.tryParse(url)?.queryParameters['filename'];
    final base = (filename != null && filename.isNotEmpty) ? filename : url;
    return base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  /// Returns a local [File] holding [url]'s bytes — served from disk if
  /// already downloaded, fetched and saved otherwise. Throws on a network
  /// failure with nothing cached yet (callers show their own error state).
  static Future<File> fileFor(String url) async {
    final dir = await _cacheDir();
    final file = File('${dir.path}/${_keyFor(url)}');
    if (await file.exists() && await file.length() > 0) return file;

    final res = await _http.get(Uri.parse(url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode} fetching $url');
    }
    // Write to a temp file first and rename — an interrupted write (app
    // killed mid-download) must not leave a zero/partial-byte file that
    // the exists()+length()>0 check above would then treat as cached.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(res.bodyBytes, flush: true);
    await tmp.rename(file.path);
    return file;
  }
}
