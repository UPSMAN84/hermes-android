import 'dart:io';

import '../models/generation_job.dart';
import 'atomic_json_store.dart';

final class GenerationJobStore implements RecordStore<GenerationJob> {
  GenerationJobStore({
    required this.root,
    ComfyStorageIndex? index,
    this.maxRecordBytes = 5 * 1024 * 1024,
    AtomicStoreFileSystem? fileSystem,
  }) {
    storageIndex =
        index ??
        ComfyStorageIndex(
          root: root,
          maxRecordBytes: maxRecordBytes,
          fileSystem: fileSystem,
        );
    _atomic = AtomicJsonStore(
      root: root,
      index: storageIndex,
      maxRecordBytes: maxRecordBytes,
      fileSystem: fileSystem,
    );
  }

  final Directory root;
  final int maxRecordBytes;
  late final ComfyStorageIndex storageIndex;
  late final AtomicJsonStore _atomic;

  Directory get _directory => Directory(_join(root.path, 'jobs'));

  @override
  Future<List<GenerationJob>> list() async {
    final snapshot = await storageIndex.read();
    final records = <GenerationJob>[];
    for (final id in snapshot.jobIds) {
      final record = await get(id);
      if (record != null) records.add(record);
    }
    return List.unmodifiable(records);
  }

  Future<List<GenerationJob>> listNonterminal() async => List.unmodifiable(
    (await list()).where(
      (job) => const {
        GenerationJobState.submitting,
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state),
    ),
  );

  @override
  Future<GenerationJob?> get(String id) async {
    validateRecordId(id);
    final record = _record(id);
    if (!await record.exists()) return null;
    try {
      final value = GenerationJob.fromJson(await _atomic.readJson(record));
      if (value.localId != id) {
        throw const FormatException('Record ID does not match its filename');
      }
      return value;
    } on Object catch (error) {
      if (isMissingFileError(error) && !await record.exists()) return null;
      if (!isCorruptRecordError(error)) rethrow;
      await storageIndex.quarantine(record, collection: 'jobs');
      await storageIndex.removeAfterRecordDelete(
        collection: ComfyStorageIndex.jobs,
        id: id,
      );
      return null;
    }
  }

  @override
  Future<void> save(GenerationJob value) async {
    validateRecordId(value.localId);
    final record = _record(value.localId);
    await storageIndex.commitRecordMutation<void>(
      collection: ComfyStorageIndex.jobs,
      id: value.localId,
      presentAfterCommit: true,
      mutation: (commitIndex) => _atomic.withRecordTransaction(
        record,
        (transaction) => transaction.writeJson(record, value.toJson()),
        afterCommit: commitIndex,
      ),
    );
  }

  @override
  Future<void> delete(String id) async {
    validateRecordId(id);
    final record = _record(id);
    await storageIndex.commitRecordMutation<void>(
      collection: ComfyStorageIndex.jobs,
      id: id,
      presentAfterCommit: false,
      mutation: (commitIndex) => _atomic.withRecordTransaction(
        record,
        (transaction) => transaction.deleteFile(record),
        afterCommit: commitIndex,
      ),
    );
  }

  File _record(String id) => File(_join(_directory.path, '$id.json'));
}

String _join(String first, String second) =>
    '$first${Platform.pathSeparator}$second';
