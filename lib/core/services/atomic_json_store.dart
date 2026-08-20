import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/character_generation_context.dart';
import '../models/comfy_workflow.dart';
import '../models/generation_job.dart';
import '../models/media_asset.dart';

abstract interface class RecordStore<T> {
  Future<List<T>> list();
  Future<T?> get(String id);
  Future<void> save(T value);
  Future<void> delete(String id);
}

final class AtomicJsonStore {
  AtomicJsonStore({
    required this.root,
    required this.index,
    this.maxRecordBytes = 5 * 1024 * 1024,
  });

  final Directory root;
  final ComfyStorageIndex index;
  final int maxRecordBytes;

  Future<T> withRecordLock<T>(File target, Future<T> Function() action) async {
    final key = await _canonicalTargetPath(target);
    return _CanonicalPathLocks.run(key, action);
  }

  Future<T> withRecordTransaction<T>(
    File primaryTarget,
    Future<T> Function(AtomicFileTransaction transaction) action,
  ) async {
    await primaryTarget.parent.create(recursive: true);
    return withRecordLock(
      primaryTarget,
      () => action(AtomicFileTransaction._(this)),
    );
  }

  Future<void> writeJson(File target, Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    await writeBytes(target, bytes);
  }

  Future<void> writeBytes(File target, List<int> bytes) async {
    if (bytes.length > maxRecordBytes) {
      throw const FormatException('Record exceeds size limit');
    }
    await target.parent.create(recursive: true);
    await withRecordLock(target, () => _writeBytesUnlocked(target, bytes));
  }

  Future<void> copyFile(
    File source,
    File target, {
    required int maxBytes,
  }) async {
    await target.parent.create(recursive: true);
    await withRecordLock(
      target,
      () => _copyFileUnlocked(source, target, maxBytes: maxBytes),
    );
  }

  Future<Map<String, Object?>> readJson(File target) async {
    final decoded = jsonDecode(utf8.decode(await readBytes(target)));
    if (decoded is! Map) {
      throw const FormatException('Record must be a JSON object');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<Uint8List> readBytes(File target) =>
      withRecordLock(target, () => _readBytesUnlocked(target));

  Future<Uint8List> _readBytesUnlocked(File target) async {
    final builder = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in target.openRead()) {
      count += chunk.length;
      if (count > maxRecordBytes) {
        throw const FormatException('Record exceeds size limit');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> deleteFile(File target) => withRecordLock(target, () async {
    if (await target.exists()) await target.delete();
  });

  Future<void> _writeBytesUnlocked(File target, List<int> bytes) async {
    final temporary = File('${target.path}.${_uniqueSuffix()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await replaceFileAtomically(temp: temporary, target: target);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _copyFileUnlocked(
    File source,
    File target, {
    required int maxBytes,
  }) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.${_uniqueSuffix()}.tmp');
    IOSink? sink;
    try {
      sink = temporary.openWrite();
      var count = 0;
      await for (final chunk in source.openRead()) {
        count += chunk.length;
        if (count > maxBytes) {
          throw const FormatException('File exceeds size limit');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await replaceFileAtomically(temp: temporary, target: target);
    } finally {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

final class AtomicFileTransaction {
  AtomicFileTransaction._(this._store);

  final AtomicJsonStore _store;

  Future<void> writeJson(File target, Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    await writeBytes(target, bytes);
  }

  Future<void> writeBytes(File target, List<int> bytes) async {
    if (bytes.length > _store.maxRecordBytes) {
      throw const FormatException('Record exceeds size limit');
    }
    await target.parent.create(recursive: true);
    await _store._writeBytesUnlocked(target, bytes);
  }

  Future<Map<String, Object?>> readJson(File target) async {
    final decoded = jsonDecode(
      utf8.decode(await _store._readBytesUnlocked(target)),
    );
    if (decoded is! Map) {
      throw const FormatException('Record must be a JSON object');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<Uint8List> readBytes(File target) => _store._readBytesUnlocked(target);

  Future<void> copyFile(File source, File target, {required int maxBytes}) =>
      _store._copyFileUnlocked(source, target, maxBytes: maxBytes);

  Future<void> deleteFile(File target) async {
    if (await target.exists()) await target.delete();
  }
}

Future<void> replaceFileAtomically({
  required File temp,
  required File target,
}) async {
  try {
    await temp.rename(target.path);
    return;
  } on FileSystemException {
    if (!await target.exists()) rethrow;
  }

  final backup = File('${target.path}.${_uniqueSuffix()}.replace-backup');
  var targetMoved = false;
  try {
    await target.rename(backup.path);
    targetMoved = true;
    await temp.rename(target.path);
  } catch (_) {
    if (targetMoved && !await target.exists() && await backup.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  } finally {
    if (await backup.exists() && await target.exists()) {
      await backup.delete();
    }
  }
}

final class ComfyStorageIndex {
  ComfyStorageIndex({required this.root, this.maxRecordBytes = 5 * 1024 * 1024})
    : _indexFile = File(_join(root.path, 'index.json')),
      _mutexFile = File(_join(root.path, '.index-serialization')) {
    _atomic = AtomicJsonStore(
      root: root,
      index: this,
      maxRecordBytes: maxRecordBytes,
    );
  }

  static const schemaVersion = 1;
  static const workflows = 'workflows';
  static const jobs = 'jobs';
  static const media = 'media';
  static const contexts = 'contexts';

  final Directory root;
  final int maxRecordBytes;
  final File _indexFile;
  final File _mutexFile;
  late final AtomicJsonStore _atomic;

  Future<ComfyIndexSnapshot> read() =>
      _atomic.withRecordLock(_mutexFile, _readOrRebuildUnlocked);

  Future<void> updateAfterRecordWrite({
    required String collection,
    required String id,
  }) async {
    _validateCollection(collection);
    validateRecordId(id);
    await _atomic.withRecordLock(_mutexFile, () async {
      final current = await _readOrRebuildUnlocked();
      await _atomic.writeJson(
        _indexFile,
        current.withAdded(collection, id).toJson(),
      );
    });
  }

  Future<void> removeAfterRecordDelete({
    required String collection,
    required String id,
  }) async {
    _validateCollection(collection);
    validateRecordId(id);
    await _atomic.withRecordLock(_mutexFile, () async {
      final current = await _readOrRebuildUnlocked();
      await _atomic.writeJson(
        _indexFile,
        current.withRemoved(collection, id).toJson(),
      );
    });
  }

  Future<ComfyIndexSnapshot> rebuild() =>
      _atomic.withRecordLock(_mutexFile, _rebuildUnlocked);

  Future<File?> quarantine(File record, {required String collection}) async {
    _validateQuarantineCollection(collection);
    if (!await record.exists()) return null;
    final directory = Directory(_join(root.path, 'quarantine'));
    await directory.create(recursive: true);
    final name = _fileName(record);
    final target = File(
      _join(directory.path, '$collection-$name.${_uniqueSuffix()}.corrupt'),
    );
    return _atomic.withRecordLock(record, () async {
      if (!await record.exists()) return null;
      return record.rename(target.path);
    });
  }

  Future<ComfyIndexSnapshot> _readOrRebuildUnlocked() async {
    if (!await _indexFile.exists()) return _rebuildUnlocked();
    try {
      return ComfyIndexSnapshot.fromJson(await _atomic.readJson(_indexFile));
    } on Object {
      await quarantine(_indexFile, collection: 'index');
      return _rebuildUnlocked();
    }
  }

  Future<ComfyIndexSnapshot> _rebuildUnlocked() async {
    final snapshot = ComfyIndexSnapshot(
      schemaVersion: schemaVersion,
      workflowIds: await _scan(
        directoryName: workflows,
        suffix: '.hermes.json',
        decode: _decodeWorkflow,
      ),
      jobIds: await _scan(
        directoryName: jobs,
        suffix: '.json',
        decode: _decodeJob,
      ),
      mediaIds: await _scan(
        directoryName: media,
        suffix: '.json',
        decode: _decodeMedia,
      ),
      contextIds: await _scan(
        directoryName: 'character-contexts',
        suffix: '.json',
        decode: _decodeContext,
      ),
    );
    await _atomic.writeJson(_indexFile, snapshot.toJson());
    return snapshot;
  }

  Future<List<String>> _scan({
    required String directoryName,
    required String suffix,
    required Future<String> Function(File file, String fileId) decode,
  }) async {
    final directory = Directory(_join(root.path, directoryName));
    if (!await directory.exists()) return const [];
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith(suffix)) files.add(entity);
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    final ids = <String>[];
    for (final file in files) {
      final name = _fileName(file);
      final fileId = name.substring(0, name.length - suffix.length);
      try {
        validateRecordId(fileId);
        final decodedId = await decode(file, fileId);
        validateRecordId(decodedId);
        if (decodedId != fileId) {
          throw const FormatException('Record ID does not match its filename');
        }
        ids.add(decodedId);
      } on Object {
        await quarantine(file, collection: directoryName);
      }
    }
    ids.sort();
    return List.unmodifiable(ids);
  }

  Future<String> _decodeWorkflow(File file, String id) async {
    return _atomic.withRecordTransaction(file, (transaction) async {
      final sidecar = await transaction.readJson(file);
      await transaction.readJson(File(_join(file.parent.path, '$id.json')));
      await transaction.readBytes(
        File(_join(file.parent.path, '$id.source.json')),
      );
      final definition = ComfyWorkflowDefinition.fromJson(sidecar);
      return definition.id;
    });
  }

  Future<String> _decodeJob(File file, String _) async =>
      GenerationJob.fromJson(await _atomic.readJson(file)).localId;

  Future<String> _decodeMedia(File file, String _) async {
    return decodeStoredMediaAsset(await _atomic.readJson(file)).id;
  }

  Future<String> _decodeContext(File file, String id) async {
    return _atomic.withRecordTransaction(file, (transaction) async {
      final context = CharacterGenerationContext.fromJson(
        await transaction.readJson(file),
      );
      final reference = context.referenceImagePath;
      if (reference != null) {
        final expected = File(
          _join(root.path, 'character-contexts', id, 'reference-image'),
        );
        if (!_sameAbsolutePath(File(reference), expected) ||
            !await expected.exists()) {
          throw const FormatException('Unsafe character reference image path');
        }
      }
      return context.sessionId;
    });
  }
}

final class ComfyIndexSnapshot {
  ComfyIndexSnapshot({
    required this.schemaVersion,
    required List<String> workflowIds,
    required List<String> jobIds,
    required List<String> mediaIds,
    required List<String> contextIds,
  }) : workflowIds = _sortedUniqueIds(workflowIds),
       jobIds = _sortedUniqueIds(jobIds),
       mediaIds = _sortedUniqueIds(mediaIds),
       contextIds = _sortedUniqueIds(contextIds);

  factory ComfyIndexSnapshot.empty() => ComfyIndexSnapshot(
    schemaVersion: ComfyStorageIndex.schemaVersion,
    workflowIds: const [],
    jobIds: const [],
    mediaIds: const [],
    contextIds: const [],
  );

  factory ComfyIndexSnapshot.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != ComfyStorageIndex.schemaVersion) {
      throw const FormatException('Unsupported storage index schema');
    }
    return ComfyIndexSnapshot(
      schemaVersion: ComfyStorageIndex.schemaVersion,
      workflowIds: _idList(json['workflowIds'], 'workflowIds'),
      jobIds: _idList(json['jobIds'], 'jobIds'),
      mediaIds: _idList(json['mediaIds'], 'mediaIds'),
      contextIds: _idList(json['contextIds'], 'contextIds'),
    );
  }

  final int schemaVersion;
  final List<String> workflowIds;
  final List<String> jobIds;
  final List<String> mediaIds;
  final List<String> contextIds;

  List<String> idsFor(String collection) => switch (collection) {
    ComfyStorageIndex.workflows => workflowIds,
    ComfyStorageIndex.jobs => jobIds,
    ComfyStorageIndex.media => mediaIds,
    ComfyStorageIndex.contexts => contextIds,
    _ => throw ArgumentError.value(collection, 'collection'),
  };

  ComfyIndexSnapshot withAdded(String collection, String id) =>
      _replace(collection, {...idsFor(collection), id}.toList());

  ComfyIndexSnapshot withRemoved(String collection, String id) => _replace(
    collection,
    idsFor(collection).where((value) => value != id).toList(),
  );

  ComfyIndexSnapshot _replace(String collection, List<String> ids) =>
      ComfyIndexSnapshot(
        schemaVersion: schemaVersion,
        workflowIds: collection == ComfyStorageIndex.workflows
            ? ids
            : workflowIds,
        jobIds: collection == ComfyStorageIndex.jobs ? ids : jobIds,
        mediaIds: collection == ComfyStorageIndex.media ? ids : mediaIds,
        contextIds: collection == ComfyStorageIndex.contexts ? ids : contextIds,
      );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'workflowIds': workflowIds,
    'jobIds': jobIds,
    'mediaIds': mediaIds,
    'contextIds': contextIds,
  };
}

final class StoreRebuildResult<T> {
  const StoreRebuildResult({required this.snapshot, required this.records});

  final ComfyIndexSnapshot snapshot;
  final List<T> records;
}

void validateRecordId(String id) {
  final windowsBase = id.split('.').first.toUpperCase();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(id) ||
      id == '.' ||
      id == '..' ||
      id.endsWith('.') ||
      id.contains('..') ||
      const {'CON', 'PRN', 'AUX', 'NUL'}.contains(windowsBase) ||
      RegExp(r'^(COM|LPT)[1-9]$').hasMatch(windowsBase)) {
    throw const FormatException('Unsafe record ID');
  }
}

MediaAsset decodeStoredMediaAsset(Map<String, Object?> json) {
  final filename = json['filename'];
  final subfolder = json['subfolder'] ?? '';
  final type = json['type'] ?? 'output';
  if (filename is! String || subfolder is! String || type is! String) {
    throw const FormatException('Invalid ComfyUI output reference fields');
  }
  ComfyOutputRef(filename: filename, subfolder: subfolder, type: type);
  final asset = MediaAsset.fromJson(json);
  asset.outputRef;
  return asset;
}

bool isCorruptRecordError(Object error) =>
    error is FormatException || error is TypeError || error is RangeError;

String _join(String first, String second, [String? third, String? fourth]) =>
    [first, second, ?third, ?fourth].join(Platform.pathSeparator);

String _fileName(File file) => file.uri.pathSegments.last;

String _uniqueSuffix() =>
    '$pid-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';

Future<String> _canonicalTargetPath(File target) async {
  String parent;
  try {
    parent = await target.parent.resolveSymbolicLinks();
  } on FileSystemException {
    parent = target.parent.absolute.path;
  }
  final path = _join(parent, _fileName(target));
  return Platform.isWindows ? path.toLowerCase() : path;
}

bool _sameAbsolutePath(File left, File right) {
  final leftPath = left.absolute.path;
  final rightPath = right.absolute.path;
  return Platform.isWindows
      ? leftPath.toLowerCase() == rightPath.toLowerCase()
      : leftPath == rightPath;
}

List<String> _idList(Object? raw, String key) {
  if (raw is! List || raw.any((value) => value is! String)) {
    throw FormatException('$key must contain only record IDs');
  }
  return raw.cast<String>();
}

List<String> _sortedUniqueIds(Iterable<String> values) {
  final result = values.toSet().toList()..sort();
  for (final value in result) {
    validateRecordId(value);
  }
  return List.unmodifiable(result);
}

void _validateCollection(String collection) {
  if (!const {
    ComfyStorageIndex.workflows,
    ComfyStorageIndex.jobs,
    ComfyStorageIndex.media,
    ComfyStorageIndex.contexts,
  }.contains(collection)) {
    throw ArgumentError.value(collection, 'collection');
  }
}

void _validateQuarantineCollection(String collection) {
  if (!const {
    'index',
    'workflows',
    'jobs',
    'media',
    'character-contexts',
  }.contains(collection)) {
    throw ArgumentError.value(collection, 'collection');
  }
}

final class _CanonicalPathLocks {
  static final Map<String, Completer<void>> _tails = {};

  static Future<T> run<T>(String key, Future<T> Function() action) async {
    final previous = _tails[key]?.future;
    final current = Completer<void>();
    _tails[key] = current;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      current.complete();
      if (identical(_tails[key], current)) _tails.remove(key);
    }
  }
}
