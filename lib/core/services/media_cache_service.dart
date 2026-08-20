import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final http.Client _appMediaHttpClient = http.Client();
final _FileMutationGate _appMediaFileMutationGate = _FileMutationGate();
final MediaDownloadPort appMediaDownloadService = DefaultMediaDownloadService._(
  httpClient: _appMediaHttpClient,
  mutationGate: _appMediaFileMutationGate,
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

abstract interface class MediaDownloadCleanupPort {
  Future<void> drainCleanup();
}

abstract interface class MediaCachePort {
  Future<File?> cache(Uri uri, {Map<String, String> headers = const {}});

  Future<void> remove(Uri uri);
}

abstract interface class MediaFileOperations {
  Future<void> delete(File file);

  Future<File> rename(File file, String newPath);

  Stream<FileSystemEntity> list(Directory directory);
}

final class DefaultMediaFileOperations implements MediaFileOperations {
  const DefaultMediaFileOperations();

  @override
  Future<void> delete(File file) => file.delete();

  @override
  Future<File> rename(File file, String newPath) => file.rename(newPath);

  @override
  Stream<FileSystemEntity> list(Directory directory) => directory.list();
}

final class DefaultMediaDownloadService
    implements MediaDownloadPort, MediaDownloadCleanupPort {
  // Keep the public named httpClient parameter; storage remains private.
  factory DefaultMediaDownloadService({
    required http.Client httpClient,
    MediaFileOperations fileOperations = const DefaultMediaFileOperations(),
  }) => DefaultMediaDownloadService._(
    httpClient: httpClient,
    fileOperations: fileOperations,
    mutationGate: _FileMutationGate(),
  );

  DefaultMediaDownloadService._({
    required http.Client httpClient,
    required _FileMutationGate mutationGate,
    MediaFileOperations fileOperations = const DefaultMediaFileOperations(),
  })
    // ignore: prefer_initializing_formals
    : _httpClient = httpClient,
       // ignore: prefer_initializing_formals
       _fileOperations = fileOperations,
       // ignore: prefer_initializing_formals
       _mutationGate = mutationGate;

  final http.Client _httpClient;
  final MediaFileOperations _fileOperations;
  final _FileMutationGate _mutationGate;
  final Set<String> _pendingPartialCleanup = {};
  Future<void>? _cleanupFuture;

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
        await _abort(response.stream);
        throw MediaDownloadHttpException(response.statusCode);
      }

      final declaredBytes = response.contentLength;
      if (declaredBytes != null && declaredBytes > maxBytes) {
        await _abort(response.stream);
        throw MediaDownloadLimitException(maxBytes);
      }

      final confirm = confirmAfterHeaders;
      if (confirm != null) {
        late final bool accepted;
        try {
          accepted = await confirm(
            MediaDownloadInfo(
              statusCode: response.statusCode,
              contentType: response.headers['content-type'],
              declaredBytes: declaredBytes,
            ),
          );
        } catch (_) {
          await _abort(response.stream);
          rethrow;
        }
        if (!accepted) {
          await _abort(response.stream);
          throw const MediaDownloadDeclinedException();
        }
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
      try {
        if (await part.exists()) {
          await _fileOperations.delete(part);
        }
      } catch (_) {
        _pendingPartialCleanup.add(part.path);
      }
      rethrow;
    }
  }

  @override
  Future<void> drainCleanup() {
    final active = _cleanupFuture;
    if (active != null) return active;

    late final Future<void> operation;
    operation = _drainCleanupPass().whenComplete(() {
      if (identical(_cleanupFuture, operation)) _cleanupFuture = null;
    });
    _cleanupFuture = operation;
    return operation;
  }

  Future<void> _drainCleanupPass() async {
    final pending = _pendingPartialCleanup.toList(growable: false);
    for (final path in pending) {
      final part = File(path);
      try {
        if (!await part.exists()) {
          _pendingPartialCleanup.remove(path);
          continue;
        }
        await _fileOperations.delete(part);
        _pendingPartialCleanup.remove(path);
      } catch (_) {}
    }
  }

  static Future<void> _abort(Stream<List<int>> stream) async {
    StreamSubscription<List<int>>? subscription;
    try {
      subscription = stream.listen(null, onError: (_) {});
      await subscription.cancel();
    } catch (_) {
      if (subscription != null) {
        try {
          await subscription.cancel();
        } catch (_) {}
      }
    }
  }

  static File _uniqueSibling(File destination, String suffix) {
    final sequence = _temporaryFileSequence++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return File('${destination.path}.$timestamp.$sequence.$suffix');
  }

  Future<File> _promote(File part, File destination) =>
      _mutationGate.run(() async {
        File? old;
        if (await destination.exists()) {
          old = _uniqueSibling(destination, 'old');
          await _fileOperations.rename(destination, old.path);
          _mutationGate.markChanged(destination.path);
        }

        try {
          await _fileOperations.rename(part, destination.path);
          _mutationGate.markChanged(destination.path);
        } catch (_) {
          if (old != null && await old.exists()) {
            if (await destination.exists()) {
              try {
                await _fileOperations.delete(destination);
                _mutationGate.markChanged(destination.path);
              } catch (_) {}
            }
            await _fileOperations.rename(old, destination.path);
            _mutationGate.markChanged(destination.path);
          }
          rethrow;
        }

        if (old != null && await old.exists()) {
          try {
            await _fileOperations.delete(old);
          } catch (_) {}
        }
        return destination;
      });
}

final class MediaCacheService implements MediaCachePort {
  factory MediaCacheService({
    required Directory root,
    http.Client? httpClient,
    MediaDownloadPort? downloadService,
    int maxImageBytes = 50 * 1024 * 1024,
    int maxCacheBytes = 512 * 1024 * 1024,
    Duration maxAge = const Duration(days: 30),
    DateTime Function()? clock,
    MediaFileOperations fileOperations = const DefaultMediaFileOperations(),
  }) {
    final mutationGate = _FileMutationGate();
    return MediaCacheService._(
      root: Future<Directory>.value(root),
      maxImageBytes: maxImageBytes,
      maxCacheBytes: maxCacheBytes,
      maxAge: maxAge,
      fileOperations: fileOperations,
      downloadService:
          downloadService ??
          DefaultMediaDownloadService._(
            httpClient: httpClient ?? http.Client(),
            fileOperations: fileOperations,
            mutationGate: mutationGate,
          ),
      clock: clock ?? DateTime.now,
      mutationGate: mutationGate,
    );
  }

  MediaCacheService._({
    required Future<Directory> root,
    required this.maxImageBytes,
    required this.maxCacheBytes,
    required this.maxAge,
    required MediaFileOperations fileOperations,
    required MediaDownloadPort downloadService,
    required DateTime Function() clock,
    required _FileMutationGate mutationGate,
  })
    // ignore: prefer_initializing_formals
    : _root = root,
       // ignore: prefer_initializing_formals
       _fileOperations = fileOperations,
       // ignore: prefer_initializing_formals
       _downloadService = downloadService,
       // ignore: prefer_initializing_formals
       _clock = clock,
       // ignore: prefer_initializing_formals
       _mutationGate = mutationGate;

  MediaCacheService._appDefault()
    : _root = _applicationCacheRoot(),
      maxImageBytes = 50 * 1024 * 1024,
      maxCacheBytes = 512 * 1024 * 1024,
      maxAge = const Duration(days: 30),
      _fileOperations = const DefaultMediaFileOperations(),
      _downloadService = appMediaDownloadService,
      _clock = DateTime.now,
      _mutationGate = _appMediaFileMutationGate;

  final Future<Directory> _root;
  final int maxImageBytes;
  final int maxCacheBytes;
  final Duration maxAge;
  final MediaFileOperations _fileOperations;
  final MediaDownloadPort _downloadService;
  final DateTime Function() _clock;
  final _FileMutationGate _mutationGate;
  final Map<String, Future<File>> _inFlight = {};
  Future<void>? _maintenanceFuture;
  bool _maintenanceRequested = false;

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
      return downloaded;
    } catch (_) {
      if (staleIsComplete && await _isComplete(destination)) {
        return destination;
      }
      rethrow;
    } finally {
      _scheduleMaintenance();
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
    await _mutationGate.run(() async {
      if (await file.exists()) {
        await _fileOperations.delete(file);
        _mutationGate.markDeleted(file.path);
      }
    });
  }

  Future<void> drainMaintenance() async {
    if (_maintenanceFuture == null) _scheduleMaintenance();
    while (true) {
      final active = _maintenanceFuture;
      if (active == null) return;
      await active;
      if (_maintenanceFuture == null && !_maintenanceRequested) return;
    }
  }

  Future<void> close() => drainMaintenance();

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

  void _scheduleMaintenance() {
    _maintenanceRequested = true;
    if (_maintenanceFuture != null) return;

    late final Future<void> operation;
    operation = _runMaintenance().whenComplete(() {
      if (identical(_maintenanceFuture, operation)) {
        _maintenanceFuture = null;
      }
      if (_maintenanceRequested) _scheduleMaintenance();
    });
    _maintenanceFuture = operation;
  }

  Future<void> _runMaintenance() async {
    await Future<void>.delayed(Duration.zero);
    while (true) {
      _maintenanceRequested = false;
      await _waitForInFlight();
      _maintenanceRequested = false;
      await _maintainCache();
      if (!_maintenanceRequested) return;
    }
  }

  Future<void> _waitForInFlight() async {
    while (_inFlight.isNotEmpty) {
      final current = _inFlight.values.toList(growable: false);
      await Future.wait<void>(
        current.map((future) => future.then<void>((_) {}, onError: (_) {})),
      );
    }
  }

  Future<void> _maintainCache() async {
    try {
      final root = await _root;
      await root.create(recursive: true);
      final entries = <_CacheEntry>[];
      var totalBytes = 0;
      await for (final entity in _fileOperations.list(root)) {
        if (entity is! File) continue;

        if (entity.path.endsWith('.part')) {
          var deleted = false;
          if (_inFlight.isEmpty) {
            try {
              await _fileOperations.delete(entity);
              deleted = true;
            } catch (_) {}
          }
          if (!deleted) totalBytes += await _safeLength(entity);
          continue;
        }

        if (entity.path.endsWith('.old')) {
          final recovered = await _recoverOrCleanOld(entity);
          if (recovered.entry case final entry?) entries.add(entry);
          totalBytes += recovered.size;
          continue;
        }

        final entry = await _snapshotCanonical(entity);
        if (entry != null) {
          entries.add(entry);
          totalBytes += entry.size;
        }
      }

      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (totalBytes <= maxCacheBytes) break;
        final outcome = await _evictIfUnchanged(entry);
        if (outcome == _EvictionOutcome.deleted) {
          totalBytes -= entry.size;
        } else if (outcome == _EvictionOutcome.changed) {
          _maintenanceRequested = true;
        }
      }
    } catch (_) {}
  }

  Future<_CacheEntry?> _snapshotCanonical(File file) =>
      _mutationGate.run(() async {
        try {
          final stat = await file.stat();
          return _CacheEntry(
            file: file,
            modified: stat.modified,
            size: stat.size,
            generation: _mutationGate.generation(file.path),
          );
        } catch (_) {
          return null;
        }
      });

  Future<({int size, _CacheEntry? entry})> _recoverOrCleanOld(File old) async {
    final canonical = _canonicalForOld(old);
    if (canonical == null) return (size: await _safeLength(old), entry: null);

    return _mutationGate.run(() async {
      if (await _safeExists(canonical)) {
        try {
          await _fileOperations.delete(old);
          return (size: 0, entry: null);
        } catch (_) {
          return (size: await _safeLength(old), entry: null);
        }
      }

      try {
        final restored = await _fileOperations.rename(old, canonical.path);
        _mutationGate.markChanged(canonical.path);
        final stat = await restored.stat();
        return (
          size: stat.size,
          entry: _CacheEntry(
            file: restored,
            modified: stat.modified,
            size: stat.size,
            generation: _mutationGate.generation(restored.path),
          ),
        );
      } catch (_) {
        return (size: await _safeLength(old), entry: null);
      }
    });
  }

  Future<_EvictionOutcome> _evictIfUnchanged(_CacheEntry entry) =>
      _mutationGate.run(() async {
        if (_mutationGate.generation(entry.file.path) != entry.generation) {
          return _EvictionOutcome.changed;
        }

        try {
          final stat = await entry.file.stat();
          if (stat.size != entry.size || stat.modified != entry.modified) {
            return _EvictionOutcome.changed;
          }
          await _fileOperations.delete(entry.file);
          _mutationGate.markDeleted(entry.file.path);
          return _EvictionOutcome.deleted;
        } catch (_) {
          return _EvictionOutcome.failed;
        }
      });

  static File? _canonicalForOld(File old) {
    final match = RegExp(r'^(.*)\.\d+\.\d+\.old$').firstMatch(old.path);
    if (match == null) return null;
    return File(match.group(1)!);
  }

  static Future<bool> _safeExists(File file) async {
    try {
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  static Future<int> _safeLength(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }
}

final class _CacheEntry {
  const _CacheEntry({
    required this.file,
    required this.modified,
    required this.size,
    required this.generation,
  });

  final File file;
  final DateTime modified;
  final int size;
  final int generation;
}

enum _EvictionOutcome { deleted, changed, failed }

final class _FileMutationGate {
  Future<void> _tail = Future<void>.value();
  final Map<String, int> _generations = {};
  int _nextGeneration = 0;

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        released.complete();
      }
    });
  }

  int generation(String path) => _generations[path] ?? 0;

  void markDeleted(String path) {
    _generations.remove(path);
  }

  void markChanged(String path) {
    _generations[path] = ++_nextGeneration;
  }
}
