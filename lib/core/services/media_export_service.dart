// Share / save-to-gallery for generated media (images and video clips).
// Both bubble types (chat_screen.dart's _ImageBubble/_VideoBubble) and the
// media gallery route through this so the two entry points can't drift.
import 'dart:async';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'media_cache_service.dart';

class MediaExportService {
  MediaExportService({
    Directory? root,
    Future<Directory> Function()? rootProvider,
    MediaDownloadPort? downloadService,
    Future<void> Function(File)? shareFile,
    Future<String?> Function(File, {required bool isVideo})? saveFile,
    this.maxDownloadBytes = defaultMaxDownloadBytes,
  }) : _rootProvider = _resolveRootProvider(root, rootProvider),
       _downloadService = downloadService ?? appMediaDownloadService,
       _shareFile = shareFile ?? share,
       _saveFile = saveFile ?? saveToGallery;

  static const int confirmationBytes = 512 * 1024 * 1024;
  static const int defaultMaxDownloadBytes = 2 * 1024 * 1024 * 1024;

  static final MediaExportService appDefault = MediaExportService(
    rootProvider: getTemporaryDirectory,
    downloadService: appMediaDownloadService,
  );

  static int _destinationSequence = 0;

  final Future<Directory> Function() _rootProvider;
  final MediaDownloadPort _downloadService;
  final Future<void> Function(File) _shareFile;
  final Future<String?> Function(File, {required bool isVideo}) _saveFile;
  final int maxDownloadBytes;
  final MediaDownloadCleanupScope _downloadCleanupScope =
      MediaDownloadCleanupScope();
  final Set<Future<dynamic>> _activeExports = Set<Future<dynamic>>.identity();
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Opens the system share sheet for [file].
  static Future<void> share(File file) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  /// Saves [file] to the device's own Photos/Gallery app -- distinct from
  /// this app's private MediaCacheService disk cache, which the OS gallery
  /// can't see at all. Returns null on success, or a short user-facing
  /// message on failure (permission denied, unsupported format).
  static Future<String?> saveToGallery(
    File file, {
    required bool isVideo,
  }) async {
    try {
      // On API 24-29, gal's putImage/putVideo attempt the write directly and
      // throw if WRITE_EXTERNAL_STORAGE hasn't been granted yet -- unlike
      // hasAccess/requestAccess, they never trigger the OS permission
      // dialog themselves. Without this, a fresh install on those OS
      // versions would report "Photos permission denied" forever with no
      // way to actually grant it. toAlbum: true matches the album: 'Hermes'
      // save below (a plain gallery save needs no prompt on API 29; saving
      // into a named album does). No-ops on API 30+, where hasAccess is
      // unconditionally true and scoped storage handles consent per write.
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) return 'Photos permission denied';
      }
      if (isVideo) {
        await Gal.putVideo(file.path, album: 'Hermes');
      } else {
        await Gal.putImage(file.path, album: 'Hermes');
      }
      return null;
    } on GalException catch (e) {
      switch (e.type) {
        case GalExceptionType.accessDenied:
          return 'Photos permission denied';
        case GalExceptionType.notSupportedFormat:
          return 'Unsupported file format';
        case GalExceptionType.notEnoughSpace:
          return 'Not enough storage space';
        case GalExceptionType.unexpected:
          return 'Save failed: ${e.type}';
      }
    } catch (e) {
      return 'Save failed: $e';
    }
  }

  Future<void> shareRemote(
    Uri uri, {
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) {
    if (_closing) {
      return Future<void>.error(
        StateError('MediaExportService is closing; cannot start sharing.'),
      );
    }
    return _track(
      _shareRemote(
        uri,
        headers: headers,
        confirmAfterHeaders: confirmAfterHeaders,
      ),
    );
  }

  Future<void> _shareRemote(
    Uri uri, {
    required Map<String, String> headers,
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) async {
    final destination = await _destinationFor(uri);
    try {
      final downloaded = await _downloadCleanupScope.download(
        _downloadService,
        uri,
        destination: destination,
        maxBytes: maxDownloadBytes,
        headers: headers,
        confirmAfterHeaders: _confirmation(confirmAfterHeaders),
      );
      await _shareFile(downloaded);
    } finally {
      await _downloadCleanupScope.deleteOrSchedule(destination);
    }
  }

  Future<String?> saveRemote(
    Uri uri, {
    required bool isVideo,
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) {
    if (_closing) {
      return Future<String?>.error(
        StateError('MediaExportService is closing; cannot start saving.'),
      );
    }
    return _track(
      _saveRemote(
        uri,
        isVideo: isVideo,
        headers: headers,
        confirmAfterHeaders: confirmAfterHeaders,
      ),
    );
  }

  Future<String?> _saveRemote(
    Uri uri, {
    required bool isVideo,
    required Map<String, String> headers,
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) async {
    final destination = await _destinationFor(uri);
    try {
      final downloaded = await _downloadCleanupScope.download(
        _downloadService,
        uri,
        destination: destination,
        maxBytes: maxDownloadBytes,
        headers: headers,
        confirmAfterHeaders: _confirmation(confirmAfterHeaders),
      );
      return await _saveFile(downloaded, isVideo: isVideo);
    } finally {
      await _downloadCleanupScope.deleteOrSchedule(destination);
    }
  }

  Future<void> drainCleanup() => _downloadCleanupScope.drainCleanup();

  Future<void> close() {
    final active = _closeFuture;
    if (active != null) return active;

    _closing = true;
    final operation = _close();
    _closeFuture = operation;
    return operation;
  }

  Future<void> _close() async {
    while (_activeExports.isNotEmpty) {
      final active = _activeExports.toList(growable: false);
      await Future.wait<void>(
        active.map((future) => future.then<void>((_) {}, onError: (_) {})),
      );
    }

    for (var pass = 0; pass < 3; pass++) {
      await _downloadCleanupScope.drainCleanup();
      if (!_downloadCleanupScope.hasPendingCleanup) return;
      if (pass < 2) await Future<void>.delayed(Duration.zero);
    }
    throw StateError(
      'MediaExportService still has pending download cleanup after 3 passes.',
    );
  }

  Future<T> _track<T>(Future<T> operation) {
    late final Future<T> tracked;
    tracked = operation.whenComplete(() {
      _activeExports.remove(tracked);
    });
    _activeExports.add(tracked);
    return tracked;
  }

  Future<bool> Function(MediaDownloadInfo) _confirmation(
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  ) {
    return (info) async {
      final declaredBytes = info.declaredBytes;
      if (declaredBytes != null && declaredBytes <= confirmationBytes) {
        return true;
      }
      final confirm = confirmAfterHeaders;
      return confirm != null && await confirm(info);
    };
  }

  Future<File> _destinationFor(Uri uri) async {
    final root = await _rootProvider();
    await root.create(recursive: true);
    final sequence = _destinationSequence++;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final filename = _sanitizedFilename(uri);
    return File(
      '${root.path}${Platform.pathSeparator}${timestamp}_$sequence-$filename',
    );
  }

  static String _sanitizedFilename(Uri uri) {
    final queryFilename = uri.queryParameters['filename'];
    final pathFilename = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final candidate = queryFilename?.isNotEmpty == true
        ? queryFilename!
        : pathFilename.isNotEmpty
        ? pathFilename
        : 'media';
    final sanitized = candidate.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      return 'media';
    }
    return sanitized;
  }

  static Future<Directory> Function() _resolveRootProvider(
    Directory? root,
    Future<Directory> Function()? rootProvider,
  ) {
    if (root != null && rootProvider != null) {
      throw ArgumentError('Provide either root or rootProvider, not both.');
    }
    if (root != null) return () async => root;
    return rootProvider ?? getTemporaryDirectory;
  }
}
