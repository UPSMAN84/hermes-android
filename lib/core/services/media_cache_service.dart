import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

final http.Client _appMediaHttpClient = http.Client();
final MediaDownloadPort appMediaDownloadService = DefaultMediaDownloadService(
  httpClient: _appMediaHttpClient,
);

final Map<String, WeakReference<MediaCacheMutationCoordinator>>
_mediaCacheMutationCoordinators = {};

MediaCacheMutationCoordinator _coordinatorForRootIdentity(
  String identity, {
  MediaCacheMutationCoordinator? preferred,
}) {
  _mediaCacheMutationCoordinators.removeWhere(
    (_, reference) => reference.target == null,
  );
  final existing = _mediaCacheMutationCoordinators[identity]?.target;
  if (existing != null) return existing;

  final coordinator = preferred ?? MediaCacheMutationCoordinator();
  _mediaCacheMutationCoordinators[identity] = WeakReference(coordinator);
  return coordinator;
}

Future<_ResolvedMediaCacheRoot> _resolveMediaCacheRoot(
  Directory requested, {
  MediaCacheMutationCoordinator? preferredCoordinator,
}) async {
  final absolute = Directory(_normalizedAbsolutePath(requested.path));
  await absolute.create(recursive: true);
  final realPath = _trimTrailingSeparators(
    _normalizedAbsolutePath(await absolute.resolveSymbolicLinks()),
  );
  final directory = Directory(realPath);
  final identity = _pathIdentity(realPath);
  return _ResolvedMediaCacheRoot(
    directory: directory,
    identity: identity,
    coordinator: _coordinatorForRootIdentity(
      identity,
      preferred: preferredCoordinator,
    ),
  );
}

String _normalizedAbsolutePath(String path) => File(
  path,
).absolute.uri.normalizePath().toFilePath(windows: Platform.isWindows);

String _trimTrailingSeparators(String path) {
  var result = path;
  while (Directory(result).parent.path != result &&
      result.endsWith(Platform.pathSeparator)) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

String _pathIdentity(String path) {
  final normalized = _trimTrailingSeparators(_normalizedAbsolutePath(path));
  if (Platform.isWindows || Platform.isMacOS) {
    return normalized.toLowerCase();
  }
  return normalized;
}

final class _ResolvedMediaCacheRoot {
  const _ResolvedMediaCacheRoot({
    required this.directory,
    required this.identity,
    required this.coordinator,
  });

  final Directory directory;
  final String identity;
  final MediaCacheMutationCoordinator coordinator;

  File child(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\')) {
      throw ArgumentError.value(name, 'name', 'Must be one confined filename.');
    }
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    _requireConfinedIdentity(_pathIdentity(file.path));
    return file;
  }

  Future<File> confine(File file) async {
    final normalizedPath = _normalizedAbsolutePath(file.path);
    final lexicalIdentity = _pathIdentity(normalizedPath);
    _requireConfinedIdentity(lexicalIdentity);
    final type = await FileSystemEntity.type(
      normalizedPath,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      throw FileSystemException(
        'Media cache files cannot be symbolic links.',
        normalizedPath,
      );
    }
    final resolvedPath = await _resolveThroughExistingAncestor(normalizedPath);
    _requireConfinedIdentity(_pathIdentity(resolvedPath));
    return File(resolvedPath);
  }

  Future<String> _resolveThroughExistingAncestor(String path) async {
    var current = path;
    final missingSegments = <String>[];
    while (true) {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        final resolved = switch (type) {
          FileSystemEntityType.file => await File(
            current,
          ).resolveSymbolicLinks(),
          FileSystemEntityType.directory => await Directory(
            current,
          ).resolveSymbolicLinks(),
          FileSystemEntityType.link => await Link(
            current,
          ).resolveSymbolicLinks(),
          _ => throw FileSystemException(
            'Unsupported media cache path entity.',
            current,
          ),
        };
        var result = _normalizedAbsolutePath(resolved);
        for (final segment in missingSegments.reversed) {
          result = _normalizedAbsolutePath(
            '$result${Platform.pathSeparator}$segment',
          );
        }
        return result;
      }

      final parent = Directory(current).parent.path;
      if (_pathIdentity(parent) == _pathIdentity(current)) {
        throw FileSystemException(
          'Media cache path has no resolvable ancestor.',
          path,
        );
      }
      var segmentOffset = parent.length;
      while (segmentOffset < current.length &&
          (current[segmentOffset] == '/' || current[segmentOffset] == r'\')) {
        segmentOffset++;
      }
      missingSegments.add(current.substring(segmentOffset));
      current = parent;
    }
  }

  bool _isConfinedIdentity(String candidate) =>
      candidate.startsWith('$identity${Platform.pathSeparator}');

  void _requireConfinedIdentity(String candidate) {
    if (_isConfinedIdentity(candidate)) return;
    throw FileSystemException(
      'Media cache path escapes its normalized root.',
      candidate,
    );
  }
}

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

abstract interface class MediaDownloadOwnershipPort {
  Future<File> downloadOwned(
    Uri uri, {
    required File destination,
    required int maxBytes,
    required MediaDownloadCleanupScope cleanupScope,
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  });
}

abstract interface class MediaDownloadCleanupPort {
  bool get hasPendingCleanup;

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

final class MediaDownloadCleanupScope implements MediaDownloadCleanupPort {
  final Map<String, _PendingMediaDownloadCleanup> _pending = {};
  Future<void>? _cleanupFuture;

  @override
  bool get hasPendingCleanup => _pending.isNotEmpty;

  Future<File> download(
    MediaDownloadPort downloadService,
    Uri uri, {
    required File destination,
    required int maxBytes,
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) {
    if (downloadService case final MediaDownloadOwnershipPort owned) {
      return owned.downloadOwned(
        uri,
        destination: destination,
        maxBytes: maxBytes,
        cleanupScope: this,
        headers: headers,
        confirmAfterHeaders: confirmAfterHeaders,
      );
    }
    return downloadService.download(
      uri,
      destination: destination,
      maxBytes: maxBytes,
      headers: headers,
      confirmAfterHeaders: confirmAfterHeaders,
    );
  }

  Future<void> deleteOrSchedule(
    File file, {
    MediaFileOperations fileOperations = const DefaultMediaFileOperations(),
  }) async {
    final pending = _PendingMediaDownloadCleanup(
      file: File(_normalizedAbsolutePath(file.path)),
      fileOperations: fileOperations,
    );
    if (await pending.tryDelete()) return;
    _pending[_pathIdentity(file.path)] = pending;
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
    final pending = _pending.entries.toList(growable: false);
    for (final entry in pending) {
      if (!await entry.value.tryDelete()) continue;
      if (identical(_pending[entry.key], entry.value)) {
        _pending.remove(entry.key);
      }
    }
  }
}

final class _PendingMediaDownloadCleanup {
  const _PendingMediaDownloadCleanup({
    required this.file,
    required this.fileOperations,
  });

  final File file;
  final MediaFileOperations fileOperations;

  Future<bool> tryDelete() async {
    try {
      if (await file.exists()) await fileOperations.delete(file);
      return true;
    } catch (_) {
      return false;
    }
  }
}

final class DefaultMediaDownloadService
    implements
        MediaDownloadPort,
        MediaDownloadOwnershipPort,
        MediaDownloadCleanupPort {
  // Keep the public named httpClient parameter; storage remains private.
  factory DefaultMediaDownloadService({
    required http.Client httpClient,
    MediaFileOperations fileOperations = const DefaultMediaFileOperations(),
  }) => DefaultMediaDownloadService._(
    httpClient: httpClient,
    fileOperations: fileOperations,
    mutationCoordinator: MediaCacheMutationCoordinator(),
  );

  DefaultMediaDownloadService._({
    required http.Client httpClient,
    required MediaCacheMutationCoordinator mutationCoordinator,
    MediaFileOperations fileOperations = const DefaultMediaFileOperations(),
  })
    // ignore: prefer_initializing_formals
    : _httpClient = httpClient,
       // ignore: prefer_initializing_formals
       _fileOperations = fileOperations,
       // ignore: prefer_initializing_formals
       _mutationCoordinator = mutationCoordinator;

  final http.Client _httpClient;
  final MediaFileOperations _fileOperations;
  final MediaCacheMutationCoordinator _mutationCoordinator;
  final MediaDownloadCleanupScope _defaultCleanupScope =
      MediaDownloadCleanupScope();

  static int _temporaryFileSequence = 0;

  @override
  bool get hasPendingCleanup => _defaultCleanupScope.hasPendingCleanup;

  @override
  Future<File> download(
    Uri uri, {
    required File destination,
    required int maxBytes,
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) => downloadOwned(
    uri,
    destination: destination,
    maxBytes: maxBytes,
    cleanupScope: _defaultCleanupScope,
    headers: headers,
    confirmAfterHeaders: confirmAfterHeaders,
  );

  @override
  Future<File> downloadOwned(
    Uri uri, {
    required File destination,
    required int maxBytes,
    required MediaDownloadCleanupScope cleanupScope,
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
      cleanupScope: cleanupScope,
    );
  }

  Future<File> _download(
    Uri uri, {
    required File destination,
    required int maxBytes,
    required Map<String, String> headers,
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
    required MediaDownloadCleanupScope cleanupScope,
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
      await cleanupScope.deleteOrSchedule(
        part,
        fileOperations: _fileOperations,
      );
      rethrow;
    }
  }

  @override
  Future<void> drainCleanup() => _defaultCleanupScope.drainCleanup();

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
    final destinationPath = _normalizedAbsolutePath(destination.path);
    return File('$destinationPath.$timestamp.$sequence.$suffix');
  }

  Future<File> _promote(File part, File destination) =>
      _mutationCoordinator._run(() async {
        File? old;
        if (await destination.exists()) {
          old = _uniqueSibling(destination, 'old');
          await _fileOperations.rename(destination, old.path);
          _mutationCoordinator._markChanged(destination.path);
        }

        try {
          await _fileOperations.rename(part, destination.path);
          _mutationCoordinator._markChanged(destination.path);
        } catch (_) {
          if (old != null && await old.exists()) {
            if (await destination.exists()) {
              try {
                await _fileOperations.delete(destination);
                _mutationCoordinator._markChanged(destination.path);
              } catch (_) {}
            }
            await _fileOperations.rename(old, destination.path);
            _mutationCoordinator._markChanged(destination.path);
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
    MediaCacheMutationCoordinator? mutationCoordinator,
  }) {
    return MediaCacheService._(
      root: _resolveMediaCacheRoot(
        root,
        preferredCoordinator: mutationCoordinator,
      ),
      maxImageBytes: maxImageBytes,
      maxCacheBytes: maxCacheBytes,
      maxAge: maxAge,
      fileOperations: fileOperations,
      downloadService: downloadService,
      httpClient: httpClient,
      clock: clock ?? DateTime.now,
    );
  }

  MediaCacheService._({
    required Future<_ResolvedMediaCacheRoot> root,
    required this.maxImageBytes,
    required this.maxCacheBytes,
    required this.maxAge,
    required MediaFileOperations fileOperations,
    required MediaDownloadPort? downloadService,
    required http.Client? httpClient,
    required DateTime Function() clock,
  })
    // ignore: prefer_initializing_formals
    : _root = root,
       // ignore: prefer_initializing_formals
       _fileOperations = fileOperations,
       // ignore: prefer_initializing_formals
       _downloadService = downloadService,
       // ignore: prefer_initializing_formals
       _httpClient = httpClient,
       // ignore: prefer_initializing_formals
       _clock = clock;

  MediaCacheService._appDefault()
    : _root = _applicationCacheRoot().then(_resolveMediaCacheRoot),
      maxImageBytes = 50 * 1024 * 1024,
      maxCacheBytes = 512 * 1024 * 1024,
      maxAge = const Duration(days: 30),
      _fileOperations = const DefaultMediaFileOperations(),
      _downloadService = null,
      _httpClient = _appMediaHttpClient,
      _clock = DateTime.now,
      _ownedDownloadService = null;

  final Future<_ResolvedMediaCacheRoot> _root;
  final int maxImageBytes;
  final int maxCacheBytes;
  final Duration maxAge;
  final MediaFileOperations _fileOperations;
  final MediaDownloadPort? _downloadService;
  final http.Client? _httpClient;
  final DateTime Function() _clock;
  MediaDownloadPort? _ownedDownloadService;
  final MediaDownloadCleanupScope _downloadCleanupScope =
      MediaDownloadCleanupScope();
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
    final cacheRoot = await _root;
    final coordinator = cacheRoot.coordinator;
    final destination = cacheRoot.child(_keyFor(uri));
    await cacheRoot.confine(destination);
    final staleIsComplete = await _isComplete(destination);

    if (staleIsComplete) {
      final age = _clock().difference(await destination.lastModified());
      if (age < maxAge) return destination;
    }

    final staging = DefaultMediaDownloadService._uniqueSibling(
      destination,
      'part',
    );
    await cacheRoot.confine(staging);
    coordinator._registerTemporary(staging.path);
    File? produced;
    File? confinedProduced;
    try {
      produced = await _downloadCleanupScope.download(
        _downloadServiceFor(cacheRoot),
        uri,
        destination: staging,
        maxBytes: maxImageBytes,
        headers: headers,
        confirmAfterHeaders: requireImage
            ? (info) async {
                final type = info.contentType?.toLowerCase();
                return type == null || type.startsWith('image/');
              }
            : null,
      );
      confinedProduced = await cacheRoot.confine(produced);
      return await _promoteToCanonical(
        confinedProduced,
        destination,
        cacheRoot,
      );
    } catch (_) {
      if (staleIsComplete && await _isComplete(destination)) {
        return destination;
      }
      rethrow;
    } finally {
      coordinator._unregisterTemporary(staging.path);
      await _deleteTemporary(cacheRoot, staging, ownsLinkEntry: true);
      if (confinedProduced != null &&
          _pathIdentity(confinedProduced.path) !=
              _pathIdentity(destination.path) &&
          _pathIdentity(confinedProduced.path) != _pathIdentity(staging.path)) {
        await _deleteTemporary(
          cacheRoot,
          confinedProduced,
          ownsLinkEntry: false,
        );
      }
      _scheduleMaintenance();
    }
  }

  MediaDownloadPort _downloadServiceFor(_ResolvedMediaCacheRoot root) {
    final injected = _downloadService;
    if (injected != null) return injected;
    return _ownedDownloadService ??= DefaultMediaDownloadService._(
      httpClient: _httpClient ?? http.Client(),
      fileOperations: _fileOperations,
      mutationCoordinator: root.coordinator,
    );
  }

  Future<File> _promoteToCanonical(
    File source,
    File destination,
    _ResolvedMediaCacheRoot root,
  ) {
    return root.coordinator._run(() async {
      final confinedSource = await root.confine(source);
      final confinedDestination = await root.confine(destination);
      if (_pathIdentity(confinedSource.path) ==
          _pathIdentity(confinedDestination.path)) {
        return confinedDestination;
      }
      File? old;
      if (await confinedDestination.exists()) {
        old = DefaultMediaDownloadService._uniqueSibling(
          confinedDestination,
          'old',
        );
        await root.confine(old);
        await _fileOperations.rename(confinedDestination, old.path);
        root.coordinator._markChanged(confinedDestination.path);
      }

      try {
        await _fileOperations.rename(confinedSource, confinedDestination.path);
        root.coordinator._markChanged(confinedDestination.path);
      } catch (_) {
        if (old != null && await old.exists()) {
          if (await confinedDestination.exists()) {
            try {
              await _fileOperations.delete(confinedDestination);
              root.coordinator._markChanged(confinedDestination.path);
            } catch (_) {}
          }
          await _fileOperations.rename(old, confinedDestination.path);
          root.coordinator._markChanged(confinedDestination.path);
        }
        rethrow;
      }

      if (old != null && await old.exists()) {
        try {
          await _fileOperations.delete(old);
        } catch (_) {}
      }
      return confinedDestination;
    });
  }

  Future<void> _deleteTemporary(
    _ResolvedMediaCacheRoot root,
    File temporary, {
    required bool ownsLinkEntry,
  }) async {
    try {
      final normalizedPath = _normalizedAbsolutePath(temporary.path);
      final type = await FileSystemEntity.type(
        normalizedPath,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.link) {
        if (ownsLinkEntry) {
          root._requireConfinedIdentity(_pathIdentity(normalizedPath));
          await Link(normalizedPath).delete();
        }
        return;
      }
      if (type != FileSystemEntityType.file) return;

      final confined = await root.confine(File(normalizedPath));
      final confinedType = await FileSystemEntity.type(
        confined.path,
        followLinks: false,
      );
      if (confinedType == FileSystemEntityType.file) {
        await _fileOperations.delete(confined);
      } else if (confinedType == FileSystemEntityType.link && ownsLinkEntry) {
        await Link(confined.path).delete();
      }
    } catch (_) {}
  }

  @override
  Future<void> remove(Uri uri) async {
    final active = _inFlight[uri.toString()];
    if (active != null) {
      try {
        await active;
      } catch (_) {}
    }

    final root = await _root;
    final file = root.child(_keyFor(uri));
    await root.confine(file);
    await root.coordinator._run(() async {
      if (await file.exists()) {
        await _fileOperations.delete(file);
        root.coordinator._markDeleted(file.path);
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

  Future<void> close() async {
    await drainMaintenance();
    for (var pass = 0; pass < 3; pass++) {
      await _downloadCleanupScope.drainCleanup();
      if (!_downloadCleanupScope.hasPendingCleanup) return;
      if (pass < 2) await Future<void>.delayed(Duration.zero);
    }
    throw StateError(
      'MediaCacheService still has pending download cleanup after 3 passes.',
    );
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
      final cacheRoot = await _root;
      final root = cacheRoot.directory;
      final coordinator = cacheRoot.coordinator;
      final entries = <_CacheEntry>[];
      var totalBytes = 0;
      await for (final entity in _fileOperations.list(root)) {
        if (entity is! File) continue;
        final confinedEntity = await cacheRoot.confine(entity);

        if (confinedEntity.path.endsWith('.part')) {
          var deleted = false;
          if (_inFlight.isEmpty) {
            deleted = await coordinator._run(() async {
              if (_inFlight.isNotEmpty ||
                  coordinator._isTemporaryActive(confinedEntity.path)) {
                return false;
              }
              try {
                await _fileOperations.delete(confinedEntity);
                return true;
              } catch (_) {
                return false;
              }
            });
          }
          if (!deleted) totalBytes += await _safeLength(confinedEntity);
          continue;
        }

        if (confinedEntity.path.endsWith('.old')) {
          final recovered = await _recoverOrCleanOld(
            confinedEntity,
            coordinator,
          );
          if (recovered.entry case final entry?) entries.add(entry);
          totalBytes += recovered.size;
          continue;
        }

        final entry = await _snapshotCanonical(confinedEntity, coordinator);
        if (entry != null) {
          entries.add(entry);
          totalBytes += entry.size;
        }
      }

      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (totalBytes <= maxCacheBytes) break;
        final outcome = await _evictIfUnchanged(entry, coordinator);
        if (outcome == _EvictionOutcome.deleted) {
          totalBytes -= entry.size;
        } else if (outcome == _EvictionOutcome.changed) {
          _maintenanceRequested = true;
        }
      }
    } catch (_) {}
  }

  Future<_CacheEntry?> _snapshotCanonical(
    File file,
    MediaCacheMutationCoordinator coordinator,
  ) => coordinator._run(() async {
    try {
      final stat = await file.stat();
      return _CacheEntry(
        file: file,
        modified: stat.modified,
        size: stat.size,
        generation: coordinator._generation(file.path),
      );
    } catch (_) {
      return null;
    }
  });

  Future<({int size, _CacheEntry? entry})> _recoverOrCleanOld(
    File old,
    MediaCacheMutationCoordinator coordinator,
  ) async {
    final canonical = _canonicalForOld(old);
    if (canonical == null) return (size: await _safeLength(old), entry: null);

    return coordinator._run(() async {
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
        coordinator._markChanged(canonical.path);
        final stat = await restored.stat();
        return (
          size: stat.size,
          entry: _CacheEntry(
            file: restored,
            modified: stat.modified,
            size: stat.size,
            generation: coordinator._generation(restored.path),
          ),
        );
      } catch (_) {
        return (size: await _safeLength(old), entry: null);
      }
    });
  }

  Future<_EvictionOutcome> _evictIfUnchanged(
    _CacheEntry entry,
    MediaCacheMutationCoordinator coordinator,
  ) => coordinator._run(() async {
    if (coordinator._generation(entry.file.path) != entry.generation) {
      return _EvictionOutcome.changed;
    }

    try {
      final stat = await entry.file.stat();
      if (stat.size != entry.size || stat.modified != entry.modified) {
        return _EvictionOutcome.changed;
      }
      await _fileOperations.delete(entry.file);
      coordinator._markDeleted(entry.file.path);
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

final class MediaCacheMutationCoordinator {
  Future<void> _tail = Future<void>.value();
  final Map<String, int> _generations = {};
  final Set<String> _activeTemporaryPaths = {};
  int _nextGeneration = 0;

  Future<T> _run<T>(Future<T> Function() action) {
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

  int _generation(String path) => _generations[_pathIdentity(path)] ?? 0;

  void _markDeleted(String path) {
    _generations.remove(_pathIdentity(path));
  }

  void _markChanged(String path) {
    _generations[_pathIdentity(path)] = ++_nextGeneration;
  }

  void _registerTemporary(String path) {
    _activeTemporaryPaths.add(_pathIdentity(path));
  }

  void _unregisterTemporary(String path) {
    _activeTemporaryPaths.remove(_pathIdentity(path));
  }

  bool _isTemporaryActive(String path) {
    final identity = _pathIdentity(path);
    for (final activePath in _activeTemporaryPaths) {
      if (identity == activePath || identity.startsWith('$activePath.')) {
        return true;
      }
    }
    return false;
  }
}
