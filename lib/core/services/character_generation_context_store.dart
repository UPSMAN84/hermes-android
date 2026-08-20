import 'dart:io';

import '../models/character_generation_context.dart';
import 'atomic_json_store.dart';

final class CharacterGenerationContextStore
    implements RecordStore<CharacterGenerationContext> {
  CharacterGenerationContextStore({
    required this.root,
    ComfyStorageIndex? index,
    this.maxRecordBytes = 5 * 1024 * 1024,
    this.maxReferenceImageBytes = 25 * 1024 * 1024,
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
  final int maxReferenceImageBytes;
  late final ComfyStorageIndex storageIndex;
  late final AtomicJsonStore _atomic;

  Directory get _directory => Directory(_join(root.path, 'character-contexts'));

  @override
  Future<List<CharacterGenerationContext>> list() async {
    final snapshot = await storageIndex.read();
    final records = <CharacterGenerationContext>[];
    for (final id in snapshot.contextIds) {
      final record = await get(id);
      if (record != null) records.add(record);
    }
    return List.unmodifiable(records);
  }

  @override
  Future<CharacterGenerationContext?> get(String id) async {
    validateRecordId(id);
    await _atomic.recoverPendingTransactions();
    final record = _record(id);
    if (!await record.exists()) return null;
    try {
      return await _atomic.withRecordTransaction(record, (transaction) async {
        final value = await decodeStoredCharacterContext(
          json: await transaction.readJson(record),
          id: id,
          root: root,
          transaction: transaction,
          maxReferenceImageBytes: maxReferenceImageBytes,
        );
        if (value.sessionId != id) {
          throw const FormatException('Record ID does not match its filename');
        }
        return value;
      });
    } on Object catch (error) {
      if (isMissingFileError(error) && !await record.exists()) return null;
      if (!isCorruptRecordError(error)) rethrow;
      await storageIndex.quarantine(record, collection: 'character-contexts');
      await storageIndex.removeAfterRecordDelete(
        collection: ComfyStorageIndex.contexts,
        id: id,
      );
      return null;
    }
  }

  @override
  Future<CharacterGenerationContext> save(
    CharacterGenerationContext value, {
    File? referenceImage,
  }) async {
    validateRecordId(value.sessionId);
    final record = _record(value.sessionId);
    final ownedImage = _referenceImage(value.sessionId);
    return storageIndex.commitRecordMutation<CharacterGenerationContext>(
      collection: ComfyStorageIndex.contexts,
      id: value.sessionId,
      presentAfterCommit: true,
      mutation: (stageIndex) => _atomic.withRecordTransaction(record, (
        transaction,
      ) async {
        final CharacterGenerationContext saved;
        String? referenceImageSha256;
        if (referenceImage != null) {
          referenceImageSha256 = await transaction.copyFile(
            referenceImage,
            ownedImage,
            maxBytes: maxReferenceImageBytes,
          );
          saved = value.copyWith(referenceImagePath: ownedImage.absolute.path);
        } else if (value.referenceImagePath != null) {
          if (!_sameAbsolutePath(File(value.referenceImagePath!), ownedImage) ||
              !await ownedImage.exists()) {
            throw const FormatException(
              'Unsafe character reference image path',
            );
          }
          referenceImageSha256 = await transaction.sha256File(
            ownedImage,
            maxBytes: maxReferenceImageBytes,
          );
          saved = value.copyWith(referenceImagePath: ownedImage.absolute.path);
        } else {
          saved = value;
        }
        await transaction.writeJson(record, {
          ...saved.toJson(),
          referenceImageSha256Key: ?referenceImageSha256,
        });
        if (saved.referenceImagePath == null) {
          await transaction.deleteFile(ownedImage);
        }
        await stageIndex(transaction);
        return saved;
      }),
    );
  }

  @override
  Future<void> delete(String id) async {
    validateRecordId(id);
    final record = _record(id);
    final image = _referenceImage(id);
    await storageIndex.commitRecordMutation<void>(
      collection: ComfyStorageIndex.contexts,
      id: id,
      presentAfterCommit: false,
      mutation: (stageIndex) =>
          _atomic.withRecordTransaction(record, (transaction) async {
            await transaction.deleteFile(record);
            await transaction.deleteFile(image);
            await stageIndex(transaction);
          }),
    );
  }

  File _record(String id) => File(_join(_directory.path, '$id.json'));

  File _referenceImage(String id) =>
      File(_join(_directory.path, id, 'reference-image'));
}

String _join(String first, String second, [String? third]) =>
    [first, second, ?third].join(Platform.pathSeparator);

bool _sameAbsolutePath(File left, File right) {
  final leftPath = left.absolute.path;
  final rightPath = right.absolute.path;
  return Platform.isWindows
      ? leftPath.toLowerCase() == rightPath.toLowerCase()
      : leftPath == rightPath;
}
