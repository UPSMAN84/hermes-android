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

  Future<void> delete(File file);
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

  @override
  Future<void> delete(File file) => file.delete();
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
    await _recoverPendingTransactions();
    return _withRecordLockWithoutRecovery(target, action);
  }

  Future<T> _withRecordLockWithoutRecovery<T>(
    File target,
    Future<T> Function() action,
  ) async {
    final key = await _canonicalTargetPath(target);
    return _CanonicalPathLocks.run(key, action);
  }

  Future<T> withRecordTransaction<T>(
    File primaryTarget,
    Future<T> Function(AtomicFileTransaction transaction) action,
  ) async {
    await primaryTarget.parent.create(recursive: true);
    return _withDurableRootLock(() async {
      await _recoverPendingTransactionsUnlocked();
      return _withRecordLockWithoutRecovery(primaryTarget, () async {
        final transaction = AtomicFileTransaction._(this);
        try {
          final result = await action(transaction);
          await transaction._commitDurably();
          await transaction._finalizeCommittedBestEffort();
          return result;
        } catch (error, stackTrace) {
          if (!transaction.isDurablyCommitted) {
            await transaction._rollback();
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      });
    });
  }

  Future<void> _recoverPendingTransactions() =>
      _withDurableRootLock(_recoverPendingTransactionsUnlocked);

  Future<void> recoverPendingTransactions() => _recoverPendingTransactions();

  Future<void> _recoverPendingTransactionsUnlocked() =>
      _DurableTransactionRecovery(root: root, fileSystem: fileSystem).recover();

  Future<T> _withDurableRootLock<T>(Future<T> Function() action) async {
    final lockTarget = File(_join(root.path, '.transaction-serialization'));
    final key = await _canonicalTargetPath(lockTarget);
    return _CanonicalPathLocks.run(key, action);
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
  AtomicFileTransaction._(this._store) : _transactionId = _uniqueSuffix();

  final AtomicJsonStore _store;
  final String _transactionId;
  final Map<String, _StagedFileMutation> _mutations = {};
  bool _committed = false;
  bool _rolledBack = false;
  bool _durablyCommitted = false;
  File? _journal;
  File? _commitMarker;

  bool get isDurablyCommitted => _durablyCommitted;

  Future<void> writeJson(File target, Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    await writeBytes(target, bytes);
  }

  Future<void> writeBytes(File target, List<int> bytes) async {
    if (bytes.length > _store.maxRecordBytes) {
      throw const FormatException('Record exceeds size limit');
    }
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.${_uniqueSuffix()}.transaction-temp',
    );
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

  Future<String> copyFile(
    File source,
    File target, {
    required int maxBytes,
  }) async {
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.${_uniqueSuffix()}.transaction-temp',
    );
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
      final digest = await _sha256Bounded(temporary, maxBytes: maxBytes);
      await _stage(target, temporary);
      return digest;
    } catch (_) {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> deleteFile(File target) async {
    await _stage(target, null);
  }

  Future<String> sha256File(File target, {required int maxBytes}) async {
    final key = await _canonicalTargetPath(target);
    final staged = _mutations[key];
    final file = staged?.temporary ?? target;
    if (staged != null && staged.temporary == null || !await file.exists()) {
      throw StoredRecordCorruption('Required record file is missing');
    }
    return _sha256Bounded(file, maxBytes: maxBytes);
  }

  Future<void> _stage(File target, File? temporary) async {
    if (_committed || _durablyCommitted || _rolledBack) {
      throw StateError('Transaction is no longer writable');
    }
    final key = await _canonicalTargetPath(target);
    final previous = _mutations.remove(key);
    if (previous?.temporary case final oldTemporary?) {
      if (await oldTemporary.exists()) await oldTemporary.delete();
    }
    _mutations[key] = _StagedFileMutation(target: target, temporary: temporary);
  }

  Future<void> _commitDurably() async {
    if (_committed) throw StateError('Transaction already committed');
    if (_mutations.isEmpty) {
      _committed = true;
      _durablyCommitted = true;
      return;
    }
    await _prepareJournal();
    for (final mutation in _mutations.values) {
      if (mutation.hadOriginal) {
        await mutation.target.rename(mutation.backup!.path);
      }
      final temporary = mutation.temporary;
      if (temporary != null) {
        mutation.promotionAttempted = true;
        await _store.fileSystem.promote(temporary, mutation.target);
      }
    }
    _committed = true;
    await _writeCommitMarker();
    _durablyCommitted = true;
  }

  Future<void> _rollback() async {
    if (_durablyCommitted || _rolledBack) return;
    Object? rollbackError;
    StackTrace? rollbackStackTrace;
    for (final mutation in _mutations.values.toList().reversed) {
      try {
        if (mutation.promotionAttempted && await mutation.target.exists()) {
          await _store.fileSystem.delete(mutation.target);
        }
        final backup = mutation.backup;
        if (mutation.hadOriginal && backup != null && await backup.exists()) {
          if (await mutation.target.exists()) {
            await _store.fileSystem.delete(mutation.target);
          }
          await backup.rename(mutation.target.path);
        }
        final temporary = mutation.temporary;
        if (temporary != null && await temporary.exists()) {
          await _store.fileSystem.delete(temporary);
        }
      } catch (error, stackTrace) {
        rollbackError ??= error;
        rollbackStackTrace ??= stackTrace;
      }
    }
    _rolledBack = true;
    if (rollbackError == null) {
      await _deleteJournalFiles();
    }
    if (rollbackError != null) {
      Error.throwWithStackTrace(rollbackError, rollbackStackTrace!);
    }
  }

  Future<void> _prepareJournal() async {
    final directory = Directory(_join(_store.root.path, '.transactions'));
    await directory.create(recursive: true);
    for (final mutation in _mutations.values) {
      mutation.hadOriginal = await mutation.target.exists();
      if (mutation.hadOriginal) {
        mutation.backup = File(
          '${mutation.target.path}.$_transactionId.transaction-backup',
        );
      }
    }
    final journal = File(_join(directory.path, '$_transactionId.journal.json'));
    _journal = journal;
    _commitMarker = File('${journal.path}.committed');
    await _writeNewDurableFile(
      journal,
      utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'transactionId': _transactionId,
          'entries': [
            for (final mutation in _mutations.values)
              {
                'target': _relativeStoragePath(_store.root, mutation.target),
                'temporary': mutation.temporary == null
                    ? null
                    : _relativeStoragePath(_store.root, mutation.temporary!),
                'backup': mutation.backup == null
                    ? null
                    : _relativeStoragePath(_store.root, mutation.backup!),
                'hadOriginal': mutation.hadOriginal,
              },
          ],
        }),
      ),
    );
  }

  Future<void> _writeCommitMarker() async {
    await _writeNewDurableFile(_commitMarker!, utf8.encode(_transactionId));
  }

  Future<void> _finalizeCommittedBestEffort() async {
    if (!_durablyCommitted || _journal == null) return;
    var clean = true;
    for (final mutation in _mutations.values) {
      final temporary = mutation.temporary;
      if (temporary != null && await temporary.exists()) {
        try {
          await _store.fileSystem.delete(temporary);
        } on FileSystemException {
          clean = false;
        }
      }
      final backup = mutation.backup;
      if (backup != null && await backup.exists()) {
        try {
          await _store.fileSystem.delete(backup);
        } on FileSystemException {
          clean = false;
        }
      }
    }
    if (clean) {
      try {
        await _deleteJournalFiles();
      } on FileSystemException {
        // The durable committed marker makes later cleanup idempotent.
      }
    }
  }

  Future<void> _deleteJournalFiles() async {
    final journal = _journal;
    if (journal != null && await journal.exists()) {
      await _store.fileSystem.delete(journal);
    }
    final marker = _commitMarker;
    if (marker != null && await marker.exists()) {
      await _store.fileSystem.delete(marker);
    }
  }
}

final class _StagedFileMutation {
  _StagedFileMutation({required this.target, required this.temporary});

  final File target;
  final File? temporary;
  File? backup;
  bool hadOriginal = false;
  bool promotionAttempted = false;
}

Future<String> _sha256Bounded(File file, {required int maxBytes}) async {
  var count = 0;
  final digest = await sha256
      .bind(
        file.openRead().map((chunk) {
          count += chunk.length;
          if (count > maxBytes) {
            throw const FormatException('File exceeds size limit');
          }
          return chunk;
        }),
      )
      .first;
  return digest.toString();
}

Future<void> _writeNewDurableFile(File target, List<int> bytes) async {
  final writing = File('${target.path}.writing');
  await target.parent.create(recursive: true);
  try {
    await writing.writeAsBytes(bytes, flush: true);
    await writing.rename(target.path);
  } finally {
    if (await writing.exists()) await writing.delete();
  }
}

final class _DurableTransactionRecovery {
  const _DurableTransactionRecovery({
    required this.root,
    required this.fileSystem,
  });

  static const _maxJournalBytes = 1024 * 1024;

  final Directory root;
  final AtomicStoreFileSystem fileSystem;

  Future<void> recover() async {
    final directory = Directory(_join(root.path, '.transactions'));
    if (!await directory.exists()) return;
    final journals = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.journal.json')) {
        journals.add(entity);
      }
    }
    journals.sort((left, right) => left.path.compareTo(right.path));
    for (final journalFile in journals) {
      final journal = await _readJournal(journalFile);
      final marker = File('${journalFile.path}.committed');
      if (await marker.exists()) {
        await _cleanupCommitted(journal, marker);
      } else {
        await _restoreUncommitted(journal);
      }
    }
    await _cleanupOrphanControlFiles(directory);
  }

  Future<_RecoveredTransactionJournal> _readJournal(File file) async {
    final decoded = jsonDecode(
      utf8.decode(await fileSystem.readBytes(file, maxBytes: _maxJournalBytes)),
    );
    if (decoded is! Map) {
      throw const FormatException('Transaction journal must be an object');
    }
    return _RecoveredTransactionJournal.decode(
      root: root,
      file: file,
      json: decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  Future<void> _restoreUncommitted(_RecoveredTransactionJournal journal) async {
    for (final entry in journal.entries.reversed) {
      final backup = entry.backup;
      if (entry.hadOriginal && backup != null && await backup.exists()) {
        if (await entry.target.exists()) {
          await fileSystem.delete(entry.target);
        }
        await backup.rename(entry.target.path);
      } else if (!entry.hadOriginal && await entry.target.exists()) {
        await fileSystem.delete(entry.target);
      }
      final temporary = entry.temporary;
      if (temporary != null && await temporary.exists()) {
        await fileSystem.delete(temporary);
      }
    }
    if (await journal.file.exists()) await fileSystem.delete(journal.file);
  }

  Future<void> _cleanupCommitted(
    _RecoveredTransactionJournal journal,
    File marker,
  ) async {
    var clean = true;
    for (final entry in journal.entries) {
      for (final debris in [entry.temporary, entry.backup]) {
        if (debris == null || !await debris.exists()) continue;
        try {
          await fileSystem.delete(debris);
        } on FileSystemException {
          clean = false;
        }
      }
    }
    if (!clean) return;
    try {
      if (await journal.file.exists()) await fileSystem.delete(journal.file);
      if (await marker.exists()) await fileSystem.delete(marker);
    } on FileSystemException {
      // Targets are already durably committed; later recovery retries cleanup.
    }
  }

  Future<void> _cleanupOrphanControlFiles(Directory directory) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final isWriting = entity.path.endsWith('.writing');
      final isOrphanMarker =
          entity.path.endsWith('.journal.json.committed') &&
          !await File(
            entity.path.substring(0, entity.path.length - '.committed'.length),
          ).exists();
      if (!isWriting && !isOrphanMarker) continue;
      try {
        await fileSystem.delete(entity);
      } on FileSystemException {
        // Safe control-file cleanup is retried by the next operation.
      }
    }
  }
}

final class _RecoveredTransactionJournal {
  const _RecoveredTransactionJournal({
    required this.file,
    required this.entries,
  });

  static Future<_RecoveredTransactionJournal> decode({
    required Directory root,
    required File file,
    required Map<String, Object?> json,
  }) async {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported transaction journal schema');
    }
    final transactionId = json['transactionId'];
    if (transactionId is! String) {
      throw const FormatException('Transaction journal ID is required');
    }
    validateRecordId(transactionId);
    if (_fileName(file) != '$transactionId.journal.json') {
      throw const FormatException('Transaction journal ID mismatch');
    }
    final rawEntries = json['entries'];
    if (rawEntries is! List || rawEntries.isEmpty) {
      throw const FormatException('Transaction journal entries are required');
    }
    final entries = <_RecoveredTransactionEntry>[];
    for (final raw in rawEntries) {
      if (raw is! Map) {
        throw const FormatException('Invalid transaction journal entry');
      }
      final entry = raw.map((key, value) => MapEntry(key.toString(), value));
      final hadOriginal = entry['hadOriginal'];
      if (hadOriginal is! bool) {
        throw const FormatException('Invalid transaction backup state');
      }
      final target = await _resolveStoragePath(root, entry['target']);
      final temporary = await _resolveOptionalStoragePath(
        root,
        entry['temporary'],
      );
      final backup = await _resolveOptionalStoragePath(root, entry['backup']);
      if (hadOriginal && backup == null) {
        throw const FormatException('Missing transaction backup mapping');
      }
      if (temporary != null &&
          !_isTransactionSibling(
            target,
            temporary,
            suffix: '.transaction-temp',
          )) {
        throw const FormatException('Unsafe transaction temp mapping');
      }
      if (backup != null &&
          !_isTransactionSibling(
            target,
            backup,
            suffix: '.transaction-backup',
          )) {
        throw const FormatException('Unsafe transaction backup mapping');
      }
      entries.add(
        _RecoveredTransactionEntry(
          target: target,
          temporary: temporary,
          backup: backup,
          hadOriginal: hadOriginal,
        ),
      );
    }
    return _RecoveredTransactionJournal(file: file, entries: entries);
  }

  final File file;
  final List<_RecoveredTransactionEntry> entries;
}

final class _RecoveredTransactionEntry {
  const _RecoveredTransactionEntry({
    required this.target,
    required this.temporary,
    required this.backup,
    required this.hadOriginal,
  });

  final File target;
  final File? temporary;
  final File? backup;
  final bool hadOriginal;
}

String _relativeStoragePath(Directory root, File file) {
  final rootPath = root.absolute.path;
  final filePath = file.absolute.path;
  final comparableRoot = _caseInsensitivePaths
      ? rootPath.toLowerCase()
      : rootPath;
  final comparableFile = _caseInsensitivePaths
      ? filePath.toLowerCase()
      : filePath;
  final prefix = '$comparableRoot${Platform.pathSeparator}';
  if (!comparableFile.startsWith(prefix)) {
    throw const FormatException('Transaction path escapes storage root');
  }
  return filePath
      .substring(rootPath.length + 1)
      .replaceAll(Platform.pathSeparator, '/');
}

Future<File?> _resolveOptionalStoragePath(Directory root, Object? raw) async {
  if (raw == null) return null;
  return _resolveStoragePath(root, raw);
}

Future<File> _resolveStoragePath(Directory root, Object? raw) async {
  if (raw is! String ||
      raw.isEmpty ||
      raw.startsWith('/') ||
      raw.startsWith(r'\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
    throw const FormatException('Unsafe transaction path');
  }
  final parts = raw.replaceAll(r'\', '/').split('/');
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const FormatException('Unsafe transaction path');
  }
  final controlSegment = _caseInsensitivePaths
      ? parts.first.toLowerCase()
      : parts.first;
  if (controlSegment == '.transactions') {
    throw const FormatException('Transaction journal cannot target itself');
  }
  final file = File(
    [root.absolute.path, ...parts].join(Platform.pathSeparator),
  );
  _relativeStoragePath(root, file);
  final resolvedRoot = await root.resolveSymbolicLinks();
  final resolvedParent = await _resolveExistingAncestors(file.parent);
  final resolvedFile = File(
    _join(resolvedParent, _fileName(file)),
  ).absolute.path;
  final comparableRoot = _caseInsensitivePaths
      ? resolvedRoot.toLowerCase()
      : resolvedRoot;
  final comparableFile = _caseInsensitivePaths
      ? resolvedFile.toLowerCase()
      : resolvedFile;
  if (!comparableFile.startsWith('$comparableRoot${Platform.pathSeparator}')) {
    throw const FormatException('Transaction path escapes storage root');
  }
  return file;
}

Future<String> _resolveExistingAncestors(Directory directory) async {
  var current = directory.absolute;
  final unresolvedSegments = <String>[];
  while (!await current.exists()) {
    final parent = current.parent.absolute;
    if (_samePath(parent.path, current.path)) {
      throw const FormatException('Transaction path has no existing ancestor');
    }
    unresolvedSegments.insert(0, _fileName(File(current.path)));
    current = parent;
  }
  var resolved = await current.resolveSymbolicLinks();
  for (final segment in unresolvedSegments) {
    resolved = _join(resolved, segment);
  }
  return Directory(resolved).absolute.path;
}

bool _samePath(String left, String right) => _caseInsensitivePaths
    ? left.toLowerCase() == right.toLowerCase()
    : left == right;

bool _isTransactionSibling(
  File target,
  File candidate, {
  required String suffix,
}) {
  final targetParent = target.parent.absolute.path;
  final candidateParent = candidate.parent.absolute.path;
  final comparableTargetParent = _caseInsensitivePaths
      ? targetParent.toLowerCase()
      : targetParent;
  final comparableCandidateParent = _caseInsensitivePaths
      ? candidateParent.toLowerCase()
      : candidateParent;
  final targetName = _caseInsensitivePaths
      ? _fileName(target).toLowerCase()
      : _fileName(target);
  final candidateName = _caseInsensitivePaths
      ? _fileName(candidate).toLowerCase()
      : _fileName(candidate);
  final comparableSuffix = _caseInsensitivePaths
      ? suffix.toLowerCase()
      : suffix;
  final sameParent = comparableTargetParent == comparableCandidateParent;
  return sameParent &&
      candidateName.startsWith('$targetName.') &&
      candidateName.endsWith(comparableSuffix);
}

bool get _caseInsensitivePaths => Platform.isWindows || Platform.isMacOS;

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
    this.maxReferenceImageBytes = 25 * 1024 * 1024,
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
  int maxReferenceImageBytes;
  final File _indexFile;
  final File _mutexFile;
  late final AtomicJsonStore _atomic;

  void configureReferenceImageLimit(int maxBytes) {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'Must be positive');
    }
    maxReferenceImageBytes = maxBytes;
  }

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
    required Future<T> Function(
      Future<void> Function(AtomicFileTransaction transaction) stageIndex,
    )
    mutation,
  }) async {
    _validateCollection(collection);
    validateRecordId(id);
    return _atomic.withRecordLock(_mutexFile, () async {
      final current = await _readOrRebuildUnlocked();
      var indexStaged = false;
      Future<void> stageIndex(AtomicFileTransaction transaction) async {
        if (indexStaged) throw StateError('Index already staged');
        final updated = presentAfterCommit
            ? current.withAdded(collection, id)
            : current.withRemoved(collection, id);
        await transaction.writeJson(_indexFile, updated.toJson());
        indexStaged = true;
      }

      final result = await mutation(stageIndex);
      if (!indexStaged) {
        throw StateError('Record mutation did not stage the index');
      }
      return result;
    });
  }

  Future<T> migrateRecordIfNeeded<T>({
    required String collection,
    required String id,
    required Future<T> Function(
      Future<void> Function(AtomicFileTransaction transaction) stageIndex,
    )
    migration,
  }) async {
    _validateCollection(collection);
    validateRecordId(id);
    return _atomic.withRecordLock(_mutexFile, () async {
      final current = await _readOrRebuildUnlocked();
      var indexStaged = false;
      Future<void> stageIndex(AtomicFileTransaction transaction) async {
        if (indexStaged) throw StateError('Index already staged');
        await transaction.writeJson(
          _indexFile,
          current.withAdded(collection, id).toJson(),
        );
        indexStaged = true;
      }

      return migration(stageIndex);
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
      final json = await transaction.readJson(file);
      final context = await decodeStoredCharacterContext(
        json: json,
        id: id,
        root: root,
        transaction: transaction,
        maxReferenceImageBytes: maxReferenceImageBytes,
        migrateMissingHash: (hash) => transaction.writeJson(file, {
          ...json,
          referenceImageSha256Key: hash,
        }),
      );
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

const referenceImageSha256Key = 'referenceImageSha256';

Future<CharacterGenerationContext> decodeStoredCharacterContext({
  required Map<String, Object?> json,
  required String id,
  required Directory root,
  required AtomicFileTransaction transaction,
  required int maxReferenceImageBytes,
  Future<void> Function(String hash)? migrateMissingHash,
}) async {
  final context = CharacterGenerationContext.fromJson(json);
  final reference = context.referenceImagePath;
  final storedHash = json[referenceImageSha256Key];
  if (reference == null) {
    if (storedHash != null) {
      throw StoredRecordCorruption(
        'Character image hash exists without a reference image',
      );
    }
    return context;
  }
  final expected = File(
    _join(root.path, 'character-contexts', id, 'reference-image'),
  );
  if (!_sameAbsolutePath(File(reference), expected)) {
    throw const FormatException('Unsafe character reference image path');
  }
  final String? normalizedStoredHash;
  if (storedHash == null) {
    normalizedStoredHash = null;
  } else if (storedHash is String &&
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(storedHash)) {
    normalizedStoredHash = storedHash.toLowerCase();
  } else {
    throw StoredRecordCorruption('Character reference image hash is missing');
  }
  final actualHash = await transaction.sha256File(
    expected,
    maxBytes: maxReferenceImageBytes,
  );
  if (normalizedStoredHash == null) {
    final migrate = migrateMissingHash;
    if (migrate == null) {
      throw StoredRecordCorruption('Character reference image hash is missing');
    }
    await migrate(actualHash);
    return context;
  }
  if (actualHash != normalizedStoredHash) {
    throw StoredRecordCorruption('Character reference image hash mismatch');
  }
  return context;
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
