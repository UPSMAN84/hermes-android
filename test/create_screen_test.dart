import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/character_generation_context.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/models/media_asset.dart';
import 'package:hermes_android/core/screens/create_screen.dart';
import 'package:hermes_android/core/services/comfy_ui_graph_converter.dart';
import 'package:hermes_android/core/services/generation_repository.dart';

void main() {
  final connection = SavedConnection(
    id: 'conn-1',
    label: 'Test',
    host: 'localhost',
    port: 8080,
    apiKey: 'key',
  );

  Widget harness(_FakeGenerationRepository repository) => MaterialApp(
    home: CreateScreen(connection: connection, repository: repository),
  );

  testWidgets('shows image, video, and workflows tabs', (tester) async {
    await tester.pumpWidget(harness(_FakeGenerationRepository()));
    await tester.pump();

    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Workflows'), findsOneWidget);
  });

  testWidgets('an empty Image tab offers to jump to Workflows', (tester) async {
    await tester.pumpWidget(harness(_FakeGenerationRepository()));
    await tester.pump();

    expect(find.text('No image workflows yet.'), findsOneWidget);
    await tester.tap(find.text('Go to Workflows'));
    await tester.pumpAndSettle();

    expect(find.text('Import workflow'), findsOneWidget);
  });

  testWidgets('Image tab shows a form for a matching-kind workflow', (
    tester,
  ) async {
    final repository = _FakeGenerationRepository();
    repository.seedWorkflow(_imageWorkflow);
    await tester.pumpWidget(harness(repository));
    await tester.pump();

    expect(find.text('No image workflows yet.'), findsNothing);
    expect(find.byKey(const Key('binding-prompt')), findsOneWidget);
  });

  testWidgets('a video workflow does not appear under the Image tab', (
    tester,
  ) async {
    final repository = _FakeGenerationRepository();
    repository.seedWorkflow(_videoWorkflow);
    await tester.pumpWidget(harness(repository));
    await tester.pump();

    expect(find.text('No image workflows yet.'), findsOneWidget);

    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('binding-prompt')), findsOneWidget);
  });

  testWidgets('jobs of the matching kind render as cards under Image', (
    tester,
  ) async {
    final repository = _FakeGenerationRepository();
    repository.seedWorkflow(_imageWorkflow);
    repository.seedJob(
      _job(kind: ComfyMediaKind.image, state: GenerationJobState.queued),
    );
    repository.seedJob(
      _job(kind: ComfyMediaKind.video, state: GenerationJobState.running),
    );
    await tester.pumpWidget(harness(repository));
    await tester.pump();

    expect(find.text('Queued'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
  });
}

GenerationJob _job({
  required ComfyMediaKind kind,
  required GenerationJobState state,
}) => GenerationJob(
  localId: 'job-${kind.name}',
  workflowId: 'workflow-${kind.name}',
  kind: kind,
  state: state,
  endpointFingerprint: 'fp',
  endpointSnapshot: 'http://host:8188',
  submittedValues: const {},
  createdAt: DateTime.utc(2026, 8, 20),
  updatedAt: DateTime.utc(2026, 8, 20),
);

final ComfyWorkflowDefinition _imageWorkflow = ComfyWorkflowDefinition(
  id: 'workflow-image',
  name: 'Image workflow',
  kind: ComfyMediaKind.image,
  workingGraph: const {},
  sourceHash: 'hash-image',
  sourceFileName: 'workflow.json',
  bindings: const [
    WorkflowInputBinding(
      id: 'prompt',
      nodeId: '1',
      inputName: 'text',
      label: 'Prompt',
      role: BindingRole.prompt,
      controlType: WorkflowControlType.multiline,
      required: false,
    ),
  ],
  createdAt: DateTime.utc(2026, 8, 20),
  updatedAt: DateTime.utc(2026, 8, 20),
);

final ComfyWorkflowDefinition _videoWorkflow = ComfyWorkflowDefinition(
  id: 'workflow-video',
  name: 'Video workflow',
  kind: ComfyMediaKind.video,
  workingGraph: const {},
  sourceHash: 'hash-video',
  sourceFileName: 'workflow.json',
  bindings: const [
    WorkflowInputBinding(
      id: 'prompt',
      nodeId: '1',
      inputName: 'text',
      label: 'Prompt',
      role: BindingRole.prompt,
      controlType: WorkflowControlType.multiline,
      required: false,
    ),
  ],
  createdAt: DateTime.utc(2026, 8, 20),
  updatedAt: DateTime.utc(2026, 8, 20),
);

final class _FakeGenerationRepository implements GenerationRepository {
  final Map<String, ComfyWorkflowDefinition> _workflows = {};
  final Map<String, GenerationJob> _jobs = {};
  final Set<MultiStreamController<List<ComfyWorkflowDefinition>>>
  _workflowListeners = {};
  final Set<MultiStreamController<List<GenerationJob>>> _jobListeners = {};

  void seedWorkflow(ComfyWorkflowDefinition workflow) {
    _workflows[workflow.id] = workflow;
    _emitWorkflows();
  }

  void seedJob(GenerationJob job) {
    _jobs[job.localId] = job;
    _emitJobs();
  }

  void _emitWorkflows() {
    final snapshot = _workflows.values.toList(growable: false);
    for (final controller in _workflowListeners.toList(growable: false)) {
      controller.add(snapshot);
    }
  }

  void _emitJobs() {
    final snapshot = _jobs.values.toList(growable: false);
    for (final controller in _jobListeners.toList(growable: false)) {
      controller.add(snapshot);
    }
  }

  @override
  Future<void> initialize() async {}

  @override
  Stream<List<ComfyWorkflowDefinition>> watchWorkflows() =>
      Stream<List<ComfyWorkflowDefinition>>.multi((controller) {
        controller.add(_workflows.values.toList(growable: false));
        _workflowListeners.add(controller);
        controller.onCancel = () => _workflowListeners.remove(controller);
      }, isBroadcast: true);

  @override
  Stream<List<GenerationJob>> watchJobs() =>
      Stream<List<GenerationJob>>.multi((controller) {
        controller.add(_jobs.values.toList(growable: false));
        _jobListeners.add(controller);
        controller.onCancel = () => _jobListeners.remove(controller);
      }, isBroadcast: true);

  @override
  Stream<List<MediaAsset>> watchMedia() => const Stream.empty();

  @override
  Stream<CharacterGenerationContext?> watchCharacterContext(String sessionId) =>
      const Stream.empty();

  @override
  Future<GenerationJob> submit(GenerationRequest request) async {
    final now = DateTime.utc(2026, 8, 20);
    return GenerationJob(
      localId: 'submitted',
      workflowId: request.workflowId,
      kind: request.kind,
      state: GenerationJobState.submitting,
      endpointFingerprint: 'fp',
      endpointSnapshot: 'http://host:8188',
      submittedValues: request.submittedValues,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> cancel(
    String localJobId, {
    bool confirmSharedInterrupt = false,
  }) async {}

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
  }) => throw UnimplementedError();

  @override
  Future<ComfyWorkflowDefinition> duplicateWorkflow(
    String workflowId, {
    required String name,
  }) => throw UnimplementedError();

  @override
  Future<WorkflowValidationResult> validateWorkflow(
    String workflowId, {
    required bool againstServer,
  }) => throw UnimplementedError();

  @override
  Future<JsonObject> fetchObjectInfo() => throw UnimplementedError();

  @override
  Future<GraphConversionResult> normalizeImportedGraph(JsonObject graph) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> exportWorkflow(
    String workflowId,
    WorkflowExportKind kind,
  ) => throw UnimplementedError();

  @override
  Future<void> deleteWorkflow(String workflowId) => throw UnimplementedError();

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
    for (final controller in _jobListeners.toList(growable: false)) {
      await controller.close();
    }
    _workflowListeners.clear();
    _jobListeners.clear();
  }
}
