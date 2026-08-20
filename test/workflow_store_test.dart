import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/character_generation_context.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/models/media_asset.dart';
import 'package:hermes_android/core/services/atomic_json_store.dart';
import 'package:hermes_android/core/services/character_generation_context_store.dart';
import 'package:hermes_android/core/services/generation_job_store.dart';
import 'package:hermes_android/core/services/media_asset_store.dart';
import 'package:hermes_android/core/services/workflow_store.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hermes-comfy-store-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('atomic storage', () {
    test('serializes aliases of the same canonical record path', () async {
      final subdirectory = Directory(_join(temp.path, 'alias'));
      await subdirectory.create();
      final index = ComfyStorageIndex(root: temp);
      final atomic = AtomicJsonStore(root: temp, index: index);
      final direct = File(_join(temp.path, 'record.json'));
      final alias = File(_join(subdirectory.path, '..', 'record.json'));
      var active = 0;
      var maximumActive = 0;

      await Future.wait([
        atomic.withRecordLock(direct, () async {
          active++;
          maximumActive = active > maximumActive ? active : maximumActive;
          await Future<void>.delayed(const Duration(milliseconds: 25));
          active--;
        }),
        atomic.withRecordLock(alias, () async {
          active++;
          maximumActive = active > maximumActive ? active : maximumActive;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
        }),
      ]);

      expect(maximumActive, 1);
    });

    test(
      'overwrites an existing file and cleans unique sibling temps',
      () async {
        final index = ComfyStorageIndex(root: temp);
        final atomic = AtomicJsonStore(root: temp, index: index);
        final target = File(_join(temp.path, 'records', 'one.json'));

        await atomic.writeJson(target, {'value': 'first'});
        await Future.wait(
          List.generate(
            24,
            (value) => atomic.writeJson(target, {'value': value}),
          ),
        );

        final decoded = await atomic.readJson(target);
        expect(decoded['value'], isA<int>());
        expect(
          target.parent.listSync().whereType<File>().where(
            (file) => file.path.endsWith('.tmp'),
          ),
          isEmpty,
        );
      },
    );

    test('enforces read and write byte ceilings', () async {
      final index = ComfyStorageIndex(root: temp, maxRecordBytes: 64);
      final atomic = AtomicJsonStore(
        root: temp,
        index: index,
        maxRecordBytes: 64,
      );
      final target = File(_join(temp.path, 'bounded.json'));

      await expectLater(
        atomic.writeJson(target, {'value': List.filled(100, 'x').join()}),
        throwsFormatException,
      );
      await target.writeAsBytes(List.filled(65, 1));
      await expectLater(atomic.readBytes(target), throwsFormatException);
    });
  });

  group('unified index and workflows', () {
    test(
      'retains byte-exact source separately from graph and sidecar',
      () async {
        final source = utf8.encode(
          '{\r\n  "1": {"class_type":"Known","inputs":{"text":"raw"}}\r\n}\r\n',
        );
        final value = definition(sourceBytes: source);
        final store = WorkflowStore(root: temp);

        await store.save(value, originalSource: source);

        expect(await store.getOriginalSource('workflow-1'), source);
        expect((await store.get('workflow-1'))!.toJson(), value.toJson());
        final directory = Directory(_join(temp.path, 'workflows'));
        expect(
          jsonDecode(
            await File(_join(directory.path, 'workflow-1.json')).readAsString(),
          ),
          value.workingGraph,
        );
        expect(
          await File(
            _join(directory.path, 'workflow-1.source.json'),
          ).readAsBytes(),
          source,
        );
        expect(
          ComfyWorkflowDefinition.fromJson(
            (jsonDecode(
                      await File(
                        _join(directory.path, 'workflow-1.hermes.json'),
                      ).readAsString(),
                    )
                    as Map)
                .map((key, value) => MapEntry(key.toString(), value)),
          ).toJson(),
          value.toJson(),
        );
      },
    );

    test(
      'rolls back every workflow promotion failure to the old logical record',
      () async {
        final oldSource = utf8.encode(validGraph);
        final oldValue = definition(sourceBytes: oldSource);
        await WorkflowStore(
          root: temp,
        ).save(oldValue, originalSource: oldSource);
        final newSource = utf8.encode(
          '{"2":{"class_type":"Known","inputs":{"text":"new"}}}',
        );
        final newValue = definition(
          sourceBytes: newSource,
          graph: {
            '2': {
              'class_type': 'Known',
              'inputs': {'text': 'edited'},
            },
          },
        );

        for (final failAt in [1, 2, 3, 4]) {
          final fileSystem = FaultInjectingAtomicStoreFileSystem(
            failPromotionAt: failAt,
          );
          final failingStore = WorkflowStore(
            root: temp,
            fileSystem: fileSystem,
          );

          await expectLater(
            failingStore.save(newValue, originalSource: newSource),
            throwsA(isA<FileSystemException>()),
            reason: 'promotion $failAt',
          );

          final reader = WorkflowStore(root: temp);
          expect(
            (await reader.get(oldValue.id))!.toJson(),
            oldValue.toJson(),
            reason: 'promotion $failAt',
          );
          expect(
            await reader.getOriginalSource(oldValue.id),
            oldSource,
            reason: 'promotion $failAt',
          );
          expect(_atomicDebris(temp), isEmpty, reason: 'promotion $failAt');
        }
      },
    );

    test(
      'recovers abandoned workflow journals before decoding mixed files',
      () async {
        final oldSource = utf8.encode(validGraph);
        final oldValue = definition(sourceBytes: oldSource);
        await WorkflowStore(
          root: temp,
        ).save(oldValue, originalSource: oldSource);
        final newSource = utf8.encode(
          '{"2":{"class_type":"Known","inputs":{"text":"new"}}}',
        );
        final newValue = definition(
          sourceBytes: newSource,
          graph: {
            '2': {
              'class_type': 'Known',
              'inputs': {'text': 'committed'},
            },
          },
        );
        final workflows = Directory(_join(temp.path, 'workflows'));
        final index = File(_join(temp.path, 'index.json'));
        final replacements = <File, List<int>?>{
          File(_join(workflows.path, '${oldValue.id}.source.json')): newSource,
          File(_join(workflows.path, '${oldValue.id}.json')): utf8.encode(
            jsonEncode(newValue.workingGraph),
          ),
          File(_join(workflows.path, '${oldValue.id}.hermes.json')): utf8
              .encode(jsonEncode(newValue.toJson())),
          index: await index.readAsBytes(),
        };

        await _simulateAbandonedTransaction(
          temp,
          id: 'workflow-uncommitted',
          replacements: replacements,
          committed: false,
        );

        var reconstructed = WorkflowStore(root: temp);
        expect(
          (await reconstructed.get(oldValue.id))!.toJson(),
          oldValue.toJson(),
        );
        expect(await reconstructed.getOriginalSource(oldValue.id), oldSource);
        expect(_quarantinedFiles(temp), isEmpty);
        expect(_transactionArtifacts(temp), isEmpty);

        await _simulateAbandonedTransaction(
          temp,
          id: 'workflow-committed',
          replacements: replacements,
          committed: true,
        );

        reconstructed = WorkflowStore(root: temp);
        expect(
          (await reconstructed.get(newValue.id))!.toJson(),
          newValue.toJson(),
        );
        expect(await reconstructed.getOriginalSource(newValue.id), newSource);
        expect(_transactionArtifacts(temp), isEmpty);
      },
    );

    test('quarantines workflow source-hash and graph mismatches', () async {
      final store = WorkflowStore(root: temp);
      final graphSource = utf8.encode(validGraph);
      final graphValue = definition(
        id: 'workflow-graph-mismatch',
        sourceBytes: graphSource,
      );
      await store.save(graphValue, originalSource: graphSource);
      await File(
        _join(temp.path, 'workflows', '${graphValue.id}.json'),
      ).writeAsString('{"different":true}');

      expect(await store.get(graphValue.id), isNull);

      final sourceValue = definition(
        id: 'workflow-source-mismatch',
        sourceBytes: graphSource,
      );
      await store.save(sourceValue, originalSource: graphSource);
      await File(
        _join(temp.path, 'workflows', '${sourceValue.id}.source.json'),
      ).writeAsBytes(utf8.encode('{"tampered":true}'));

      expect(await store.get(sourceValue.id), isNull);
      expect(_quarantinedFiles(temp), hasLength(2));
    });

    test(
      'rebuilds deterministically and quarantines one corrupt record',
      () async {
        final workflowStore = WorkflowStore(root: temp);
        final jobStore = GenerationJobStore(root: temp);
        final mediaStore = MediaAssetStore(root: temp);
        final contextStore = CharacterGenerationContextStore(root: temp);
        await workflowStore.save(
          definition(id: 'workflow-z'),
          originalSource: utf8.encode(validGraph),
        );
        await workflowStore.save(
          definition(id: 'workflow-a'),
          originalSource: utf8.encode(validGraph),
        );
        await jobStore.save(job(id: 'job-b', state: GenerationJobState.queued));
        await mediaStore.save(asset(id: 'asset-b'));
        await contextStore.save(context(id: 'session-b'));
        final workflows = Directory(_join(temp.path, 'workflows'));
        await File(
          _join(workflows.path, 'broken.hermes.json'),
        ).writeAsString('{');
        final indexFile = File(_join(temp.path, 'index.json'));
        await indexFile.delete();

        final result = await workflowStore.rebuildIndex();

        expect(result.records.map((record) => record.id), [
          'workflow-a',
          'workflow-z',
        ]);
        expect(result.snapshot.workflowIds, ['workflow-a', 'workflow-z']);
        expect(result.snapshot.jobIds, ['job-b']);
        expect(result.snapshot.mediaIds, ['asset-b']);
        expect(result.snapshot.contextIds, ['session-b']);
        expect(_quarantinedFiles(temp), isNotEmpty);
        expect(await workflowStore.get('workflow-a'), isNotNull);
        expect(await workflowStore.get('workflow-z'), isNotNull);
      },
    );

    test('a corrupt index is quarantined and rebuilt from records', () async {
      final store = WorkflowStore(root: temp);
      await store.save(definition(), originalSource: utf8.encode(validGraph));
      await File(_join(temp.path, 'index.json')).writeAsString('{');

      final snapshot = await ComfyStorageIndex(root: temp).read();

      expect(snapshot.schemaVersion, ComfyStorageIndex.schemaVersion);
      expect(snapshot.workflowIds, ['workflow-1']);
      expect(
        _quarantinedFiles(temp).any((file) => file.path.contains('index.json')),
        isTrue,
      );
    });

    test(
      'rejects traversal ids without writing outside the collection',
      () async {
        final store = WorkflowStore(root: temp);

        for (final unsafeId in ['../escape', 'CON']) {
          await expectLater(store.get(unsafeId), throwsFormatException);
        }
        await expectLater(
          store.save(
            definition(id: '../escape'),
            originalSource: utf8.encode(validGraph),
          ),
          throwsFormatException,
        );

        expect(
          File(_join(temp.path, 'escape.hermes.json')).existsSync(),
          isFalse,
        );
      },
    );

    test('does not index a record whose atomic replacement fails', () async {
      final store = WorkflowStore(root: temp, maxRecordBytes: 128);

      await expectLater(
        store.save(definition(), originalSource: utf8.encode(validGraph)),
        throwsFormatException,
      );

      expect((await ComfyStorageIndex(root: temp).read()).workflowIds, isEmpty);
    });
  });

  group('job store', () {
    test('propagates operational reads but quarantines corrupt JSON', () async {
      final value = job(id: 'job-io', state: GenerationJobState.queued);
      final record = File(_join(temp.path, 'jobs', '${value.localId}.json'));
      await GenerationJobStore(root: temp).save(value);
      final failingStore = GenerationJobStore(
        root: temp,
        fileSystem: FaultInjectingAtomicStoreFileSystem(
          failReadPath: record.path,
        ),
      );

      await expectLater(
        failingStore.get(value.localId),
        throwsA(isA<FileSystemException>()),
      );
      expect(await record.exists(), isTrue);
      expect(_quarantinedFiles(temp), isEmpty);

      await record.writeAsString('{');
      expect(await GenerationJobStore(root: temp).get(value.localId), isNull);
      expect(await record.exists(), isFalse);
      expect(_quarantinedFiles(temp), hasLength(1));
    });

    test('propagates index I/O errors without quarantining it', () async {
      final store = GenerationJobStore(root: temp);
      await store.save(job(state: GenerationJobState.queued));
      final indexFile = File(_join(temp.path, 'index.json'));
      final index = ComfyStorageIndex(
        root: temp,
        fileSystem: FaultInjectingAtomicStoreFileSystem(
          failReadPath: indexFile.path,
        ),
      );

      await expectLater(index.read(), throwsA(isA<FileSystemException>()));

      expect(await indexFile.exists(), isTrue);
      expect(_quarantinedFiles(temp), isEmpty);
    });

    test('propagates record I/O errors while rebuilding the index', () async {
      final value = job(id: 'job-rebuild-io', state: GenerationJobState.queued);
      final store = GenerationJobStore(root: temp);
      await store.save(value);
      final record = File(_join(temp.path, 'jobs', '${value.localId}.json'));
      await File(_join(temp.path, 'index.json')).delete();
      final index = ComfyStorageIndex(
        root: temp,
        fileSystem: FaultInjectingAtomicStoreFileSystem(
          failReadPath: record.path,
        ),
      );

      await expectLater(index.read(), throwsA(isA<FileSystemException>()));

      expect(await record.exists(), isTrue);
      expect(_quarantinedFiles(temp), isEmpty);
    });

    test(
      'keeps record and index coherent during overlapping save/delete',
      () async {
        await ComfyStorageIndex(root: temp).read();
        final fileSystem = FaultInjectingAtomicStoreFileSystem(
          gateIndexPromotion: true,
        );
        final store = GenerationJobStore(root: temp, fileSystem: fileSystem);
        final value = job(id: 'job-race', state: GenerationJobState.queued);
        final record = File(_join(temp.path, 'jobs', '${value.localId}.json'));

        final save = store.save(value);
        await fileSystem.indexPromotionEntered.future;
        final delete = store.delete(value.localId);
        var deleteCompleted = false;
        delete.whenComplete(() => deleteCompleted = true);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(deleteCompleted, isFalse);
        expect(await record.exists(), isTrue);

        fileSystem.releaseIndexPromotion();
        await save;
        await delete;
        expect(await record.exists(), isFalse);
        expect(
          (await ComfyStorageIndex(root: temp).read()).jobIds,
          isNot(contains(value.localId)),
        );
      },
    );

    test(
      'committed cleanup failures preserve save/delete consistency and recover',
      () async {
        final original = job(
          id: 'job-cleanup',
          state: GenerationJobState.queued,
        );
        await GenerationJobStore(root: temp).save(original);
        final updated = job(
          id: original.localId,
          state: GenerationJobState.running,
        );
        final saveFileSystem = FaultInjectingAtomicStoreFileSystem(
          failIndexBackupCleanup: true,
        );

        await GenerationJobStore(
          root: temp,
          fileSystem: saveFileSystem,
        ).save(updated);

        expect(
          GenerationJob.fromJson(
            _readJsonFile(
              File(_join(temp.path, 'jobs', '${updated.localId}.json')),
            ),
          ).state,
          GenerationJobState.running,
        );
        expect(
          ComfyIndexSnapshot.fromJson(
            _readJsonFile(File(_join(temp.path, 'index.json'))),
          ).jobIds,
          contains(updated.localId),
        );
        expect(_transactionArtifacts(temp), isNotEmpty);

        expect(
          (await GenerationJobStore(root: temp).get(updated.localId))!.state,
          GenerationJobState.running,
        );
        expect(_transactionArtifacts(temp), isEmpty);

        final deleteFileSystem = FaultInjectingAtomicStoreFileSystem(
          failIndexBackupCleanup: true,
        );
        await GenerationJobStore(
          root: temp,
          fileSystem: deleteFileSystem,
        ).delete(updated.localId);

        expect(
          File(
            _join(temp.path, 'jobs', '${updated.localId}.json'),
          ).existsSync(),
          isFalse,
        );
        expect(
          ComfyIndexSnapshot.fromJson(
            _readJsonFile(File(_join(temp.path, 'index.json'))),
          ).jobIds,
          isNot(contains(updated.localId)),
        );
        expect(_transactionArtifacts(temp), isNotEmpty);

        expect(
          await GenerationJobStore(root: temp).get(updated.localId),
          isNull,
        );
        expect(_transactionArtifacts(temp), isEmpty);
      },
    );

    test(
      'lists every recoverable state including promptless submitting',
      () async {
        final store = GenerationJobStore(root: temp);
        final states = <GenerationJobState>[
          GenerationJobState.draft,
          GenerationJobState.submitting,
          GenerationJobState.queued,
          GenerationJobState.running,
          GenerationJobState.cancelling,
          GenerationJobState.reconciling,
          GenerationJobState.succeeded,
          GenerationJobState.failed,
          GenerationJobState.cancelled,
          GenerationJobState.uncertain,
        ];
        for (final state in states) {
          await store.save(
            job(
              id: 'job-${state.name}',
              state: state,
              promptId: state == GenerationJobState.submitting
                  ? null
                  : 'prompt',
            ),
          );
        }

        final nonterminal = await store.listNonterminal();

        expect(nonterminal.map((value) => value.state).toSet(), {
          GenerationJobState.submitting,
          GenerationJobState.queued,
          GenerationJobState.running,
          GenerationJobState.cancelling,
          GenerationJobState.reconciling,
        });
        expect(
          nonterminal
              .singleWhere(
                (value) => value.state == GenerationJobState.submitting,
              )
              .promptId,
          isNull,
        );
      },
    );
  });

  group('media store', () {
    test(
      'deduplicates by endpoint-aware identity and never cascades deletion',
      () async {
        final store = MediaAssetStore(root: temp);
        final jobStore = GenerationJobStore(root: temp);
        final serverFile = File(_join(temp.path, 'server-result.png'));
        await serverFile.writeAsBytes([9, 8, 7]);
        final first = asset(id: 'asset-first', cachePath: serverFile.path);
        final duplicate = asset(
          id: 'asset-duplicate',
          sourceSessionId: 'session-1',
          sourceMessageId: 'message-1',
        );

        final savedFirst = await store.upsert(first);
        final savedDuplicate = await store.upsert(duplicate);

        expect(savedFirst.id, 'asset-first');
        expect(savedDuplicate.id, 'asset-first');
        expect(await store.list(), hasLength(1));
        expect(savedDuplicate.sourceSessionId, 'session-1');
        expect(savedDuplicate.sourceMessageId, 'message-1');
        await jobStore.save(job(state: GenerationJobState.succeeded));
        await jobStore.delete('job-1');
        expect(await store.get(savedDuplicate.id), isNotNull);
        await store.delete(savedDuplicate.id);
        expect(await store.list(), isEmpty);
        expect(await serverFile.exists(), isTrue);
      },
    );

    test('quarantines loaded media records with unsafe output refs', () async {
      final store = MediaAssetStore(root: temp);
      final corruptions = <String, Map<String, Object?>>{
        'asset-unsafe-path': {'filename': '../outside.png'},
        'asset-empty-name': {'filename': ''},
        'asset-unsafe-type': {'type': 'future-output'},
      };
      for (final entry in corruptions.entries) {
        final value = asset(id: entry.key);
        await store.save(value);
        final record = File(_join(temp.path, 'media', '${entry.key}.json'));
        await record.writeAsString(
          jsonEncode({...value.toJson(), ...entry.value}),
        );

        expect(await store.get(value.id), isNull, reason: entry.key);
        expect(await record.exists(), isFalse, reason: entry.key);
        expect(
          (await ComfyStorageIndex(root: temp).read()).mediaIds,
          isNot(contains(value.id)),
          reason: entry.key,
        );
      }
      expect(_quarantinedFiles(temp), isNotEmpty);
    });
  });

  group('character context store', () {
    test('context copies and deletes the reference image', () async {
      final source = File(_join(temp.path, 'picked.png'));
      await source.writeAsBytes([1, 2, 3]);
      final store = CharacterGenerationContextStore(root: temp);

      final saved = await store.save(context(), referenceImage: source);

      expect(File(saved.referenceImagePath!).readAsBytesSync(), [1, 2, 3]);
      expect(saved.referenceImagePath, isNot(source.path));
      await store.delete(saved.sessionId);
      expect(File(saved.referenceImagePath!).existsSync(), isFalse);
      expect(await source.exists(), isTrue);
    });

    test('rolls back image and metadata promotion failures together', () async {
      final oldImage = File(_join(temp.path, 'old.png'));
      final newImage = File(_join(temp.path, 'new.png'));
      await oldImage.writeAsBytes([1, 2, 3]);
      await newImage.writeAsBytes([4, 5, 6]);
      final oldValue = context(appearancePrompt: 'old appearance');
      await CharacterGenerationContextStore(
        root: temp,
      ).save(oldValue, referenceImage: oldImage);

      for (final failAt in [1, 2, 3]) {
        final failingStore = CharacterGenerationContextStore(
          root: temp,
          fileSystem: FaultInjectingAtomicStoreFileSystem(
            failPromotionAt: failAt,
          ),
        );
        await expectLater(
          failingStore.save(
            context(appearancePrompt: 'new appearance'),
            referenceImage: newImage,
          ),
          throwsA(isA<FileSystemException>()),
          reason: 'promotion $failAt',
        );

        final loaded = await CharacterGenerationContextStore(
          root: temp,
        ).get(oldValue.sessionId);
        expect(loaded!.appearancePrompt, 'old appearance');
        expect(File(loaded.referenceImagePath!).readAsBytesSync(), [1, 2, 3]);
        expect(_atomicDebris(temp), isEmpty, reason: 'promotion $failAt');
      }
    });

    test('persists and validates reference image SHA-256 metadata', () async {
      final source = File(_join(temp.path, 'hash-source.png'));
      await source.writeAsBytes([1, 3, 3, 7]);
      final store = CharacterGenerationContextStore(root: temp);

      final saved = await store.save(context(), referenceImage: source);
      final record = File(
        _join(temp.path, 'character-contexts', '${saved.sessionId}.json'),
      );
      expect(
        _readJsonFile(record)['referenceImageSha256'],
        sha256.convert([1, 3, 3, 7]).toString(),
      );

      await File(saved.referenceImagePath!).writeAsBytes([9, 9, 9]);

      expect(await store.get(saved.sessionId), isNull);
      expect(await record.exists(), isFalse);
      expect(_quarantinedFiles(temp), hasLength(1));
    });

    test(
      'recovers abandoned character journals before image integrity decode',
      () async {
        final oldImageSource = File(_join(temp.path, 'journal-old.png'));
        await oldImageSource.writeAsBytes([1, 2, 3]);
        final oldValue = context(appearancePrompt: 'old appearance');
        final store = CharacterGenerationContextStore(root: temp);
        final oldSaved = await store.save(
          oldValue,
          referenceImage: oldImageSource,
        );
        final ownedImage = File(oldSaved.referenceImagePath!);
        final newImageBytes = <int>[4, 5, 6];
        final newSaved = context(
          appearancePrompt: 'committed appearance',
        ).copyWith(referenceImagePath: ownedImage.absolute.path);
        final newRecord = <String, Object?>{
          ...newSaved.toJson(),
          'referenceImageSha256': sha256.convert(newImageBytes).toString(),
        };
        final record = File(
          _join(temp.path, 'character-contexts', '${oldSaved.sessionId}.json'),
        );
        final index = File(_join(temp.path, 'index.json'));
        final replacements = <File, List<int>?>{
          ownedImage: newImageBytes,
          record: utf8.encode(jsonEncode(newRecord)),
          index: await index.readAsBytes(),
        };

        await _simulateAbandonedTransaction(
          temp,
          id: 'context-uncommitted',
          replacements: replacements,
          committed: false,
        );

        var reconstructed = CharacterGenerationContextStore(root: temp);
        var loaded = await reconstructed.get(oldSaved.sessionId);
        expect(loaded!.appearancePrompt, 'old appearance');
        expect(await File(loaded.referenceImagePath!).readAsBytes(), [1, 2, 3]);
        expect(_transactionArtifacts(temp), isEmpty);

        await _simulateAbandonedTransaction(
          temp,
          id: 'context-committed',
          replacements: replacements,
          committed: true,
        );

        reconstructed = CharacterGenerationContextStore(root: temp);
        loaded = await reconstructed.get(oldSaved.sessionId);
        expect(loaded!.appearancePrompt, 'committed appearance');
        expect(
          await File(loaded.referenceImagePath!).readAsBytes(),
          newImageBytes,
        );
        expect(_transactionArtifacts(temp), isEmpty);
      },
    );
  });
}

const validGraph = '{"1":{"class_type":"Known","inputs":{"text":"raw"}}}';

String _join(String first, String second, [String? third, String? fourth]) =>
    [first, second, ?third, ?fourth].join(Platform.pathSeparator);

List<File> _quarantinedFiles(Directory root) {
  final quarantine = Directory(_join(root.path, 'quarantine'));
  if (!quarantine.existsSync()) return const [];
  return quarantine.listSync(recursive: true).whereType<File>().toList();
}

List<File> _atomicDebris(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where(
      (file) =>
          file.path.contains('.tmp') ||
          file.path.contains('.transaction-temp') ||
          file.path.contains('.transaction-backup') ||
          file.path.contains('.journal.json') ||
          file.path.contains('.backup'),
    )
    .toList();

List<FileSystemEntity> _transactionArtifacts(Directory root) {
  final directory = Directory(_join(root.path, '.transactions'));
  final artifacts = <FileSystemEntity>[];
  if (directory.existsSync()) {
    artifacts.addAll(directory.listSync(recursive: true));
  }
  artifacts.addAll(
    root
        .listSync(recursive: true)
        .where(
          (entity) =>
              entity is File &&
              (entity.path.contains('.transaction-backup') ||
                  entity.path.contains('.transaction-temp')),
        ),
  );
  return artifacts;
}

Map<String, Object?> _readJsonFile(File file) =>
    (jsonDecode(file.readAsStringSync()) as Map).map(
      (key, value) => MapEntry(key.toString(), value),
    );

Future<void> _simulateAbandonedTransaction(
  Directory root, {
  required String id,
  required Map<File, List<int>?> replacements,
  required bool committed,
}) async {
  final entries = <Map<String, Object?>>[];
  for (final replacement in replacements.entries) {
    final target = replacement.key;
    final hadOriginal = await target.exists();
    final backup = hadOriginal
        ? File('${target.path}.$id.transaction-backup')
        : null;
    if (backup != null) await target.rename(backup.path);
    final bytes = replacement.value;
    if (bytes != null) {
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
    }
    entries.add({
      'target': _relativeStoragePath(root, target),
      'temporary': _relativeStoragePath(
        root,
        File('${target.path}.$id.transaction-temp'),
      ),
      'backup': backup == null ? null : _relativeStoragePath(root, backup),
      'hadOriginal': hadOriginal,
    });
  }
  final directory = Directory(_join(root.path, '.transactions'));
  await directory.create(recursive: true);
  final journal = File(_join(directory.path, '$id.journal.json'));
  await journal.writeAsString(
    jsonEncode({'schemaVersion': 1, 'transactionId': id, 'entries': entries}),
    flush: true,
  );
  if (committed) {
    await File('${journal.path}.committed').writeAsString(id, flush: true);
  }
}

String _relativeStoragePath(Directory root, File file) {
  final rootPath = root.absolute.path;
  return file.absolute.path
      .substring(rootPath.length + 1)
      .replaceAll(Platform.pathSeparator, '/');
}

ComfyWorkflowDefinition definition({
  String id = 'workflow-1',
  List<int>? sourceBytes,
  Map<String, Object?>? graph,
}) => ComfyWorkflowDefinition(
  id: id,
  name: 'Fixture $id',
  kind: ComfyMediaKind.image,
  workingGraph:
      graph ??
      {
        '1': {
          'class_type': 'Known',
          'inputs': {'text': id},
        },
      },
  sourceHash: sha256.convert(sourceBytes ?? utf8.encode(validGraph)).toString(),
  sourceFileName: '$id.json',
  bindings: const [],
  createdAt: DateTime.utc(2026, 8, 20, 1),
  updatedAt: DateTime.utc(2026, 8, 20, 2),
);

GenerationJob job({
  String id = 'job-1',
  required GenerationJobState state,
  String? promptId = 'prompt-1',
}) => GenerationJob(
  localId: id,
  workflowId: 'workflow-1',
  kind: ComfyMediaKind.image,
  state: state,
  endpointFingerprint: 'endpoint-fingerprint',
  endpointSnapshot: 'http://host:8188',
  submittedValues: const {'prompt': 'hello'},
  promptId: promptId,
  createdAt: DateTime.utc(2026, 8, 20, 1),
  updatedAt: DateTime.utc(2026, 8, 20, 2),
);

MediaAsset asset({
  String id = 'asset-1',
  String? cachePath,
  String? sourceSessionId,
  String? sourceMessageId,
}) => MediaAsset(
  id: id,
  jobId: 'job-1',
  workflowId: 'workflow-1',
  kind: ComfyMediaKind.image,
  endpointSnapshot: 'http://host:8188',
  filename: 'result.png',
  subfolder: 'images',
  type: 'output',
  cachePath: cachePath,
  sourceSessionId: sourceSessionId,
  sourceMessageId: sourceMessageId,
  createdAt: DateTime.utc(2026, 8, 20, 1),
  updatedAt: DateTime.utc(2026, 8, 20, 2),
);

CharacterGenerationContext context({
  String id = 'session-1',
  String appearancePrompt = 'Silver hair and a blue coat.',
}) => CharacterGenerationContext(
  sessionId: id,
  characterName: 'Hermes',
  appearancePrompt: appearancePrompt,
  createdAt: DateTime.utc(2026, 8, 20, 1),
  updatedAt: DateTime.utc(2026, 8, 20, 2),
);

final class FaultInjectingAtomicStoreFileSystem
    implements AtomicStoreFileSystem {
  FaultInjectingAtomicStoreFileSystem({
    this.failPromotionAt,
    String? failReadPath,
    this.gateIndexPromotion = false,
    this.failIndexBackupCleanup = false,
  }) : failReadPath = failReadPath == null
           ? null
           : _canonicalPath(failReadPath);

  final int? failPromotionAt;
  final String? failReadPath;
  final bool gateIndexPromotion;
  final bool failIndexBackupCleanup;
  final IoAtomicStoreFileSystem _delegate = IoAtomicStoreFileSystem();
  final Completer<void> indexPromotionEntered = Completer<void>();
  final Completer<void> _indexPromotionRelease = Completer<void>();
  int _promotionCount = 0;
  bool _gated = false;
  bool _backupCleanupFailed = false;

  @override
  Future<Uint8List> readBytes(File file, {required int maxBytes}) {
    if (_canonicalPath(file.path) == failReadPath) {
      throw FileSystemException(
        'Injected permission failure',
        file.path,
        const OSError('Access denied', 5),
      );
    }
    return _delegate.readBytes(file, maxBytes: maxBytes);
  }

  @override
  Future<void> promote(File temporary, File target) async {
    _promotionCount++;
    if (_promotionCount == failPromotionAt) {
      throw FileSystemException(
        'Injected promotion failure',
        target.path,
        const OSError('Access denied', 5),
      );
    }
    if (gateIndexPromotion &&
        !_gated &&
        target.path.endsWith('${Platform.pathSeparator}index.json')) {
      _gated = true;
      indexPromotionEntered.complete();
      await _indexPromotionRelease.future;
    }
    await _delegate.promote(temporary, target);
  }

  @override
  Future<void> delete(File file) {
    if (failIndexBackupCleanup &&
        !_backupCleanupFailed &&
        file.path.contains('index.json') &&
        file.path.contains('.transaction-backup')) {
      _backupCleanupFailed = true;
      throw FileSystemException(
        'Injected post-replacement cleanup failure',
        file.path,
        const OSError('Access denied', 5),
      );
    }
    return _delegate.delete(file);
  }

  void releaseIndexPromotion() {
    if (!_indexPromotionRelease.isCompleted) _indexPromotionRelease.complete();
  }
}

String _canonicalPath(String path) => File(path).absolute.path.toLowerCase();
