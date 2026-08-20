import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/character_generation_context.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/models/media_asset.dart';
import 'package:hermes_android/core/screens/settings_screen.dart';
import 'package:hermes_android/core/services/comfyui_client.dart';
import 'package:hermes_android/core/services/generation_repository.dart';
import 'package:hermes_android/core/services/workflow_document_port.dart';
import 'package:hermes_android/core/widgets/workflow_library_tab.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('WorkflowLibraryTab', () {
    late _FakeGenerationRepository repository;
    late _FakeWorkflowDocumentPort documents;

    setUp(() {
      repository = _FakeGenerationRepository();
      documents = _FakeWorkflowDocumentPort();
    });

    Widget harness() => MaterialApp(
      home: Scaffold(
        body: WorkflowLibraryTab(
          repository: repository,
          documents: documents,
          clock: () => DateTime.utc(2026, 8, 20),
        ),
      ),
    );

    testWidgets('import keeps source bytes and requires confirmed bindings', (
      tester,
    ) async {
      documents.importedBytes = _workflowBytes;
      documents.importedFileName = 'my-workflow.json';

      await tester.pumpWidget(harness());
      await tester.tap(find.text('Import workflow'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm inputs'), findsOneWidget);
      expect(repository.savedWorkflows, isEmpty);
    });

    testWidgets('confirming import saves the workflow', (tester) async {
      documents.importedBytes = _workflowBytes;
      documents.importedFileName = 'my-workflow.json';

      await tester.pumpWidget(harness());
      await tester.tap(find.text('Import workflow'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm inputs'));
      await tester.pumpAndSettle();

      expect(repository.savedWorkflows, hasLength(1));
      final saved = repository.savedWorkflows.single;
      expect(saved.name, 'my-workflow.json');
      expect(saved.sourceHash, isNotEmpty);
      expect(repository.savedSourceBytes[saved.id], _workflowBytes);
    });

    testWidgets('paste decodes clipboard JSON through the same flow', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': utf8.decode(_workflowBytes)};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(harness());
      await tester.tap(find.text('Paste workflow JSON'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm inputs'), findsOneWidget);
    });

    testWidgets('an oversized import is rejected before the confirm dialog', (
      tester,
    ) async {
      documents.importedBytes = Uint8List(6 * 1024 * 1024);
      documents.importedFileName = 'huge.json';

      await tester.pumpWidget(harness());
      await tester.tap(find.text('Import workflow'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm inputs'), findsNothing);
      expect(find.textContaining('Invalid workflow JSON'), findsOneWidget);
      expect(repository.savedWorkflows, isEmpty);
    });

    testWidgets('local validation reports the issue count', (tester) async {
      await repository.saveWorkflow(
        _savedWorkflow,
        sourceBytes: _workflowBytes,
      );
      repository.nextLocalValidation = const WorkflowValidationResult(
        issues: [WorkflowValidationIssue(code: 'missing_node', message: 'bad')],
      );

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Validate locally'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 issue(s)'), findsWidgets);
    });

    testWidgets('server validation reports failure reasons', (tester) async {
      await repository.saveWorkflow(
        _savedWorkflow,
        sourceBytes: _workflowBytes,
      );
      repository.serverValidationError = StateError(
        'ComfyUI is not configured',
      );

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Validate against server'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Server validation failed'), findsOneWidget);
    });

    testWidgets('exports the original source and working graph', (
      tester,
    ) async {
      await repository.saveWorkflow(
        _savedWorkflow,
        sourceBytes: _workflowBytes,
      );

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export original source'));
      await tester.pumpAndSettle();

      expect(documents.savedFileNames.single, contains('.source.json'));
      expect(documents.savedBytes.single, _workflowBytes);

      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export working graph'));
      await tester.pumpAndSettle();

      expect(documents.savedFileNames, hasLength(2));
      expect(documents.savedFileNames[1], contains('.graph.json'));
    });

    testWidgets('delete requires confirmation and only removes on confirm', (
      tester,
    ) async {
      await repository.saveWorkflow(
        _savedWorkflow,
        sourceBytes: _workflowBytes,
      );

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete workflow?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.savedWorkflows, hasLength(1));

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repository.savedWorkflows, isEmpty);
    });
  });

  group('ComfyEndpointSettings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    Widget harness({
      required http.Client httpClient,
      _FakeLauncher? launcher,
      _FakeClipboard? clipboard,
    }) => MaterialApp(
      home: Scaffold(
        body: ComfyEndpointSettings(
          clientFactory: _FakeClientFactory(httpClient),
          launcher: launcher ?? _FakeLauncher(opens: true),
          clipboard: clipboard ?? _FakeClipboard(),
        ),
      ),
    );

    testWidgets('invalid endpoint is not saved and the reason is reported', (
      tester,
    ) async {
      await tester.pumpWidget(harness(httpClient: _RecordingClient()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('comfy-endpoint')),
        'ftp://host',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('HTTP or HTTPS'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('comfyui_base_url'), isNull);
    });

    testWidgets('a private LAN address saves without acknowledgement', (
      tester,
    ) async {
      await tester.pumpWidget(harness(httpClient: _RecordingClient()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('comfy-endpoint')),
        'http://192.168.1.50:8188',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      // Flush the "Saved" checkmark's 2-second Timer.delayed before the
      // test ends -- pumpAndSettle() only waits for scheduled frames, not
      // arbitrary Timers, so a still-pending one fails teardown.
      await tester.pump(const Duration(seconds: 3));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('comfyui_base_url'), 'http://192.168.1.50:8188');
      expect(find.byKey(const Key('comfy-plain-http-ack')), findsNothing);
    });

    testWidgets(
      'a public plain-HTTP address requires acknowledgement before saving',
      (tester) async {
        await tester.pumpWidget(harness(httpClient: _RecordingClient()));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('comfy-endpoint')),
          'http://203.0.113.9:8188',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        var prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('comfyui_base_url'), isNull);
        expect(find.byKey(const Key('comfy-plain-http-ack')), findsOneWidget);

        await tester.tap(find.byKey(const Key('comfy-plain-http-ack')));
        await tester.tap(find.text('Save'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 3));

        prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('comfyui_base_url'), 'http://203.0.113.9:8188');
      },
    );

    testWidgets('test connection reports server info on success', (
      tester,
    ) async {
      final client = _RecordingClient(
        (request, body) => _jsonResponse({
          'system': {'comfyui_version': '0.3.50'},
          'devices': <Object?>[
            {'name': 'gpu0'},
          ],
        }),
      );
      await tester.pumpWidget(harness(httpClient: client));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('comfy-endpoint')),
        'http://192.168.1.50:8188',
      );
      await tester.tap(find.text('Test connection'));
      // pumpAndSettle() would spin forever here: the "testing" state shows
      // an indeterminate CircularProgressIndicator, which keeps scheduling
      // frames for as long as it's on screen regardless of whether the
      // underlying future has resolved.
      await _pumpUntilNotTesting(tester);

      expect(find.textContaining('Connected'), findsOneWidget);
      expect(find.textContaining('0.3.50'), findsOneWidget);
    });

    testWidgets('test connection reports the failure reason', (tester) async {
      final client = _RecordingClient(
        (request, body) => _jsonResponse({
          'error': {'message': 'boom'},
        }, statusCode: 500),
      );
      await tester.pumpWidget(harness(httpClient: client));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('comfy-endpoint')),
        'http://192.168.1.50:8188',
      );
      await tester.tap(find.text('Test connection'));
      // pumpAndSettle() would spin forever here: the "testing" state shows
      // an indeterminate CircularProgressIndicator, which keeps scheduling
      // frames for as long as it's on screen regardless of whether the
      // underlying future has resolved.
      await _pumpUntilNotTesting(tester);

      expect(find.textContaining('Connection failed'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
    });

    testWidgets('open falls back to clipboard when nothing can open it', (
      tester,
    ) async {
      final launcher = _FakeLauncher(opens: false);
      final clipboard = _FakeClipboard();
      await tester.pumpWidget(
        harness(
          httpClient: _RecordingClient(),
          launcher: launcher,
          clipboard: clipboard,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('comfy-endpoint')),
        'http://192.168.1.50:8188',
      );
      await tester.tap(find.text('Open ComfyUI'));
      await tester.pumpAndSettle();

      expect(launcher.opened.single.toString(), 'http://192.168.1.50:8188');
      expect(clipboard.copied.single.toString(), 'http://192.168.1.50:8188');
      expect(find.textContaining('copied instead'), findsOneWidget);
    });

    testWidgets('open does not fall back when the launcher succeeds', (
      tester,
    ) async {
      final launcher = _FakeLauncher(opens: true);
      final clipboard = _FakeClipboard();
      await tester.pumpWidget(
        harness(
          httpClient: _RecordingClient(),
          launcher: launcher,
          clipboard: clipboard,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('comfy-endpoint')),
        'http://192.168.1.50:8188',
      );
      await tester.tap(find.text('Open ComfyUI'));
      await tester.pumpAndSettle();

      expect(launcher.opened, hasLength(1));
      expect(clipboard.copied, isEmpty);
    });
  });
}

final Uint8List _workflowBytes = Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      '1': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'a cat'},
      },
    }),
  ),
);

final ComfyWorkflowDefinition _savedWorkflow = ComfyWorkflowDefinition(
  id: 'workflow-1',
  name: 'Saved workflow',
  kind: ComfyMediaKind.image,
  workingGraph: {
    '1': {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': 'a cat'},
    },
  },
  sourceHash: 'hash',
  sourceFileName: 'saved.json',
  bindings: const [],
  createdAt: DateTime.utc(2026, 8, 20),
  updatedAt: DateTime.utc(2026, 8, 20),
);

final class _FakeWorkflowDocumentPort implements WorkflowDocumentPort {
  Uint8List? importedBytes;
  String importedFileName = 'workflow.json';
  final List<String> savedFileNames = [];
  final List<Uint8List> savedBytes = [];

  @override
  Future<ImportedWorkflowDocument?> pickJson() async {
    final bytes = importedBytes;
    if (bytes == null) return null;
    return ImportedWorkflowDocument(fileName: importedFileName, bytes: bytes);
  }

  @override
  Future<void> saveJson({
    required String fileName,
    required Uint8List bytes,
  }) async {
    savedFileNames.add(fileName);
    savedBytes.add(bytes);
  }
}

final class _FakeGenerationRepository implements GenerationRepository {
  final Map<String, ComfyWorkflowDefinition> _workflows = {};
  final Map<String, Uint8List> savedSourceBytes = {};
  final Set<MultiStreamController<List<ComfyWorkflowDefinition>>>
  _workflowListeners = {};
  WorkflowValidationResult? nextLocalValidation;
  WorkflowValidationResult? nextServerValidation;
  Object? serverValidationError;

  List<ComfyWorkflowDefinition> get savedWorkflows =>
      _workflows.values.toList(growable: false);

  // A plain broadcast StreamController drops any event added before a
  // listener attaches, so a workflow seeded before pumpWidget() would never
  // reach the widget's initState() subscription -- replay the current
  // snapshot to every new listener, matching DefaultGenerationRepository's
  // real watch* semantics.
  void _emit() {
    final snapshot = savedWorkflows;
    for (final controller in _workflowListeners.toList(growable: false)) {
      controller.add(snapshot);
    }
  }

  @override
  Future<void> initialize() async {}

  @override
  Stream<List<ComfyWorkflowDefinition>> watchWorkflows() =>
      Stream<List<ComfyWorkflowDefinition>>.multi((controller) {
        controller.add(savedWorkflows);
        _workflowListeners.add(controller);
        controller.onCancel = () => _workflowListeners.remove(controller);
      }, isBroadcast: true);

  @override
  Stream<List<GenerationJob>> watchJobs() => const Stream.empty();

  @override
  Stream<List<MediaAsset>> watchMedia() => const Stream.empty();

  @override
  Stream<CharacterGenerationContext?> watchCharacterContext(String sessionId) =>
      const Stream.empty();

  @override
  Future<GenerationJob> submit(GenerationRequest request) =>
      throw UnimplementedError();

  @override
  Future<void> cancel(
    String localJobId, {
    bool confirmSharedInterrupt = false,
  }) => throw UnimplementedError();

  @override
  Future<GenerationJob> retryAsNew(String localJobId) =>
      throw UnimplementedError();

  @override
  Future<void> reconcilePending() async {}

  @override
  Future<ComfyWorkflowDefinition?> getWorkflow(String workflowId) async =>
      _workflows[workflowId];

  @override
  Future<void> saveWorkflow(
    ComfyWorkflowDefinition workflow, {
    required Uint8List sourceBytes,
  }) async {
    _workflows[workflow.id] = workflow;
    savedSourceBytes[workflow.id] = sourceBytes;
    _emit();
  }

  @override
  Future<ComfyWorkflowDefinition> duplicateWorkflow(
    String workflowId, {
    required String name,
  }) async {
    final source = _workflows[workflowId]!;
    final duplicate = source.copyWith(name: name);
    _workflows['$workflowId-dup'] = ComfyWorkflowDefinition(
      id: '$workflowId-dup',
      name: duplicate.name,
      kind: duplicate.kind,
      workingGraph: duplicate.workingGraph,
      sourceHash: duplicate.sourceHash,
      sourceFileName: duplicate.sourceFileName,
      bindings: duplicate.bindings,
      createdAt: duplicate.createdAt,
      updatedAt: duplicate.updatedAt,
    );
    savedSourceBytes['$workflowId-dup'] = savedSourceBytes[workflowId]!;
    _emit();
    return _workflows['$workflowId-dup']!;
  }

  @override
  Future<WorkflowValidationResult> validateWorkflow(
    String workflowId, {
    required bool againstServer,
  }) async {
    if (againstServer) {
      final error = serverValidationError;
      if (error != null) throw error;
      return nextServerValidation ?? const WorkflowValidationResult(issues: []);
    }
    return nextLocalValidation ?? const WorkflowValidationResult(issues: []);
  }

  @override
  Future<Uint8List> exportWorkflow(
    String workflowId,
    WorkflowExportKind kind,
  ) async {
    switch (kind) {
      case WorkflowExportKind.originalSource:
        return savedSourceBytes[workflowId]!;
      case WorkflowExportKind.workingGraph:
        return Uint8List.fromList(
          utf8.encode(jsonEncode(_workflows[workflowId]!.workingGraph)),
        );
      case WorkflowExportKind.hermesSidecar:
        return Uint8List.fromList(
          utf8.encode(jsonEncode(_workflows[workflowId]!.toJson())),
        );
    }
  }

  @override
  Future<void> deleteWorkflow(String workflowId) async {
    _workflows.remove(workflowId);
    savedSourceBytes.remove(workflowId);
    _emit();
  }

  @override
  Future<void> removeMedia(String assetId, {required bool clearCache}) async {}

  @override
  Future<CharacterGenerationContext?> getCharacterContext(
    String sessionId,
  ) async => null;

  @override
  Future<void> saveCharacterContext(
    CharacterGenerationContext context, {
    File? referenceImage,
  }) async {}

  @override
  Future<void> deleteCharacterContext(String sessionId) async {}

  @override
  Future<void> upsertChatToolOutputs({
    required ComfyEndpoint endpoint,
    required String sessionId,
    required List<JsonObject> messages,
  }) async {}

  @override
  Future<void> dispose() async {
    for (final controller in _workflowListeners.toList(growable: false)) {
      await controller.close();
    }
    _workflowListeners.clear();
  }
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

final class _FakeLauncher implements ExternalUriLauncher {
  _FakeLauncher({required this.opens});

  final bool opens;
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return opens;
  }
}

final class _FakeClipboard implements UriClipboardPort {
  final List<Uri> copied = [];

  @override
  Future<void> copy(Uri uri) async {
    copied.add(uri);
  }
}

final class _RecordedRequest {
  const _RecordedRequest(this.request, this.body);

  final http.BaseRequest request;
  final Uint8List body;
}

final class _RecordingClient extends http.BaseClient {
  _RecordingClient([this.handler]);

  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )?
  handler;
  final List<_RecordedRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    requests.add(_RecordedRequest(request, body));
    if (handler != null) return handler!(request, body);
    return _jsonResponse({
      'system': <String, Object?>{},
      'devices': <Object?>[],
    });
  }
}

http.StreamedResponse _jsonResponse(Object? value, {int statusCode = 200}) {
  final body = utf8.encode(jsonEncode(value));
  return http.StreamedResponse(
    Stream<List<int>>.value(body),
    statusCode,
    contentLength: body.length,
    headers: const {'content-type': 'application/json'},
  );
}

/// Pumps until the "Test connection" indeterminate spinner is gone, up to a
/// bounded number of iterations. pumpAndSettle() can't be used here (the
/// spinner keeps scheduling frames for as long as it's shown), and a fixed
/// pump count is fragile against how many real microtask/Timer hops the
/// fake HTTP round trip needs -- poll instead.
Future<void> _pumpUntilNotTesting(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
  fail('Test connection never left the testing state.');
}
