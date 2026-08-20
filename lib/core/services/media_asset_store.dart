import 'dart:io';

import '../models/media_asset.dart';
import 'atomic_json_store.dart';

final class MediaAssetStore implements RecordStore<MediaAsset> {
  MediaAssetStore({
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

  Directory get _directory => Directory(_join(root.path, 'media'));

  @override
  Future<List<MediaAsset>> list() async {
    final snapshot = await storageIndex.read();
    final records = <MediaAsset>[];
    for (final id in snapshot.mediaIds) {
      final record = await get(id);
      if (record != null) records.add(record);
    }
    return List.unmodifiable(records);
  }

  @override
  Future<MediaAsset?> get(String id) async {
    validateRecordId(id);
    final record = _record(id);
    if (!await record.exists()) return null;
    try {
      final value = decodeStoredMediaAsset(await _atomic.readJson(record));
      if (value.id != id) {
        throw const FormatException('Record ID does not match its filename');
      }
      return value;
    } on Object catch (error) {
      if (isMissingFileError(error) && !await record.exists()) return null;
      if (!isCorruptRecordError(error)) rethrow;
      await storageIndex.quarantine(record, collection: 'media');
      await storageIndex.removeAfterRecordDelete(
        collection: ComfyStorageIndex.media,
        id: id,
      );
      return null;
    }
  }

  @override
  Future<void> save(MediaAsset value) async {
    validateRecordId(value.id);
    value.outputRef;
    final record = _record(value.id);
    await storageIndex.commitRecordMutation<void>(
      collection: ComfyStorageIndex.media,
      id: value.id,
      presentAfterCommit: true,
      mutation: (commitIndex) => _atomic.withRecordTransaction(
        record,
        (transaction) => transaction.writeJson(record, value.toJson()),
        afterCommit: commitIndex,
      ),
    );
  }

  Future<MediaAsset> upsert(MediaAsset value) async {
    validateRecordId(value.id);
    value.outputRef;
    await _directory.create(recursive: true);
    final identityLock = File(
      _join(_directory.path, '.identity-serialization'),
    );
    return _atomic.withRecordLock(identityLock, () async {
      for (final existing in await list()) {
        if (existing.identityKey == value.identityKey) {
          final merged = _merge(existing, value);
          await save(merged);
          return merged;
        }
      }
      await save(value);
      return value;
    });
  }

  @override
  Future<void> delete(String id) async {
    validateRecordId(id);
    final record = _record(id);
    await storageIndex.commitRecordMutation<void>(
      collection: ComfyStorageIndex.media,
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

MediaAsset _merge(MediaAsset existing, MediaAsset incoming) => MediaAsset(
  id: existing.id,
  jobId: incoming.jobId ?? existing.jobId,
  workflowId: incoming.workflowId ?? existing.workflowId,
  kind: incoming.kind,
  endpointSnapshot: incoming.endpointSnapshot,
  filename: incoming.filename,
  subfolder: incoming.subfolder,
  type: incoming.type,
  contentType: incoming.contentType ?? existing.contentType,
  width: incoming.width ?? existing.width,
  height: incoming.height ?? existing.height,
  durationSeconds: incoming.durationSeconds ?? existing.durationSeconds,
  cachePath: incoming.cachePath ?? existing.cachePath,
  cacheState: incoming.cacheState == MediaCacheState.remoteOnly
      ? existing.cacheState
      : incoming.cacheState,
  sourceSessionId: incoming.sourceSessionId ?? existing.sourceSessionId,
  sourceMessageId: incoming.sourceMessageId ?? existing.sourceMessageId,
  createdAt: existing.createdAt,
  updatedAt: incoming.updatedAt.isAfter(existing.updatedAt)
      ? incoming.updatedAt
      : existing.updatedAt,
);

String _join(String first, String second) =>
    '$first${Platform.pathSeparator}$second';
