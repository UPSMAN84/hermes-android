import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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

abstract interface class AtomicStoreFileSystem {
  Future<Uint8List> readBytes(File file, {required int maxBytes});

  Future<void> promote(File temporary, File target);
}

final class IoAtomicStoreFileSystem implements AtomicStoreFileSystem {
  @override
  Future<Uint8List> readBytes(File file, {required int maxBytes}) async {
    final builder = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in file.openRead()) {
      count += chunk.length;
      if (count > maxBytes) {
        throw const FormatException('Record exceeds size limit');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> promote(File temporary, File target) =>
      replaceFileAtomically(temp: temporary, target: target);
}

final class AtomicJsonStore {
  AtomicJsonStore({
    required this.root,
    required this.index,
    this.maxRecordBytes = 5 * 1024 * 1024,
    AtomicStoreFileSystem? fileSystem,
  }) : fileSystem = fileSystem ?? IoAtomicStoreFileSystem();

  final Directory root;
  final ComfyStorageIndex index;
  final int maxRecordBytes;
  final AtomicStoreFileSystem fileSystem;

  Future<T> withRecordLock<T>(File target, Future<T> Function() action) async {
    final key = await _canonicalTargetPath(target);
    return _CanonicalPathLocks.run(key, action);
  }

  Future<T> withRecordTransaction<T>(
    File primaryTarget,
    Future<T> Function(AtomicFileTransaction transaction) action, {
    Future<void> Function()? afterCommit,
  }) async {
    await primaryTarget.parent.create(recursive: true);
    return withRecordLock(primaryTarget, () async {
      final transaction = AtomicFileTransaction._(this);
      try {
        final result = await action(transaction);
        await transaction._commit();
        if (afterCommit != null) await afterCommit();
        await transaction._finalize();
        return result;
      } catch (error, stackTrace) {
        await transaction._rollback();
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        await transaction._cleanup();
      }
    });
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

  Future<Uint8List> _readBytesUnlocked(File target) =>
      fileSystem.readBytes(target, maxBytes: maxRecordBytes);

  Future<void> deleteFile(File target) => withRecordLock(target, () async {
    if (await target.exists()) await target.delete();
  });

  Future<void> _writeBytesUnlocked(File target, List<int> bytes) async {
    final temporary = File('${target.path}.${_uniqueSuffix()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await fileSystem.promote(temporary, target);
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
      await fileSystem.promote(temporary, target);
    } finally {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

final class AtomicFileTransaction {
  AtomicFileTransaction._(this._store);

  final AtomicJsonStore _store;
  final Map<String, _StagedFileMutation> _mutations = {};
  bool _committed = false;
  bool _finalized = false;
  bool _rolledBack = false;

  Future<void> writeJson(File target, Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    await writeBytes(target, bytes);
  }

  Future<void> writeBytes(File target, List<int> bytes) async {
    if (bytes.length > _store.maxRecordBytes) {
      throw const FormatException('Record exceeds size limit');
    }
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.${_uniqueSuffix()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await _stage(target, temporary);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<Map<String, Object?>> readJson(File target) async {
    final decoded = jsonDecode(utf8.decode(await readBytes(target)));
    if (decoded is! Map) {
      throw const FormatException('Record must be a JSON object');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<Uint8List> readBytes(File target) async {
    final key = await _canonicalTargetPath(target);
    final staged = _mutations[key];
    if (staged != null) {
      final temporary = staged.temporary;
      if (temporary == null) {
        throw StoredRecordCorruption('Required record file is missing');
      }
      return _store._readBytesUnlocked(temporary);
    }
    if (!await target.exists()) {
      throw StoredRecordCorruption('Required record file is missing');
    }
    return _store._readBytesUnlocked(target);
  }

  Future<void> copyFile(
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
      await _stage(target, temporary);
    } catch (_) {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> deleteFile(File target) async {
    await _stage(target, null);
  }

  Future<void> _stage(File target, File? temporary) async {
    if (_committed || _finalized || _rolledBack) {
      throw StateError('Transaction is no longer writable');
    }
    final key = await _canonicalTargetPath(target);
    final previous = _mutations.remove(key);
    if (previous?.temporary case final oldTemporary?) {
      if (await oldTemporary.exists()) await oldTemporary.delete();
    }
    _mutations[key] = _StagedFileMutation(target: target, temporary: temporary);
  }

  Future<void> _commit() async {
    if (_committed) throw StateError('Transaction already committed');
    for (final mutation in _mutations.values) {
      if (await mutation.target.exists()) {
        mutation.backup = File(
          '${mutation.target.path}.${_uniqueSuffix()}.transaction-backup',
        );
        await mutation.target.rename(mutation.backup!.path);
        mutation.originalMoved = true;
      }
      final temporary = mutation.temporary;
      if (temporary != null) {
        mutation.promotionAttempted = true;
        await _store.fileSystem.promote(temporary, mutation.target);
      }
    }
    _committed = true;
  }

  Future<void> _rollback() async {
    if (_finalized || _rolledBack) return;
    Object? rollbackError;
    StackTrace? rollbackStackTrace;
    for (final mutation in _mutations.values.toList().reversed) {
      try {
        if (mutation.promotionAttempted && await mutation.target.exists()) {
          await mutation.target.delete();
        }
        final backup = mutation.backup;
        if (mutation.originalMoved && backup != null && await backup.exists()) {
          if (await mutation.target.exists()) await mutation.target.delete();
          await backup.rename(mutation.target.path);
        }
      } catch (error, stackTrace) {
        rollbackError ??= error;
        rollbackStackTrace ??= stackTrace;
      }
    }
    _rolledBack = true;
    if (rollbackError != null) {
      Error.throwWithStackTrace(rollbackError, rollbackStackTrace!);
    }
  }

  Future<void> _finalize() async {
    _finalized = true;
    for (final mutation in _mutations.values) {
      final backup = mutation.backup;
      if (backup != null && await backup.exists()) await backup.delete();
    }
  }

  Future<void> _cleanup() async {
    for (final mutation in _mutations.values) {
      final temporary = mutation.temporary;
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}

final class _StagedFileMutation {
  _StagedFileMutation({required this.target, required this.temporary});

  final File target;
  final File? temporary;
  File? backup;
  bool originalMoved = false;
  bool promotionAttempted = false;
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
  ComfyStorageIndex({
    required this.root,
    this.maxRecordBytes = 5 * 1024 * 1024,
    AtomicStoreFileSystem? fileSystem,
  }) : _indexFile = File(_join(root.path, 'index.json')),
       _mutexFile = File(_join(root.path, '.index-serialization')) {
    _atomic = AtomicJsonStore(
      root: root,
      index: this,
      maxRecordBytes: maxRecordBytes,
      fileSystem: fileSystem,
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

  Future<T> commitRecordMutation<T>({
    required String collection,
    required String id,
    required bool presentAfterCommit,
    required Future<T> Function(Future<void> Function() commitIndex) mutation,
  }) async {
    _validateCollection(collection);
    validateRecordId(id);
    return _atomic.withRecordLock(_mutexFile, () async {
      final current = await _readOrRebuildUnlocked();
      var indexCommitted = false;
      Future<void> commitIndex() async {
        if (indexCommitted) throw StateError('Index already committed');
        final updated = presentAfterCommit
            ? current.withAdded(collection, id)
            : current.withRemoved(collection, id);
        await _atomic.writeJson(_indexFile, updated.toJson());
        indexCommitted = true;
      }

      final result = await mutation(commitIndex);
      if (!indexCommitted) {
        throw StateError('Record mutation did not commit the index');
      }
      return result;
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
    } on Object catch (error) {
      if (!isCorruptRecordError(error)) rethrow;
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
      } on Object catch (error) {
        if (!isCorruptRecordError(error)) rethrow;
        await quarantine(file, collection: directoryName);
      }
    }
    ids.sort();
    return List.unmodifiable(ids);
  }

  Future<String> _decodeWorkflow(File file, String id) async {
    return _atomic.withRecordTransaction(file, (transaction) async {
      final sidecar = await transaction.readJson(file);
      final graph = await transaction.readJson(
        File(_join(file.parent.path, '$id.json')),
      );
      final source = await transaction.readBytes(
        File(_join(file.parent.path, '$id.source.json')),
      );
      final definition = decodeStoredWorkflowDefinition(
        sidecar: sidecar,
        workingGraph: graph,
        sourceBytes: source,
      );
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

ComfyWorkflowDefinition decodeStoredWorkflowDefinition({
  required Map<String, Object?> sidecar,
  required Map<String, Object?> workingGraph,
  required List<int> sourceBytes,
}) {
  final definition = ComfyWorkflowDefinition.fromJson(sidecar);
  if (_canonicalJson(definition.workingGraph) != _canonicalJson(workingGraph)) {
    throw StoredRecordCorruption(
      'Workflow sidecar and working graph do not match',
    );
  }
  final actualSourceHash = sha256.convert(sourceBytes).toString();
  if (definition.sourceHash.toLowerCase() != actualSourceHash) {
    throw StoredRecordCorruption('Workflow source hash does not match');
  }
  return definition;
}

final class StoredRecordCorruption implements Exception {
  const StoredRecordCorruption(this.message);

  final String message;

  @override
  String toString() => 'StoredRecordCorruption: $message';
}

bool isCorruptRecordError(Object error) =>
    error is StoredRecordCorruption ||
    error is FormatException ||
    error is TypeError ||
    error is RangeError;

bool isMissingFileError(Object error) =>
    error is FileSystemException &&
    const {2, 3}.contains(error.osError?.errorCode);

String _canonicalJson(Object? value) => jsonEncode(_canonicalizeJson(value));

Object? _canonicalizeJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalizeJson(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalizeJson).toList();
  return value;
}

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
