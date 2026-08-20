import 'dart:convert';
import 'dart:io';

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
        final store = WorkflowStore(root: temp);

        await store.save(definition(), originalSource: source);

        expect(await store.getOriginalSource('workflow-1'), source);
        expect(
          (await store.get('workflow-1'))!.toJson(),
          definition().toJson(),
        );
        final directory = Directory(_join(temp.path, 'workflows'));
        expect(
          jsonDecode(
            await File(_join(directory.path, 'workflow-1.json')).readAsString(),
          ),
          definition().workingGraph,
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
          definition().toJson(),
        );
      },
    );

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

ComfyWorkflowDefinition definition({String id = 'workflow-1'}) =>
    ComfyWorkflowDefinition(
      id: id,
      name: 'Fixture $id',
      kind: ComfyMediaKind.image,
      workingGraph: {
        '1': {
          'class_type': 'Known',
          'inputs': {'text': id},
        },
      },
      sourceHash: 'source-hash-$id',
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

CharacterGenerationContext context({String id = 'session-1'}) =>
    CharacterGenerationContext(
      sessionId: id,
      characterName: 'Hermes',
      appearancePrompt: 'Silver hair and a blue coat.',
      createdAt: DateTime.utc(2026, 8, 20, 1),
      updatedAt: DateTime.utc(2026, 8, 20, 2),
    );
