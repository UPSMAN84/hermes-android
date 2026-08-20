import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/character.dart';
import 'package:hermes_android/core/models/character_generation_context.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/models/media_asset.dart';

void main() {
  group('generation reducer', () {
    test('acceptance, queue, execution, and progress advance active jobs', () {
      final submitting = job(state: GenerationJobState.submitting);
      final accepted = reduceGenerationJob(
        submitting,
        const PromptAccepted('prompt-2'),
        later(),
      );
      expect(accepted.state, GenerationJobState.queued);
      expect(accepted.promptId, 'prompt-2');

      final queued = reduceGenerationJob(
        submitting,
        const PromptQueued(),
        later(),
      );
      expect(queued.state, GenerationJobState.queued);

      final running = reduceGenerationJob(
        queued,
        const ExecutionStarted(),
        later(),
      );
      final progressed = reduceGenerationJob(
        running,
        const ExecutionProgressed('12', 3, 8),
        later(),
      );
      expect(progressed.state, GenerationJobState.running);
      expect(progressed.currentNodeId, '12');
      expect(progressed.progressValue, 3);
      expect(progressed.progressMax, 8);
    });

    test('socket loss reconciles and never implies success', () {
      final running = job(state: GenerationJobState.running);
      final lost = reduceGenerationJob(running, const SocketLost(), later());
      expect(lost.state, GenerationJobState.reconciling);
      expect(lost.outputs, isEmpty);
    });

    test('socket loss while cancelling reconciles instead of cancelling', () {
      final cancelling = job(state: GenerationJobState.cancelling);
      final lost = reduceGenerationJob(cancelling, const SocketLost(), later());
      expect(lost.state, GenerationJobState.reconciling);
    });

    test('queue and history reconciliation select authoritative states', () {
      final reconciling = job(state: GenerationJobState.reconciling);

      final queued = reduceGenerationJob(
        reconciling,
        const QueueReconciled(true),
        later(),
      );
      expect(queued.state, GenerationJobState.queued);

      final absent = reduceGenerationJob(
        reconciling,
        const QueueReconciled(false),
        later(),
      );
      expect(absent.state, GenerationJobState.reconciling);

      final running = reduceGenerationJob(
        reconciling,
        const HistoryReconciled(completed: false),
        later(),
      );
      expect(running.state, GenerationJobState.running);

      final succeeded = reduceGenerationJob(
        reconciling,
        HistoryReconciled(completed: true, outputs: [outputRef()]),
        later(),
      );
      expect(succeeded.state, GenerationJobState.succeeded);

      final failed = reduceGenerationJob(
        reconciling,
        const HistoryReconciled(completed: true, error: 'bad graph'),
        later(),
      );
      expect(failed.state, GenerationJobState.failed);
      expect(failed.error, 'bad graph');
    });

    test('cancel confirmation and interruption are required for cancelled', () {
      final cancelling = job(state: GenerationJobState.cancelling);
      expect(
        reduceGenerationJob(
          cancelling,
          const QueueReconciled(false),
          later(),
        ).state,
        GenerationJobState.cancelling,
      );
      expect(
        reduceGenerationJob(
          cancelling,
          const QueueRemovalConfirmed(),
          later(),
        ).state,
        GenerationJobState.cancelled,
      );
      expect(
        reduceGenerationJob(
          cancelling,
          const ExecutionInterrupted(),
          later(),
        ).state,
        GenerationJobState.cancelled,
      );
    });

    test(
      'restore without prompt and ambiguous submission become uncertain',
      () {
        final promptless = job(
          state: GenerationJobState.submitting,
          promptId: null,
        );
        final restored = reduceGenerationJob(
          promptless,
          const RestoreWithoutPromptId(),
          later(),
        );
        expect(restored.state, GenerationJobState.uncertain);

        final unknown = reduceGenerationJob(
          promptless,
          const SubmissionUnknown('response lost'),
          later(),
        );
        expect(unknown.state, GenerationJobState.uncertain);
        expect(unknown.error, 'response lost');
      },
    );

    test('terminal success or error wins cancellation races', () {
      final cancelling = job(state: GenerationJobState.cancelling);
      final completed = reduceGenerationJob(
        cancelling,
        ExecutionSucceeded([outputRef()]),
        later(),
      );
      expect(completed.state, GenerationJobState.succeeded);

      final failed = reduceGenerationJob(
        cancelling,
        ExecutionFailed('node failed', nodeErrors: {'12': 'out of memory'}),
        later(),
      );
      expect(failed.state, GenerationJobState.failed);
      expect(failed.nodeErrors, {'12': 'out of memory'});

      final lateSuccess = reduceGenerationJob(
        job(state: GenerationJobState.cancelled),
        ExecutionSucceeded([outputRef()]),
        later(),
      );
      expect(lateSuccess.state, GenerationJobState.succeeded);
    });

    test('terminal jobs ignore stale nonterminal events', () {
      final succeeded = job(
        state: GenerationJobState.succeeded,
        outputs: [outputRef()],
      );
      final stale = reduceGenerationJob(succeeded, const SocketLost(), later());
      expect(stale.state, GenerationJobState.succeeded);
      expect(stale.outputs, hasLength(1));
    });

    test('draft and cancelled jobs reject stale nonterminal transitions', () {
      final draft = job(state: GenerationJobState.draft, promptId: null);
      final staleEvents = <GenerationEvent>[
        const PromptQueued(),
        const ExecutionStarted(),
        const ExecutionProgressed('12', 1, 2),
        ExecutionSucceeded([outputRef()]),
        ExecutionFailed('stale'),
        const ExecutionInterrupted(),
        const SocketLost(),
        const QueueReconciled(true),
        const HistoryReconciled(completed: false),
        HistoryReconciled(completed: true, outputs: [outputRef()]),
        const QueueRemovalConfirmed(),
      ];
      for (final event in staleEvents) {
        expect(
          reduceGenerationJob(draft, event, later()).state,
          GenerationJobState.draft,
        );
      }

      final cancelled = job(state: GenerationJobState.cancelled);
      expect(
        reduceGenerationJob(
          cancelled,
          const HistoryReconciled(completed: false),
          later(),
        ).state,
        GenerationJobState.cancelled,
      );
    });

    test('empty success payload preserves outputs already observed', () {
      final executed = job(
        state: GenerationJobState.running,
        outputs: [outputRef()],
      );
      final completed = reduceGenerationJob(
        executed,
        const ExecutionSucceeded([]),
        later(),
      );
      expect(completed.state, GenerationJobState.succeeded);
      expect(completed.outputs, hasLength(1));
      expect(completed.outputs.single.filename, 'result.png');
    });

    test('empty completed history preserves outputs already observed', () {
      final executed = job(
        state: GenerationJobState.reconciling,
        outputs: [outputRef()],
      );
      final completed = reduceGenerationJob(
        executed,
        const HistoryReconciled(completed: true),
        later(),
      );
      expect(completed.state, GenerationJobState.succeeded);
      expect(completed.outputs.single.filename, 'result.png');
    });

    test('blank accepted prompt ids are ignored', () {
      final submitting = job(
        state: GenerationJobState.submitting,
        promptId: null,
      );
      for (final promptId in ['', '   ', '\t']) {
        final reduced = reduceGenerationJob(
          submitting,
          PromptAccepted(promptId),
          later(),
        );
        expect(reduced.state, GenerationJobState.submitting);
        expect(reduced.promptId, isNull);
      }
    });

    test('nested node errors are immutable after reduction', () {
      final messages = <Object?>['original'];
      final details = <String, Object?>{'messages': messages};
      final errors = <String, Object?>{'12': details};
      final event = ExecutionFailed('node failed', nodeErrors: errors);

      messages[0] = 'mutated';
      details['extra'] = true;
      errors['13'] = 'late';

      expect(event.nodeErrors, {
        '12': {
          'messages': ['original'],
        },
      });
      final failed = reduceGenerationJob(
        job(state: GenerationJobState.running),
        event,
        later(),
      );
      expect(failed.nodeErrors, {
        '12': {
          'messages': ['original'],
        },
      });
    });
  });

  group('generation JSON', () {
    test(
      'round trip retains endpoint, values, provenance, errors, and UTC',
      () {
        final original = job(
          state: GenerationJobState.failed,
          sourceSessionId: 'session-1',
          sourceMessageId: 'message-1',
          sourceContextId: 'context-1',
          outputs: [outputRef()],
          error: 'failed',
          nodeErrors: const {'7': 'invalid'},
        );
        final restored = GenerationJob.fromJson(original.toJson());
        expect(restored.toJson(), original.toJson());
        expect(restored.endpointSnapshot, 'http://host:8188/comfy');
        expect(restored.submittedValues, {'prompt': 'hello', 'seed': 42});
        expect(restored.createdAt.isUtc, isTrue);
        expect(restored.updatedAt.isUtc, isTrue);
      },
    );

    test('unknown and missing persisted values restore to safe defaults', () {
      final restored = GenerationJob.fromJson({
        'localId': 'legacy',
        'workflowId': 'workflow-1',
        'state': 'future-state',
        'kind': 'future-kind',
        'createdAt': 'not-a-date',
      });
      expect(restored.state, GenerationJobState.uncertain);
      expect(restored.kind, ComfyMediaKind.image);
      expect(restored.submittedValues, isEmpty);
      expect(restored.outputs, isEmpty);
      expect(restored.progressValue, 0);
      expect(restored.progressMax, 0);
      expect(
        restored.createdAt,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    });

    test('blank legacy prompt ids restore as unknown', () {
      for (final promptId in ['', '   ', '\t']) {
        final json = job(
          state: GenerationJobState.submitting,
          promptId: null,
        ).toJson()..['promptId'] = promptId;
        final restored = GenerationJob.fromJson(json);
        expect(restored.promptId, isNull);
        expect(
          reduceGenerationJob(
            restored,
            const RestoreWithoutPromptId(),
            later(),
          ).state,
          GenerationJobState.uncertain,
        );
        expect(
          reduceGenerationJob(restored, const SocketLost(), later()).state,
          GenerationJobState.uncertain,
        );
      }
    });

    test('generation request snapshots submitted values and source ids', () {
      final mutable = <String, Object?>{'prompt': 'first'};
      final request = GenerationRequest(
        workflowId: 'workflow-1',
        kind: ComfyMediaKind.image,
        submittedValues: mutable,
        sourceSessionId: 'session-1',
        sourceMessageId: null,
        sourceContextId: 'context-1',
      );
      mutable['prompt'] = 'changed';
      expect(request.submittedValues['prompt'], 'first');
      expect(request.sourceSessionId, 'session-1');
      expect(request.sourceMessageId, isNull);
      expect(
        GenerationRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
    });
  });

  group('media assets', () {
    test('identity normalizes endpoint and distinguishes another endpoint', () {
      final normalized = asset(endpoint: 'HTTP://Host:8188/comfy/');
      expect(
        normalized.identityKey,
        asset(endpoint: 'http://host:8188/comfy').identityKey,
      );
      expect(
        normalized.identityKey,
        isNot(asset(endpoint: 'http://other:8188/comfy').identityKey),
      );
    });

    test('identity includes filename, subfolder, and type independently', () {
      final original = asset(endpoint: 'http://host:8188');
      expect(
        original.copyWith(filename: 'other.png').identityKey,
        isNot(original.identityKey),
      );
      expect(
        original.copyWith(subfolder: 'other').identityKey,
        isNot(original.identityKey),
      );
      expect(
        original.copyWith(type: 'temp').identityKey,
        isNot(original.identityKey),
      );
    });

    test('source session and message ids persist independently', () {
      final sessionOnly = asset(
        endpoint: 'http://host:8188',
        sourceSessionId: 'session-1',
        sourceMessageId: null,
      );
      final restored = MediaAsset.fromJson(sessionOnly.toJson());
      expect(restored.sourceSessionId, 'session-1');
      expect(restored.sourceMessageId, isNull);

      final messageOnly = sessionOnly.copyWith(
        sourceSessionId: null,
        sourceMessageId: 'message-1',
      );
      expect(messageOnly.sourceSessionId, isNull);
      expect(messageOnly.sourceMessageId, 'message-1');
    });

    test('round trip uses safe defaults and UTC dates', () {
      final original = asset(endpoint: 'http://host:8188');
      final restored = MediaAsset.fromJson(original.toJson());
      expect(restored.toJson(), original.toJson());
      expect(restored.createdAt.isUtc, isTrue);

      final legacy = MediaAsset.fromJson({
        'id': 'asset-legacy',
        'endpointSnapshot': 'http://host:8188',
        'filename': 'legacy.png',
        'kind': 'new-kind',
        'type': 'new-type',
      });
      expect(legacy.kind, ComfyMediaKind.image);
      expect(legacy.type, 'output');
      expect(legacy.subfolder, '');
      expect(legacy.cacheState, MediaCacheState.remoteOnly);
    });
  });

  group('character generation context', () {
    test(
      'fromCard copies the stable editable name and description snapshot',
      () {
        final context = CharacterGenerationContext.fromCard(
          sessionId: 'session-1',
          card: const CharacterCard(
            name: 'Hermes',
            description: 'Silver hair and a blue coat.',
            personality: 'Cheerful',
            scenario: 'A market',
          ),
          now: created(),
        );
        expect(context.characterName, 'Hermes');
        expect(context.appearancePrompt, 'Silver hair and a blue coat.');
        expect(context.referenceImagePath, isNull);
        expect(context.createdAt.isUtc, isTrue);
        expect(context.updatedAt, context.createdAt);
      },
    );

    test(
      'prompt composition is optional, trimmed, and does not mutate context',
      () {
        final context = CharacterGenerationContext(
          sessionId: 'session-1',
          characterName: 'Hermes',
          appearancePrompt: '  Silver hair and a blue coat.  ',
          referenceImagePath: 'app/context/reference.png',
          createdAt: created(),
          updatedAt: created(),
        );
        final before = context.toJson();
        expect(
          composeGenerationPrompt(
            userPrompt: '  walking through rain  ',
            context: context,
            useContext: true,
          ),
          'Silver hair and a blue coat.\n\nwalking through rain',
        );
        expect(
          composeGenerationPrompt(
            userPrompt: '  walking through rain  ',
            context: context,
            useContext: false,
          ),
          'walking through rain',
        );
        expect(context.toJson(), before);
      },
    );

    test('null context returns the trimmed user prompt', () {
      expect(
        composeGenerationPrompt(
          userPrompt: '  walking through rain  ',
          context: null,
          useContext: true,
        ),
        'walking through rain',
      );
    });

    test('JSON round trip preserves app-owned reference image path', () {
      final context = CharacterGenerationContext(
        sessionId: 'session-1',
        characterName: 'Hermes',
        appearancePrompt: 'Silver hair.',
        referenceImagePath: 'app/context/reference.png',
        createdAt: created(),
        updatedAt: later(),
      );
      expect(
        CharacterGenerationContext.fromJson(context.toJson()).toJson(),
        context.toJson(),
      );
    });
  });
}

DateTime created() => DateTime.utc(2026, 8, 20, 8);

DateTime later() => DateTime.utc(2026, 8, 20, 9);

ComfyOutputRef outputRef() =>
    ComfyOutputRef(filename: 'result.png', subfolder: 'images', type: 'output');

GenerationJob job({
  required GenerationJobState state,
  String? promptId = 'prompt-1',
  String? sourceSessionId,
  String? sourceMessageId,
  String? sourceContextId,
  List<ComfyOutputRef> outputs = const [],
  String? error,
  Map<String, Object?> nodeErrors = const {},
}) => GenerationJob(
  localId: 'job-1',
  workflowId: 'workflow-1',
  kind: ComfyMediaKind.image,
  state: state,
  endpointFingerprint: 'endpoint-sha',
  endpointSnapshot: 'http://host:8188/comfy',
  submittedValues: const {'prompt': 'hello', 'seed': 42},
  promptId: promptId,
  progressValue: 2,
  progressMax: 10,
  currentNodeId: '7',
  outputs: outputs,
  sourceSessionId: sourceSessionId,
  sourceMessageId: sourceMessageId,
  sourceContextId: sourceContextId,
  error: error,
  nodeErrors: nodeErrors,
  createdAt: created(),
  updatedAt: later(),
);

MediaAsset asset({
  required String endpoint,
  String? sourceSessionId,
  String? sourceMessageId,
}) => MediaAsset(
  id: 'asset-1',
  jobId: 'job-1',
  workflowId: 'workflow-1',
  kind: ComfyMediaKind.image,
  endpointSnapshot: endpoint,
  filename: 'result.png',
  subfolder: 'images',
  type: 'output',
  contentType: 'image/png',
  width: 1024,
  height: 768,
  durationSeconds: null,
  cachePath: null,
  sourceSessionId: sourceSessionId,
  sourceMessageId: sourceMessageId,
  createdAt: created(),
  updatedAt: later(),
);
