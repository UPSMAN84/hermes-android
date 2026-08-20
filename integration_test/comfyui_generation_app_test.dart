// Device-level proof that the production ComfyUI generation stack -- the
// real DefaultGenerationRepository, its on-disk stores, the real ComfyUiClient
// and ComfyUiSocket protocol classes, CreateScreen, GenerationForm,
// GenerationJobCard, MediaGalleryScreen, and GeneratedMediaView -- work
// together against a real HTTP/WebSocket server and real disk persistence.
// Everything below it (chat_screen.dart's Create/Discuss wiring, the gallery
// filter/delete UI, GeneratedMediaView's playback states) already has
// widget-level coverage with in-memory fakes; what only a device test can
// prove is that swapping those fakes for the real classes still works end
// to end.
//
// This test does NOT drive the app through HomeScreen/SessionListScreen/
// ChatScreen chrome -- that would additionally require faking the Gateway
// HTTP API, which is unrelated backend surface outside this feature's scope
// (chat_screen_test.dart already covers the Create/Discuss handoff at the
// chat-screen level with fakes). It pumps CreateScreen and MediaGalleryScreen
// directly, which is where all of this feature's real logic lives.
//
// Run with an explicit device: `flutter test integration_test -d <device-id>`.
// As of this commit it has been written and statically analyzed but not run
// against a device -- no emulator/phone was available in the environment
// that authored it. Treat it as unverified until it has actually been run.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/create_screen.dart';
import 'package:hermes_android/core/screens/media_gallery_screen.dart';
import 'package:hermes_android/core/services/background_activity_service.dart';
import 'package:hermes_android/core/services/character_generation_context_store.dart';
import 'package:hermes_android/core/services/comfyui_socket.dart';
import 'package:hermes_android/core/services/generation_job_store.dart';
import 'package:hermes_android/core/services/generation_repository.dart';
import 'package:hermes_android/core/services/generation_repository_host.dart';
import 'package:hermes_android/core/services/media_asset_store.dart';
import 'package:hermes_android/core/services/media_cache_service.dart';
import 'package:hermes_android/core/services/workflow_store.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeComfyServer server;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hermes-integration-');
    server = await _FakeComfyServer.start();
  });

  tearDown(() async {
    await server.close();
    await root.delete(recursive: true);
  });

  Future<DefaultGenerationRepository> openRepository() async {
    final repository = DefaultGenerationRepository(
      endpointConfig: _FixedEndpointConfig(server.endpoint),
      clientFactory: const DefaultComfyUiClientFactory(),
      socketFactory: const DefaultComfyUiSocketFactory(),
      workflowStore: WorkflowStore(root: root),
      jobStore: GenerationJobStore(root: root),
      mediaStore: MediaAssetStore(root: root),
      contextStore: CharacterGenerationContextStore(root: root),
      mediaCache: MediaCacheService.appDefault,
      foregroundLease: const GenerationForegroundLease(),
      clock: DateTime.now,
    );
    await repository.initialize();
    return repository;
  }

  Future<void> seedImageWorkflow(WorkflowStore workflowStore) async {
    final graph = <String, Object?>{
      '1': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'default prompt'},
      },
    };
    final sourceBytes = Uint8List.fromList(utf8.encode(jsonEncode(graph)));
    await workflowStore.save(
      ComfyWorkflowDefinition(
        id: 'workflow-1',
        name: 'Integration workflow',
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
            defaultValue: '',
          ),
        ],
        createdAt: DateTime.utc(2026, 8, 20),
        updatedAt: DateTime.utc(2026, 8, 20),
      ),
      originalSource: sourceBytes,
    );
  }

  final connection = SavedConnection(
    id: 'c1',
    label: 'Integration',
    host: 'localhost',
    port: 8642,
    apiKey: 'k',
  );

  testWidgets(
    'Create submits a real prompt through the real repository/protocol '
    'stack to a succeeded job with a rendered output',
    (tester) async {
      await seedImageWorkflow(WorkflowStore(root: root));
      final repository = await openRepository();
      addTearDown(repository.dispose);

      server.promptResponse = {'prompt_id': 'p1', 'number': 1};
      server.wsFrames = [
        jsonEncode({
          'type': 'executing',
          'data': {'node': '1', 'prompt_id': 'p1'},
        }),
        jsonEncode({
          'type': 'executed',
          'data': {
            'node': '1',
            'prompt_id': 'p1',
            'output': {
              'images': [
                {'filename': 'render.png', 'subfolder': '', 'type': 'output'},
              ],
            },
          },
        }),
        jsonEncode({
          'type': 'execution_success',
          'data': {'prompt_id': 'p1'},
        }),
      ];
      server.viewResponses['render.png'] = _pngBytes;

      await tester.pumpWidget(
        MaterialApp(
          home: CreateScreen(connection: connection, repository: repository),
        ),
      );
      // Repository resolution + workflow stream subscription.
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('binding-prompt')),
        'an integration-test cat',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Generate'));

      // Bounded pumps rather than pumpAndSettle: the succeeded job's thumbnail
      // sits on a real network image fetch against the loopback fake server,
      // which can outlast a single settle pass.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text('Done').evaluate().isNotEmpty) break;
      }

      expect(find.text('Done'), findsOneWidget);
      expect(server.requestPaths, contains('/proxy/prompt'));

      final media = await repository.watchMedia().first;
      expect(media.single.filename, 'render.png');
    },
  );

  testWidgets(
    'a succeeded job survives repository disposal and reopening against the '
    'same on-disk store (stand-in for an app restart)',
    (tester) async {
      await seedImageWorkflow(WorkflowStore(root: root));
      var repository = await openRepository();
      server.promptResponse = {'prompt_id': 'p1', 'number': 1};
      server.wsFrames = [
        jsonEncode({
          'type': 'executed',
          'data': {
            'node': '1',
            'prompt_id': 'p1',
            'output': {
              'images': [
                {'filename': 'render.png', 'subfolder': '', 'type': 'output'},
              ],
            },
          },
        }),
        jsonEncode({
          'type': 'execution_success',
          'data': {'prompt_id': 'p1'},
        }),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: CreateScreen(connection: connection, repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('binding-prompt')),
        'restart me',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text('Done').evaluate().isNotEmpty) break;
      }
      expect(find.text('Done'), findsOneWidget);

      await repository.dispose();
      repository = await openRepository();
      addTearDown(repository.dispose);

      final jobs = await repository.watchJobs().first;
      final media = await repository.watchMedia().first;
      expect(jobs.single.state.name, 'succeeded');
      expect(media.single.filename, 'render.png');
    },
  );

  testWidgets(
    'the global Media library renders a generated asset from the real '
    'repository',
    (tester) async {
      await seedImageWorkflow(WorkflowStore(root: root));
      final repository = await openRepository();
      addTearDown(repository.dispose);
      server.promptResponse = {'prompt_id': 'p1', 'number': 1};
      server.wsFrames = [
        jsonEncode({
          'type': 'executed',
          'data': {
            'node': '1',
            'prompt_id': 'p1',
            'output': {
              'images': [
                {'filename': 'gallery.png', 'subfolder': '', 'type': 'output'},
              ],
            },
          },
        }),
        jsonEncode({
          'type': 'execution_success',
          'data': {'prompt_id': 'p1'},
        }),
      ];
      server.viewResponses['gallery.png'] = _pngBytes;

      await tester.pumpWidget(
        MaterialApp(
          home: CreateScreen(connection: connection, repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('binding-prompt')),
        'for the gallery',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text('Done').evaluate().isNotEmpty) break;
      }
      expect(find.text('Done'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(home: MediaGalleryScreen(repository: repository)),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(find.text('Media (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Discuss in chat pops the succeeded image as a DiscussGeneratedImage '
    'result',
    (tester) async {
      await seedImageWorkflow(WorkflowStore(root: root));
      final repository = await openRepository();
      addTearDown(repository.dispose);
      server.promptResponse = {'prompt_id': 'p1', 'number': 1};
      server.wsFrames = [
        jsonEncode({
          'type': 'executed',
          'data': {
            'node': '1',
            'prompt_id': 'p1',
            'output': {
              'images': [
                {'filename': 'discuss.png', 'subfolder': '', 'type': 'output'},
              ],
            },
          },
        }),
        jsonEncode({
          'type': 'execution_success',
          'data': {'prompt_id': 'p1'},
        }),
      ];

      CreateScreenResult? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<CreateScreenResult>(
                  MaterialPageRoute(
                    builder: (_) => CreateScreen(
                      connection: connection,
                      repository: repository,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('binding-prompt')),
        'discuss me',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text('Done').evaluate().isNotEmpty) break;
      }
      expect(find.text('Done'), findsOneWidget);

      await tester.tap(find.byTooltip('Discuss in chat'));
      await tester.pumpAndSettle();

      expect(popped, isA<DiscussGeneratedImage>());
      expect((popped as DiscussGeneratedImage).asset.filename, 'discuss.png');
    },
  );
}

final _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0, 0, 0, 0, 0, 0, 0, 0,
]);

final class _FixedEndpointConfig implements ComfyEndpointConfig {
  const _FixedEndpointConfig(this._endpoint);

  final ComfyEndpoint _endpoint;

  @override
  Future<ComfyEndpoint?> load() async => _endpoint;

  @override
  Future<String> stableClientId() async => 'integration-test-client';
}

/// A minimal scriptable ComfyUI stand-in, reachable only over the IPv4
/// loopback and served under a `/proxy` prefix. Trimmed to what the Create
/// generation flow actually calls: prompt submission, the execution
/// WebSocket, and serving generated bytes back through `/view`.
class _FakeComfyServer {
  _FakeComfyServer._(this._server);

  static const _prefix = '/proxy';

  final HttpServer _server;
  final List<String> requestPaths = [];
  Map<String, dynamic> promptResponse = {'prompt_id': 'p1', 'number': 1};
  List<String> wsFrames = [];
  final Map<String, Uint8List> viewResponses = {};

  ComfyEndpoint get endpoint =>
      ComfyEndpoint.parse('http://127.0.0.1:${_server.port}$_prefix');

  static Future<_FakeComfyServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeComfyServer._(server);
    unawaited(fake._serve());
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requestPaths.add(path);
    if (!path.startsWith(_prefix)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final leaf = path.substring(_prefix.length);

    if (leaf == '/ws') {
      final socket = await WebSocketTransformer.upgrade(request);
      for (final frame in wsFrames) {
        socket.add(frame);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return;
    }
    if (leaf == '/prompt' && request.method == 'POST') {
      await utf8.decoder.bind(request).join();
      return _respondJson(request, promptResponse);
    }
    if (leaf == '/queue' && request.method == 'GET') {
      return _respondJson(request, {
        'queue_running': <Object?>[],
        'queue_pending': <Object?>[],
      });
    }
    if (leaf.startsWith('/history/') && request.method == 'GET') {
      // The socket-driven path above already carries execution to a
      // terminal event; history isn't consulted for this flow so an empty
      // record is enough to satisfy any incidental poll.
      return _respondJson(request, {});
    }
    if (leaf == '/view' && request.method == 'GET') {
      final filename = request.uri.queryParameters['filename'];
      final bytes = filename == null ? null : viewResponses[filename];
      if (bytes == null) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(bytes);
      await request.response.close();
      return;
    }

    request.response.statusCode = 404;
    await request.response.close();
  }

  Future<void> _respondJson(HttpRequest request, Object? body) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}
