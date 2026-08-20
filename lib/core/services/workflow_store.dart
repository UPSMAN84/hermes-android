import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/comfy_workflow.dart';
import 'atomic_json_store.dart';

final class WorkflowStore implements RecordStore<ComfyWorkflowDefinition> {
  WorkflowStore({
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

  Directory get _directory => Directory(_join(root.path, 'workflows'));

  @override
  Future<List<ComfyWorkflowDefinition>> list() async {
    final snapshot = await storageIndex.read();
    final records = <ComfyWorkflowDefinition>[];
    for (final id in snapshot.workflowIds) {
      final record = await get(id);
      if (record != null) records.add(record);
    }
    return List.unmodifiable(records);
  }

  @override
  Future<ComfyWorkflowDefinition?> get(String id) async =>
      (await _load(id))?.definition;

  Future<Uint8List?> getOriginalSource(String id) async =>
      (await _load(id))?.sourceBytes;

  Future<JsonObject?> getWorkingGraph(String id) async =>
      (await _load(id))?.definition.workingGraph;

  @override
  Future<void> save(
    ComfyWorkflowDefinition value, {
    List<int>? originalSource,
  }) async {
    validateRecordId(value.id);
    final sidecar = value.toJson();
    _checkSize(utf8.encode(jsonEncode(sidecar)));
    _checkSize(utf8.encode(jsonEncode(value.workingGraph)));
    if (originalSource != null) {
      _checkSize(originalSource);
      decodeStoredWorkflowDefinition(
        sidecar: sidecar,
        workingGraph: value.workingGraph,
        sourceBytes: originalSource,
      );
    }

    final primary = _sidecar(value.id);
    final source = _source(value.id);
    await storageIndex.commitRecordMutation<void>(
      collection: ComfyStorageIndex.workflows,
      id: value.id,
      presentAfterCommit: true,
      mutation: (stageIndex) =>
          _atomic.withRecordTransaction(primary, (transaction) async {
            if (originalSource != null) {
              await transaction.writeBytes(source, originalSource);
            } else {
              if (!await source.exists()) {
                throw StateError(
                  'Original workflow source is required for a new record',
                );
              }
              decodeStoredWorkflowDefinition(
                sidecar: sidecar,
                workingGraph: value.workingGraph,
                sourceBytes: await transaction.readBytes(source),
              );
            }
            await transaction.writeJson(_graph(value.id), value.workingGraph);
            await transaction.writeJson(primary, sidecar);
            await stageIndex(transaction);
          }),
    );
  }

  @override
  Future<void> delete(String id) async {
    validateRecordId(id);
    final primary = _sidecar(id);
    await storageIndex.commitRecordMutation<void>(
      collection: ComfyStorageIndex.workflows,
      id: id,
      presentAfterCommit: false,
      mutation: (stageIndex) =>
          _atomic.withRecordTransaction(primary, (transaction) async {
            await transaction.deleteFile(primary);
            await transaction.deleteFile(_graph(id));
            await transaction.deleteFile(_source(id));
            await stageIndex(transaction);
          }),
    );
  }

  Future<StoreRebuildResult<ComfyWorkflowDefinition>> rebuildIndex() async {
    final snapshot = await storageIndex.rebuild();
    final records = <ComfyWorkflowDefinition>[];
    for (final id in snapshot.workflowIds) {
      final record = await get(id);
      if (record != null) records.add(record);
    }
    return StoreRebuildResult(snapshot: snapshot, records: records);
  }

  Future<_WorkflowRecord?> _load(String id) async {
    validateRecordId(id);
    await _atomic.recoverPendingTransactions();
    final primary = _sidecar(id);
    if (!await primary.exists()) return null;
    try {
      return await _atomic.withRecordTransaction(primary, (transaction) async {
        final sidecar = await transaction.readJson(primary);
        final graph = await transaction.readJson(_graph(id));
        final source = await transaction.readBytes(_source(id));
        final definition = decodeStoredWorkflowDefinition(
          sidecar: sidecar,
          workingGraph: graph,
          sourceBytes: source,
        );
        if (definition.id != id) {
          throw const FormatException('Record ID does not match its filename');
        }
        return _WorkflowRecord(definition, source);
      });
    } on Object catch (error) {
      if (isMissingFileError(error) && !await primary.exists()) return null;
      if (!isCorruptRecordError(error)) rethrow;
      await storageIndex.quarantine(primary, collection: 'workflows');
      await storageIndex.removeAfterRecordDelete(
        collection: ComfyStorageIndex.workflows,
        id: id,
      );
      return null;
    }
  }

  File _graph(String id) => File(_join(_directory.path, '$id.json'));
  File _source(String id) => File(_join(_directory.path, '$id.source.json'));
  File _sidecar(String id) => File(_join(_directory.path, '$id.hermes.json'));

  void _checkSize(List<int> bytes) {
    if (bytes.length > maxRecordBytes) {
      throw const FormatException('Record exceeds size limit');
    }
  }
}

final class _WorkflowRecord {
  const _WorkflowRecord(this.definition, this.sourceBytes);

  final ComfyWorkflowDefinition definition;
  final Uint8List sourceBytes;
}

String _join(String first, String second) =>
    '$first${Platform.pathSeparator}$second';
