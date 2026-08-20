import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/character_generation_context.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/services/character_generation_context_store.dart';
import 'package:hermes_android/core/services/comfyui_client.dart';
import 'package:hermes_android/core/services/comfyui_socket.dart';
import 'package:hermes_android/core/services/generation_job_store.dart';
import 'package:hermes_android/core/services/generation_repository.dart';
import 'package:hermes_android/core/services/media_asset_store.dart';
import 'package:hermes_android/core/services/media_cache_service.dart';
import 'package:hermes_android/core/services/workflow_store.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory temp;
  late WorkflowStore workflowStore;
  late GenerationJobStore jobStore;
  late MediaAssetStore mediaStore;
  late CharacterGenerationContextStore contextStore;
  late _FakeEndpointConfig endpointConfig;
  late _FakeMediaCache mediaCache;
  late _FakeForegroundLease foregroundLease;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hermes-generation-repo-');
    workflowStore = WorkflowStore(root: temp);
    jobStore = GenerationJobStore(root: temp);
    mediaStore = MediaAssetStore(root: temp);
    contextStore = CharacterGenerationContextStore(root: temp);
    endpointConfig = _FakeEndpointConfig();
    mediaCache = _FakeMediaCache();
    foregroundLease = _FakeForegroundLease();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  DefaultGenerationRepository repo({
    required http.Client httpClient,
    ComfyUiSocketFactory? socketFactory,
  }) => DefaultGenerationRepository(
    endpointConfig: endpointConfig,
    clientFactory: _FakeClientFactory(httpClient),
    socketFactory:
        socketFactory ?? _FakeSocketFactory(_FakeConnector.pending()),
    workflowStore: workflowStore,
    jobStore: jobStore,
    mediaStore: mediaStore,
    contextStore: contextStore,
    mediaCache: mediaCache,
    foregroundLease: foregroundLease,
    clock: () => DateTime.utc(2026, 8, 20, 12),
  );

  Future<void> seedWorkflow() async {
    final graph = <String, Object?>{
      '1': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'default prompt'},
      },
      '2': {
        'class_type': 'LoadImage',
        'inputs': {'image': 'default.png'},
      },
    };
    final sourceBytes = Uint8List.fromList(utf8.encode(jsonEncode(graph)));
    await workflowStore.save(
      ComfyWorkflowDefinition(
        id: 'workflow-1',
        name: 'Test workflow',
        kind: ComfyMediaKind.image,
        workingGraph: graph,
        sourceHash: sha256.convert(sourceBytes).toString(),
        sourceFileName: 'workflow.json',
        bindings: const [
          WorkflowInputBinding(
            id: 'prompt-binding',
            nodeId: '1',
            inputName: 'text',
            label: 'Prompt',
            role: BindingRole.prompt,
            controlType: WorkflowControlType.multiline,
            required: false,
            defaultValue: 'default prompt',
          ),
          WorkflowInputBinding(
            id: 'image-binding',
            nodeId: '2',
            inputName: 'image',
            label: 'Reference image',
            role: BindingRole.inputImage,
            controlType: WorkflowControlType.file,
            required: false,
            defaultValue: 'default.png',
          ),
        ],
        createdAt: DateTime.utc(2026, 8, 20),
        updatedAt: DateTime.utc(2026, 8, 20),
      ),
      originalSource: sourceBytes,
    );
  }

  GenerationRequest buildRequest({
    Map<String, Object?> submittedValues = const {'prompt-binding': 'a cat'},
    String? sourceContextId,
    bool useCharacterContext = false,
    Map<String, File> referenceImages = const {},
  }) => GenerationRequest(
    workflowId: 'workflow-1',
    kind: ComfyMediaKind.image,
    submittedValues: submittedValues,
    sourceContextId: sourceContextId,
    useCharacterContext: useCharacterContext,
    referenceImages: referenceImages,
  );

  group('submission', () {
    test(
      'persists submitting before one prompt POST and becomes uncertain on an unusable response',
      () async {
        await seedWorkflow();
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) => _jsonResponse({}),
        );
        final repository = repo(httpClient: client);

        final job = await repository.submit(buildRequest());
        expect(job.state, GenerationJobState.uncertain);
        expect(await jobStore.get(job.localId), isNotNull);
        expect(
          (await jobStore.get(job.localId))!.state,
          GenerationJobState.uncertain,
        );
        expect(client.promptRequests, 1);
      },
    );

    test('a definite non-2xx prompt error fails the job outright', () async {
      await seedWorkflow();
      final client = _ScriptedComfyClient(
        onPrompt: (request, body) => _jsonResponse({
          'error': {'message': 'graph invalid'},
          'node_errors': {'1': 'bad text'},
        }, statusCode: 400),
      );
      final repository = repo(httpClient: client);

      final job = await repository.submit(buildRequest());
      expect(job.state, GenerationJobState.failed);
      expect(job.error, 'graph invalid');
      expect(job.nodeErrors, {'1': 'bad text'});
    });

    test(
      'uploads a reference image and binds the server filename before submitting',
      () async {
        await seedWorkflow();
        final imageFile = File('${temp.path}/avatar.png')
          ..writeAsBytesSync(_pngBytes);
        var uploadedFirst = false;
        JsonObject? sentPrompt;
        final client = _ScriptedComfyClient(
          onUpload: (request, body) {
            uploadedFirst = true;
            return _jsonResponse({
              'name': 'server.png',
              'subfolder': 'uploads',
              'type': 'input',
            });
          },
          onPrompt: (request, body) {
            expect(uploadedFirst, isTrue);
            sentPrompt =
                (jsonDecode(utf8.decode(body))
                        as Map<String, dynamic>)['prompt']
                    as Map<String, dynamic>;
            return _jsonResponse({'prompt_id': 'p1', 'number': 1});
          },
        );
        final repository = repo(httpClient: client);

        final job = await repository.submit(
          buildRequest(referenceImages: {'image-binding': imageFile}),
        );
        expect(job.state, GenerationJobState.queued);
        expect(sentPrompt, isNotNull);
        expect(sentPrompt!['2']['inputs']['image'], 'uploads/server.png');
        await repository.dispose();
      },
    );

    test(
      'character context composes the prompt and attaches the avatar when enabled',
      () async {
        await seedWorkflow();
        final avatarPath = '${temp.path}/avatar-src.png';
        File(avatarPath).writeAsBytesSync(_pngBytes);
        await contextStore.save(
          CharacterGenerationContext(
            sessionId: 'session-1',
            characterName: 'Hermes',
            appearancePrompt: 'Silver hair and a blue coat.',
            createdAt: DateTime.utc(2026, 8, 20),
            updatedAt: DateTime.utc(2026, 8, 20),
          ),
          referenceImage: File(avatarPath),
        );

        JsonObject? sentPrompt;
        final client = _ScriptedComfyClient(
          onUpload: (request, body) => _jsonResponse({
            'name': 'avatar-server.png',
            'subfolder': '',
            'type': 'input',
          }),
          onPrompt: (request, body) {
            sentPrompt =
                (jsonDecode(utf8.decode(body))
                        as Map<String, dynamic>)['prompt']
                    as Map<String, dynamic>;
            return _jsonResponse({'prompt_id': 'p1', 'number': 1});
          },
        );
        final repository = repo(httpClient: client);

        final job = await repository.submit(
          buildRequest(
            submittedValues: {'prompt-binding': 'walking through rain'},
            sourceContextId: 'session-1',
            useCharacterContext: true,
          ),
        );

        expect(
          sentPrompt!['1']['inputs']['text'],
          'Silver hair and a blue coat.\n\nwalking through rain',
        );
        expect(sentPrompt!['2']['inputs']['image'], 'avatar-server.png');
        expect(
          job.submittedValues['prompt-binding'],
          'Silver hair and a blue coat.\n\nwalking through rain',
        );
        expect(job.sourceContextId, 'session-1');
        await repository.dispose();
      },
    );

    test(
      'character context is not applied unless useCharacterContext is true',
      () async {
        await seedWorkflow();
        await contextStore.save(
          CharacterGenerationContext(
            sessionId: 'session-1',
            characterName: 'Hermes',
            appearancePrompt: 'Silver hair.',
            createdAt: DateTime.utc(2026, 8, 20),
            updatedAt: DateTime.utc(2026, 8, 20),
          ),
        );
        JsonObject? sentPrompt;
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) {
            sentPrompt =
                (jsonDecode(utf8.decode(body))
                        as Map<String, dynamic>)['prompt']
                    as Map<String, dynamic>;
            return _jsonResponse({'prompt_id': 'p1', 'number': 1});
          },
        );
        final repository = repo(httpClient: client);
        await repository.submit(
          buildRequest(
            submittedValues: {'prompt-binding': 'walking through rain'},
            sourceContextId: 'session-1',
            useCharacterContext: false,
          ),
        );
        expect(sentPrompt!['1']['inputs']['text'], 'walking through rain');
        await repository.dispose();
      },
    );
  });

  group('recovery and reconciliation', () {
    test(
      'reconcilePending never resubmits a job saved without a prompt id',
      () async {
        await seedWorkflow();
        await jobStore.save(
          job(state: GenerationJobState.submitting, promptId: null),
        );
        final client = _ScriptedComfyClient();
        final repository = repo(httpClient: client);

        await repository.reconcilePending();

        final reloaded = await jobStore.get('job-1');
        expect(reloaded!.state, GenerationJobState.uncertain);
        expect(client.promptRequests, 0);
      },
    );

    test(
      'reconciliation prefers history over a stale queue snapshot',
      () async {
        await seedWorkflow();
        await jobStore.save(
          job(state: GenerationJobState.queued, promptId: 'p1'),
        );
        final client = _ScriptedComfyClient(
          onHistory: (request, body) => _jsonResponse({
            'p1': {
              'status': {'completed': true, 'status_str': 'success'},
              'outputs': {
                '9': {
                  'images': [
                    {'filename': 'r.png', 'subfolder': '', 'type': 'output'},
                  ],
                },
              },
            },
          }),
          onQueue: (request, body) => _jsonResponse({
            'queue_running': <Object?>[],
            'queue_pending': [
              [0, 'p1'],
            ],
          }),
        );
        final repository = repo(httpClient: client);

        await repository.reconcilePending();

        final reloaded = await jobStore.get('job-1');
        expect(reloaded!.state, GenerationJobState.succeeded);
        expect(reloaded.outputs.single.filename, 'r.png');
        await repository.dispose();
      },
    );

    test(
      'queue reconciliation confirms a still-pending job without history',
      () async {
        await seedWorkflow();
        await jobStore.save(
          job(state: GenerationJobState.reconciling, promptId: 'p1'),
        );
        final client = _ScriptedComfyClient(
          onQueue: (request, body) => _jsonResponse({
            'queue_running': <Object?>[],
            'queue_pending': [
              [0, 'p1'],
            ],
          }),
        );
        final repository = repo(httpClient: client);

        await repository.reconcilePending();

        final reloaded = await jobStore.get('job-1');
        expect(reloaded!.state, GenerationJobState.queued);
        await repository.dispose();
      },
    );

    test(
      'socket loss during observation moves the job to reconciling and resolves it',
      () async {
        await seedWorkflow();
        final transport = _FakeSocketTransport();
        final connector = _FakeConnector([transport]);
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) =>
              _jsonResponse({'prompt_id': 'p1', 'number': 1}),
          onHistory: (request, body) => _jsonResponse({
            'p1': {
              'status': {'completed': true, 'status_str': 'success'},
              'outputs': <String, Object?>{},
            },
          }),
        );
        final repository = repo(
          httpClient: client,
          socketFactory: _FakeSocketFactory(connector),
        );

        final job = await repository.submit(buildRequest());
        expect(job.state, GenerationJobState.queued);
        await transport.listened;
        await transport.messagesController.close();
        await waitForState(
          repository,
          job.localId,
          GenerationJobState.succeeded,
        );
        await repository.dispose();

        final reloaded = await jobStore.get(job.localId);
        expect(reloaded!.state, GenerationJobState.succeeded);
      },
    );

    test(
      'a terminal success is not undone by frames that arrive after it',
      () async {
        await seedWorkflow();
        final transport = _FakeSocketTransport();
        final connector = _FakeConnector([transport]);
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) =>
              _jsonResponse({'prompt_id': 'p1', 'number': 1}),
        );
        final repository = repo(
          httpClient: client,
          socketFactory: _FakeSocketFactory(connector),
        );

        final job = await repository.submit(buildRequest());
        await transport.listened;
        transport.messagesController.add(
          _frame('executed', {
            'node': '9',
            'output': {
              'images': [
                {'filename': 'r.png', 'subfolder': '', 'type': 'output'},
              ],
            },
          }),
        );
        transport.messagesController.add(_frame('execution_success', {}));
        transport.messagesController.add(
          _frame('execution_error', {'exception_message': 'late error'}),
        );
        await waitForState(
          repository,
          job.localId,
          GenerationJobState.succeeded,
        );
        await transport.messagesController.close();
        await repository.dispose();

        final reloaded = await jobStore.get(job.localId);
        expect(reloaded!.state, GenerationJobState.succeeded);
        expect(reloaded.outputs.single.filename, 'r.png');
      },
    );
  });

  group('cancellation', () {
    test('cancelling a queued job deletes only that queued prompt', () async {
      await seedWorkflow();
      await jobStore.save(
        job(state: GenerationJobState.queued, promptId: 'p1'),
      );
      Uint8List? deleteBody;
      final client = _ScriptedComfyClient(
        onDeleteQueued: (request, body) {
          deleteBody = body;
          return _jsonResponse({});
        },
      );
      final repository = repo(httpClient: client);

      await repository.cancel('job-1');

      expect(deleteBody, isNotNull);
      expect(jsonDecode(utf8.decode(deleteBody!)), {
        'delete': ['p1'],
      });
      final reloaded = await jobStore.get('job-1');
      expect(reloaded!.state, GenerationJobState.cancelled);
    });

    test(
      'cancelling a running job requires explicit shared-interrupt confirmation',
      () async {
        await seedWorkflow();
        await jobStore.save(
          job(state: GenerationJobState.running, promptId: 'p1'),
        );
        var interruptCalls = 0;
        final client = _ScriptedComfyClient(
          onInterrupt: (request, body) {
            interruptCalls++;
            return _jsonResponse({});
          },
        );
        final repository = repo(httpClient: client);

        await expectLater(() => repository.cancel('job-1'), throwsStateError);
        expect(interruptCalls, 0);
        expect(
          (await jobStore.get('job-1'))!.state,
          GenerationJobState.running,
        );

        await repository.cancel('job-1', confirmSharedInterrupt: true);
        expect(interruptCalls, 1);
        expect(
          (await jobStore.get('job-1'))!.state,
          GenerationJobState.cancelling,
        );
      },
    );

    test('a success that lands after cancellation still wins', () async {
      await seedWorkflow();
      final transport = _FakeSocketTransport();
      final connector = _FakeConnector([transport]);
      final client = _ScriptedComfyClient(
        onPrompt: (request, body) =>
            _jsonResponse({'prompt_id': 'p1', 'number': 1}),
        onInterrupt: (request, body) => _jsonResponse({}),
      );
      final repository = repo(
        httpClient: client,
        socketFactory: _FakeSocketFactory(connector),
      );

      final runningCompleter = Completer<void>();
      final subscription = repository.watchJobs().listen((jobs) {
        final running = jobs.any(
          (job) => job.state == GenerationJobState.running,
        );
        if (running && !runningCompleter.isCompleted) {
          runningCompleter.complete();
        }
      });

      final job = await repository.submit(buildRequest());
      await transport.listened;
      transport.messagesController.add(_frame('execution_start', {}));
      await runningCompleter.future;
      await subscription.cancel();

      await repository.cancel(job.localId, confirmSharedInterrupt: true);
      expect(
        (await jobStore.get(job.localId))!.state,
        GenerationJobState.cancelling,
      );

      transport.messagesController.add(_frame('execution_success', {}));
      await waitForState(repository, job.localId, GenerationJobState.succeeded);
      await transport.messagesController.close();
      await repository.dispose();

      final reloaded = await jobStore.get(job.localId);
      expect(reloaded!.state, GenerationJobState.succeeded);
    });
  });

  group('retry', () {
    test(
      'retryAsNew creates a new job id and resubmits the same values',
      () async {
        await seedWorkflow();
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) =>
              _jsonResponse({'prompt_id': 'p1', 'number': 1}),
        );
        final repository = repo(httpClient: client);

        final original = await repository.submit(buildRequest());
        final retried = await repository.retryAsNew(original.localId);

        expect(retried.localId, isNot(original.localId));
        expect(retried.workflowId, original.workflowId);
        expect(retried.submittedValues, original.submittedValues);
        await repository.dispose();
      },
    );
  });

  group('media indexing', () {
    test(
      'successful job outputs are indexed as media and deduped by identity',
      () async {
        await seedWorkflow();
        final transport = _FakeSocketTransport();
        final connector = _FakeConnector([transport]);
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) =>
              _jsonResponse({'prompt_id': 'p1', 'number': 1}),
        );
        final repository = repo(
          httpClient: client,
          socketFactory: _FakeSocketFactory(connector),
        );

        final job = await repository.submit(buildRequest());
        await transport.listened;
        transport.messagesController.add(
          _frame('executed', {
            'node': '9',
            'output': {
              'images': [
                {'filename': 'r.png', 'subfolder': '', 'type': 'output'},
              ],
            },
          }),
        );
        transport.messagesController.add(_frame('execution_success', {}));
        await waitForState(
          repository,
          job.localId,
          GenerationJobState.succeeded,
        );
        await transport.messagesController.close();
        await repository.dispose();

        final media = await mediaStore.list();
        expect(media, hasLength(1));
        expect(media.single.filename, 'r.png');
        expect(media.single.jobId, job.localId);

        await repository.upsertChatToolOutputs(
          endpoint: ComfyEndpoint.parse('http://host:8188'),
          sessionId: 'session-1',
          messages: [
            {'id': 'm1', 'role': 'tool', 'content': 'rendered: /out/r.png'},
          ],
        );
        final afterUpsert = await mediaStore.list();
        expect(afterUpsert, hasLength(1));
      },
    );

    test(
      'chat-tool output ingestion dedupes repeated filenames across messages',
      () async {
        final client = _ScriptedComfyClient();
        final repository = repo(httpClient: client);
        final endpoint = ComfyEndpoint.parse('http://host:8188');

        await repository.upsertChatToolOutputs(
          endpoint: endpoint,
          sessionId: 'session-1',
          messages: [
            {
              'id': 'm1',
              'role': 'tool',
              'content': 'rendered: /out/shared.png',
            },
            {
              'id': 'm2',
              'role': 'tool',
              'content': 'rendered: /out/shared.png',
            },
            {
              'id': 'm3',
              'role': 'user',
              'content': 'not a tool message /out/shared.png',
            },
          ],
        );

        final media = await mediaStore.list();
        expect(media, hasLength(1));
        expect(media.single.sourceMessageId, 'm2');
      },
    );
  });

  group('foreground lease balance', () {
    test(
      'the lease is acquired once per observation and released exactly once',
      () async {
        await seedWorkflow();
        final transport = _FakeSocketTransport();
        final connector = _FakeConnector([transport]);
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) =>
              _jsonResponse({'prompt_id': 'p1', 'number': 1}),
          onHistory: (request, body) => _jsonResponse({
            'p1': {
              'status': {'completed': true, 'status_str': 'success'},
              'outputs': <String, Object?>{},
            },
          }),
        );
        final repository = repo(
          httpClient: client,
          socketFactory: _FakeSocketFactory(connector),
        );

        final submitted = await repository.submit(buildRequest());
        await transport.listened;
        transport.messagesController.add(_frame('execution_success', {}));
        await waitForState(
          repository,
          submitted.localId,
          GenerationJobState.succeeded,
        );
        await transport.messagesController.close();
        await repository.dispose();

        expect(foregroundLease.acquireCalls, 1);
        expect(foregroundLease.releaseCalls, 1);
      },
    );

    test(
      'the lease is released even when submission fails before a prompt id',
      () async {
        await seedWorkflow();
        final client = _ScriptedComfyClient(
          onPrompt: (request, body) => _jsonResponse({}),
        );
        final repository = repo(httpClient: client);

        await repository.submit(buildRequest());

        expect(foregroundLease.acquireCalls, 1);
        expect(foregroundLease.releaseCalls, 1);
      },
    );
  });
}

/// Waits for [jobId] to reach [state] through [repository.watchJobs()],
/// rather than using [DefaultGenerationRepository.dispose] as a completion
/// barrier: dispose() eagerly cancels active observers as part of a forced
/// shutdown, which can race ahead of and swallow an in-flight terminal
/// event delivered through the fake socket transport (the loss/success
/// event is added asynchronously relative to closing/pushing on the raw
/// transport stream).
Future<GenerationJob> waitForState(
  GenerationRepository repository,
  String jobId,
  GenerationJobState state,
) async {
  final completer = Completer<GenerationJob>();
  final subscription = repository.watchJobs().listen((jobs) {
    for (final job in jobs) {
      if (job.localId == jobId &&
          job.state == state &&
          !completer.isCompleted) {
        completer.complete(job);
      }
    }
  });
  try {
    return await completer.future;
  } finally {
    await subscription.cancel();
  }
}

GenerationJob job({
  required GenerationJobState state,
  String? promptId,
  String localId = 'job-1',
}) => GenerationJob(
  localId: localId,
  workflowId: 'workflow-1',
  kind: ComfyMediaKind.image,
  state: state,
  endpointFingerprint: 'fp',
  endpointSnapshot: 'http://host:8188',
  submittedValues: const {'prompt-binding': 'seeded'},
  promptId: promptId,
  createdAt: DateTime.utc(2026, 8, 20, 10),
  updatedAt: DateTime.utc(2026, 8, 20, 10),
);

String _frame(String type, Map<String, Object?> data) =>
    jsonEncode({'type': type, 'data': data});

http.StreamedResponse _jsonResponse(Object? value, {int statusCode = 200}) {
  final body = utf8.encode(jsonEncode(value));
  return http.StreamedResponse(
    Stream<List<int>>.value(body),
    statusCode,
    contentLength: body.length,
    headers: const {'content-type': 'application/json'},
  );
}

final Uint8List _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0, 0, 0, 0,
]);

final class _FakeEndpointConfig implements ComfyEndpointConfig {
  ComfyEndpoint? endpoint = ComfyEndpoint.parse('http://host:8188');
  String clientId = 'stable-client-id';

  @override
  Future<ComfyEndpoint?> load() async => endpoint;

  @override
  Future<String> stableClientId() async => clientId;
}

final class _FakeClientFactory implements ComfyUiClientFactory {
  _FakeClientFactory(this.httpClient);

  final http.Client httpClient;

  @override
  ComfyUiClient create({
    required ComfyEndpoint endpoint,
    required String clientId,
  }) => ComfyUiClient(
    endpoint: endpoint,
    clientId: clientId,
    httpClient: httpClient,
    connectTimeout: const Duration(seconds: 5),
    idleTimeout: const Duration(seconds: 5),
  );
}

final class _FakeMediaCache implements MediaCachePort {
  final List<Uri> removed = [];

  @override
  Future<File?> cache(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async => null;

  @override
  Future<void> remove(Uri uri) async {
    removed.add(uri);
  }
}

final class _FakeForegroundLease implements ForegroundLeasePort {
  int acquireCalls = 0;
  int releaseCalls = 0;
  bool acquireResult = true;

  @override
  Future<bool> acquire({required String notificationText}) async {
    acquireCalls++;
    return acquireResult;
  }

  @override
  Future<void> release() async {
    releaseCalls++;
  }
}

final class _ScriptedComfyClient extends http.BaseClient {
  _ScriptedComfyClient({
    this.onPrompt,
    this.onUpload,
    this.onQueue,
    this.onHistory,
    this.onInterrupt,
    this.onDeleteQueued,
  });

  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )?
  onPrompt;
  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )?
  onUpload;
  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )?
  onQueue;
  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )?
  onHistory;
  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )?
  onInterrupt;
  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )?
  onDeleteQueued;

  final List<http.BaseRequest> requests = [];
  int promptRequests = 0;
  int _promptSequence = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    requests.add(request);
    final path = request.url.path;

    if (path.endsWith('/prompt') && request.method == 'POST') {
      promptRequests++;
      if (onPrompt != null) return onPrompt!(request, body);
      return _jsonResponse({
        'prompt_id': 'prompt-${_promptSequence++}',
        'number': 1,
      });
    }
    if (path.endsWith('/upload/image')) {
      if (onUpload != null) return onUpload!(request, body);
      return _jsonResponse({
        'name': 'uploaded.png',
        'subfolder': '',
        'type': 'input',
      });
    }
    if (path.endsWith('/queue') && request.method == 'GET') {
      if (onQueue != null) return onQueue!(request, body);
      return _jsonResponse({
        'queue_running': <Object?>[],
        'queue_pending': <Object?>[],
      });
    }
    if (path.endsWith('/queue') && request.method == 'POST') {
      if (onDeleteQueued != null) return onDeleteQueued!(request, body);
      return _jsonResponse({});
    }
    if (path.contains('/history/')) {
      if (onHistory != null) return onHistory!(request, body);
      return _jsonResponse({});
    }
    if (path.endsWith('/interrupt')) {
      if (onInterrupt != null) return onInterrupt!(request, body);
      return _jsonResponse({});
    }
    return _jsonResponse({});
  }
}

final class _FakeSocketFactory implements ComfyUiSocketFactory {
  _FakeSocketFactory(this.connector);

  final _FakeConnector connector;

  @override
  ComfyUiSocket create() => ComfyUiSocket(connector: connector);
}

final class _FakeSocketTransport implements ComfySocketTransport {
  _FakeSocketTransport() {
    messagesController = StreamController<Object?>(
      onListen: () {
        if (!_listened.isCompleted) _listened.complete();
      },
    );
  }

  late final StreamController<Object?> messagesController;
  final Completer<void> _listened = Completer<void>();

  /// Resolves once the socket layer has actually subscribed to [messages].
  /// [ComfyUiSocketFactory.create]'s connect() call resolving is not enough
  /// synchronization on its own -- it completes before the subscription is
  /// attached, so pushing frames or closing right after it can race ahead
  /// of the listener and get buffered/lost.
  Future<void> get listened => _listened.future;

  @override
  Stream<Object?> get messages => messagesController.stream;

  @override
  Future<void> close() async {
    if (!messagesController.isClosed) await messagesController.close();
  }
}

final class _FakeConnector implements ComfySocketConnector {
  _FakeConnector(List<_FakeSocketTransport> transports)
    : _transports = List.of(transports);

  _FakeConnector.pending() : _transports = [];

  final List<_FakeSocketTransport> _transports;
  final Completer<void> _firstConnection = Completer<void>();

  Future<void> get firstConnection => _firstConnection.future;

  @override
  Future<ComfySocketTransport> connect(Uri uri) async {
    if (!_firstConnection.isCompleted) _firstConnection.complete();
    if (_transports.isEmpty) throw StateError('No fake transport available');
    return _transports.removeAt(0);
  }
}
