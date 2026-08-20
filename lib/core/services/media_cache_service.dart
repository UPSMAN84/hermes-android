import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final http.Client _appMediaHttpClient = http.Client();
final MediaDownloadPort appMediaDownloadService = DefaultMediaDownloadService(
  httpClient: _appMediaHttpClient,
);

final class MediaDownloadLimitException implements Exception {
  const MediaDownloadLimitException(this.limitBytes);

  final int limitBytes;
}

final class MediaDownloadHttpException implements Exception {
  const MediaDownloadHttpException(this.statusCode);

  final int statusCode;
}

final class MediaDownloadDeclinedException implements Exception {
  const MediaDownloadDeclinedException();
}

final class MediaDownloadInfo {
  const MediaDownloadInfo({
    required this.statusCode,
    this.contentType,
    this.declaredBytes,
  });

  final int statusCode;
  final String? contentType;
  final int? declaredBytes;
}

abstract interface class MediaDownloadPort {
  Future<File> download(
    Uri uri, {
    required File destination,
    required int maxBytes,
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  });
}

abstract interface class MediaCachePort {
  Future<File?> cache(Uri uri, {Map<String, String> headers = const {}});

  Future<void> remove(Uri uri);
}

final class DefaultMediaDownloadService implements MediaDownloadPort {
  // Keep the public named httpClient parameter; storage remains private.
  DefaultMediaDownloadService({required http.Client httpClient})
    // ignore: prefer_initializing_formals
    : _httpClient = httpClient;

  final http.Client _httpClient;

  static int _temporaryFileSequence = 0;

  @override
  Future<File> download(
    Uri uri, {
    required File destination,
    required int maxBytes,
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) {
    final copiedHeaders = Map<String, String>.of(headers);
    return _download(
      uri,
      destination: destination,
      maxBytes: maxBytes,
      headers: copiedHeaders,
      confirmAfterHeaders: confirmAfterHeaders,
    );
  }

  Future<File> _download(
    Uri uri, {
    required File destination,
    required int maxBytes,
    required Map<String, String> headers,
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) async {
    await destination.parent.create(recursive: true);
    final part = _uniqueSibling(destination, 'part');
    IOSink? sink;

    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      final response = await _httpClient.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MediaDownloadHttpException(response.statusCode);
      }

      final declaredBytes = response.contentLength;
      if (declaredBytes != null && declaredBytes > maxBytes) {
        throw MediaDownloadLimitException(maxBytes);
      }

      final confirm = confirmAfterHeaders;
      if (confirm != null) {
        final accepted = await confirm(
          MediaDownloadInfo(
            statusCode: response.statusCode,
            contentType: response.headers['content-type'],
            declaredBytes: declaredBytes,
          ),
        );
        if (!accepted) throw const MediaDownloadDeclinedException();
      }

      sink = part.openWrite();
      var receivedBytes = 0;
      await for (final chunk in response.stream) {
        receivedBytes += chunk.length;
        if (receivedBytes > maxBytes) {
          throw MediaDownloadLimitException(maxBytes);
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      return await _promote(part, destination);
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  static File _uniqueSibling(File destination, String suffix) {
    final sequence = _temporaryFileSequence++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return File('${destination.path}.$timestamp.$sequence.$suffix');
  }

  static Future<File> _promote(File part, File destination) async {
    File? old;
    if (await destination.exists()) {
      old = _uniqueSibling(destination, 'old');
      await destination.rename(old.path);
    }

    try {
      await part.rename(destination.path);
    } catch (_) {
      if (old != null && await old.exists()) {
        if (await destination.exists()) await destination.delete();
        await old.rename(destination.path);
      }
      rethrow;
    }

    if (old != null && await old.exists()) {
      try {
        await old.delete();
      } catch (_) {}
    }
    return destination;
  }
}

final class MediaCacheService implements MediaCachePort {
  MediaCacheService({
    required Directory root,
    http.Client? httpClient,
    MediaDownloadPort? downloadService,
    this.maxImageBytes = 50 * 1024 * 1024,
    this.maxCacheBytes = 512 * 1024 * 1024,
    this.maxAge = const Duration(days: 30),
    DateTime Function()? clock,
  }) : _root = Future<Directory>.value(root),
       _downloadService =
           downloadService ??
           DefaultMediaDownloadService(httpClient: httpClient ?? http.Client()),
       _clock = clock ?? DateTime.now;

  MediaCacheService._appDefault()
    : _root = _applicationCacheRoot(),
      maxImageBytes = 50 * 1024 * 1024,
      maxCacheBytes = 512 * 1024 * 1024,
      maxAge = const Duration(days: 30),
      _downloadService = appMediaDownloadService,
      _clock = DateTime.now;

  final Future<Directory> _root;
  final int maxImageBytes;
  final int maxCacheBytes;
  final Duration maxAge;
  final MediaDownloadPort _downloadService;
  final DateTime Function() _clock;
  final Map<String, Future<File>> _inFlight = {};

  static final MediaCacheService appDefault = MediaCacheService._appDefault();

  static Future<Directory> _applicationCacheRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}media_cache');
  }

  @override
  Future<File?> cache(Uri uri, {Map<String, String> headers = const {}}) {
    if (_isKnownVideo(uri)) return Future<File?>.value();
    return _coalescedCache(
      uri,
      headers: Map<String, String>.of(headers),
      requireImage: true,
    );
  }

  Future<File> _coalescedCache(
    Uri uri, {
    required Map<String, String> headers,
    required bool requireImage,
  }) {
    final key = uri.toString();
    final existing = _inFlight[key];
    if (existing != null) return existing;

    late final Future<File> operation;
    operation = _cache(uri, headers: headers, requireImage: requireImage)
        .whenComplete(() {
          if (identical(_inFlight[key], operation)) _inFlight.remove(key);
        });
    _inFlight[key] = operation;
    return operation;
  }

  Future<File> _cache(
    Uri uri, {
    required Map<String, String> headers,
    required bool requireImage,
  }) async {
    final root = await _root;
    await root.create(recursive: true);
    final destination = await _fileForUri(uri);
    final staleIsComplete = await _isComplete(destination);

    if (staleIsComplete) {
      final age = _clock().difference(await destination.lastModified());
      if (age < maxAge) return destination;
    }

    try {
      final downloaded = await _downloadService.download(
        uri,
        destination: destination,
        maxBytes: maxImageBytes,
        headers: headers,
        confirmAfterHeaders: requireImage
            ? (info) async {
                final type = info.contentType?.toLowerCase();
                return type == null || type.startsWith('image/');
    }
            : null,
      );
    await _evictIfNeeded();
      return downloaded;
    } catch (_) {
      if (staleIsComplete && await _isComplete(destination)) {
        return destination;
      }
      rethrow;
    }
  }

  @override
  Future<void> remove(Uri uri) async {
    final active = _inFlight[uri.toString()];
    if (active != null) {
      try {
        await active;
      } catch (_) {}
    }

    final file = await _fileForUri(uri);
    if (await file.exists()) await file.delete();
  }

  Future<File> _fileForUri(Uri uri) async {
    final root = await _root;
    return File('${root.path}${Platform.pathSeparator}${_keyFor(uri)}');
  }

  static bool _isKnownVideo(Uri uri) {
    const videoPattern = r'\.(mp4|webm|mkv|mov)$';
    final queryFilename = uri.queryParameters['filename'];
    return RegExp(videoPattern, caseSensitive: false).hasMatch(uri.path) ||
        (queryFilename != null &&
            RegExp(videoPattern, caseSensitive: false).hasMatch(queryFilename));
  }

  static Future<bool> _isComplete(File file) async =>
      await file.exists() && await file.length() > 0;

  static String _keyFor(Uri uri) {
    final url = uri.toString();
    final filename = uri.queryParameters['filename'] ?? '';
    final safeName = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final readable = safeName.length > 100
        ? safeName.substring(0, 100)
        : safeName;
    final suffix = readable.isEmpty ? '' : '_$readable';
    return '${_hash(url)}$suffix';
  }

  static String _hash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<void> _evictIfNeeded() async {
    try {
      final root = await _root;
      final entries = <({File file, DateTime modified, int size})>[];
      var totalBytes = 0;
      await for (final entity in root.list()) {
        if (entity is! File ||
            entity.path.endsWith('.part') ||
            entity.path.endsWith('.old')) {
          continue;
        }
        try {
          final stat = await entity.stat();
          entries.add((file: entity, modified: stat.modified, size: stat.size));
          totalBytes += stat.size;
        } catch (_) {}
      }

      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (totalBytes <= maxCacheBytes) break;
        try {
          await entry.file.delete();
          totalBytes -= entry.size;
        } catch (_) {}
    }
    } catch (_) {}
  }
}
