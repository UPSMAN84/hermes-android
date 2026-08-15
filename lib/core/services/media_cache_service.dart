// Disk cache for ComfyUI-served media (images/videos referenced by URL from
// tool results) so the app doesn't re-fetch the same generated file from the
// gateway's LAN every time a chat is reopened or the gallery is revisited.
//
// Only network-served (http/https) URLs go through this — user-attached
// images are `data:` URIs, already fully in-memory with no network round
// trip, so there's nothing to cache for those.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class MediaCacheService {
  MediaCacheService._();

  /// Total on-disk budget. Generated media is regenerable and re-fetchable
  /// from the gateway, so this is a convenience cache, not storage the user
  /// is relying on — keep it bounded rather than growing forever.
  static const int _maxBytes = 512 * 1024 * 1024; // 512 MB

  /// How long a cached copy is trusted before being re-fetched.
  static const Duration _maxAge = Duration(days: 30);

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

  /// Stable 32-bit FNV-1a hash, as 8 hex chars. Dart's own hashCode is NOT
  /// usable here — it is not guaranteed stable across process restarts, so a
  /// cache keyed on it would miss (and re-download) after every app launch.
  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// A filesystem-safe cache key for [url].
  ///
  /// Hashes the FULL url, not just the filename: ComfyUI view URLs vary by
  /// host and by `type` (output/input/temp) while reusing the same filename,
  /// so keying on filename alone collides — `?filename=x.png&type=output` and
  /// `?filename=x.png&type=input`, or the same filename served by two
  /// different ComfyUI hosts, would share one cache entry and serve the wrong
  /// image. The filename is still appended for human-readable cache dirs.
  static String _keyFor(String url) {
    final filename = Uri.tryParse(url)?.queryParameters['filename'] ?? '';
    final safeName = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    // Cap the readable half so the total stays well under the 255-byte
    // per-component filesystem limit.
    final suffix = safeName.isEmpty
        ? ''
        : '_${safeName.substring(0, safeName.length.clamp(0, 100))}';
    return '${_hash(url)}$suffix';
  }

  /// Returns a local [File] holding [url]'s bytes — served from disk if
  /// already downloaded, fetched and saved otherwise. Throws on a network
  /// failure with nothing cached yet (callers show their own error state).
  ///
  /// [headers] carries auth for sources that need it (gateway character
  /// images are behind the same Bearer token as every other API route;
  /// ComfyUI's /view is not). Headers are NOT part of the cache key — the
  /// same URL is the same bytes regardless of who asked.
  static Future<File> fileFor(String url, {Map<String, String>? headers}) async {
    final dir = await _cacheDir();
    final file = File('${dir.path}/${_keyFor(url)}');
    if (await file.exists() && await file.length() > 0) {
      // Bound staleness: ComfyUI's output counters (TG_00084_.png) restart
      // when its output dir is cleared, so a reused filename would otherwise
      // serve the old image from cache forever. Past the TTL, re-fetch.
      final age = DateTime.now().difference(await file.lastModified());
      if (age < _maxAge) return file;
    }

    final res = await _http.get(Uri.parse(url), headers: headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // A stale-but-present copy beats showing a broken image when the
      // server is unreachable or the file is gone upstream.
      if (await file.exists() && await file.length() > 0) return file;
      throw Exception('HTTP ${res.statusCode} fetching $url');
    }
    // Write to a temp file first and rename — an interrupted write (app
    // killed mid-download) must not leave a zero/partial-byte file that
    // the exists()+length()>0 check above would then treat as cached.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(res.bodyBytes, flush: true);
    await tmp.rename(file.path);
    unawaited(_evictIfNeeded());
    return file;
  }

  /// Trims the cache to [_maxBytes], oldest-first. Runs opportunistically
  /// after a write (fire-and-forget — never blocks rendering) and is
  /// self-guarded so concurrent writes can't run it twice at once.
  static bool _evicting = false;

  static Future<void> _evictIfNeeded() async {
    if (_evicting) return;
    _evicting = true;
    try {
      final dir = await _cacheDir();
      final entries = <({File file, DateTime modified, int size})>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          entries.add((
            file: entity,
            modified: stat.modified,
            size: stat.size,
          ));
          total += stat.size;
        } catch (_) {
          // Raced with another delete — skip it.
        }
      }
      if (total <= _maxBytes) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= _maxBytes) break;
        try {
          await entry.file.delete();
          total -= entry.size;
        } catch (_) {
          // Best-effort: a file in use just stays until the next pass.
        }
      }
    } catch (_) {
      // Eviction is housekeeping — never surface it to the caller.
    } finally {
      _evicting = false;
    }
  }
}
