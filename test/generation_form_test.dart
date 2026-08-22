import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/character_generation_context.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/models/media_asset.dart';
import 'package:hermes_android/core/services/comfy_ui_graph_converter.dart';
import 'package:hermes_android/core/services/generation_repository.dart';
import 'package:hermes_android/core/widgets/generation_form.dart';

void main() {
  final requiredPromptWorkflow = ComfyWorkflowDefinition(
    id: 'workflow-1',
    name: 'Test workflow',
    kind: ComfyMediaKind.image,
    workingGraph: const {},
    sourceHash: 'hash',
    sourceFileName: 'workflow.json',
    bindings: const [
      WorkflowInputBinding(
        id: 'prompt',
        nodeId: '1',
        inputName: 'text',
        label: 'Prompt',
        role: BindingRole.prompt,
        controlType: WorkflowControlType.multiline,
        required: true,
      ),
      WorkflowInputBinding(
        id: 'steps',
        nodeId: '2',
        inputName: 'steps',
        label: 'Steps',
        role: BindingRole.steps,
        controlType: WorkflowControlType.integer,
        required: false,
        defaultValue: 20,
        minimum: 1,
        maximum: 50,
      ),
    ],
    createdAt: DateTime.utc(2026, 8, 20),
    updatedAt: DateTime.utc(2026, 8, 20),
  );

  Widget harness({
    required _FakeGenerationRepository repository,
    ComfyWorkflowDefinition? workflow,
    CharacterGenerationContext? characterContext,
    _FakeImagePicker? imagePicker,
    void Function(GenerationJob job)? onSubmitted,
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: GenerationForm(
          repository: repository,
          workflow: workflow ?? requiredPromptWorkflow,
          characterContext: characterContext,
          imagePicker: imagePicker ?? _FakeImagePicker(null),
          onSubmitted: onSubmitted ?? (_) {},
        ),
      ),
    ),
  );

  testWidgets(
    'submit is disabled until required bindings are valid, and double taps only submit once',
    (tester) async {
      final repository = _FakeGenerationRepository()..blockSubmit = true;
      await tester.pumpWidget(harness(repository: repository));

      final generate = find.byType(FilledButton);
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('binding-prompt')),
        'portrait',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);

      await tester.tap(generate);
      await tester.pump();
      // The in-flight submit hasn't resolved (blockSubmit), so the button
      // must already be disabled -- a second tap here is a real user
      // double-tapping before the first request completes.
      expect(tester.widget<FilledButton>(generate).onPressed, isNull);
      await tester.tap(generate);
      await tester.pump();

      expect(repository.submitCalls, hasLength(1));

      repository.completePending();
      await tester.pump();
    },
  );

  testWidgets('out-of-range numeric values block submission', (tester) async {
    final repository = _FakeGenerationRepository();
    await tester.pumpWidget(harness(repository: repository));

    await tester.enterText(find.byKey(const Key('binding-prompt')), 'cat');
    await tester.enterText(find.byKey(const Key('binding-steps')), '999');
    await tester.pump();

    final generate = find.widgetWithText(FilledButton, 'Generate');
    expect(tester.widget<FilledButton>(generate).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('binding-steps')), '30');
    await tester.pump();
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
  });

  testWidgets('submitted values include the numeric binding', (tester) async {
    final repository = _FakeGenerationRepository();
    await tester.pumpWidget(harness(repository: repository));

    await tester.enterText(find.byKey(const Key('binding-prompt')), 'cat');
    await tester.enterText(find.byKey(const Key('binding-steps')), '30');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pump();

    expect(repository.submitCalls.single.submittedValues['prompt'], 'cat');
    expect(repository.submitCalls.single.submittedValues['steps'], 30);
  });

  testWidgets(
    'using character context composes the visible prompt and pre-selects the avatar, '
    'and the repository never recomposes it',
    (tester) async {
      final avatarFile = File('avatar.png');
      final context = CharacterGenerationContext(
        sessionId: 'session-1',
        characterName: 'Hermes',
        appearancePrompt: 'Silver hair and a blue coat.',
        referenceImagePath: avatarFile.path,
        createdAt: DateTime.utc(2026, 8, 20),
        updatedAt: DateTime.utc(2026, 8, 20),
      );
      final imageWorkflow = ComfyWorkflowDefinition(
        id: 'workflow-1',
        name: 'Test workflow',
        kind: ComfyMediaKind.image,
        workingGraph: const {},
        sourceHash: 'hash',
        sourceFileName: 'workflow.json',
        bindings: const [
          WorkflowInputBinding(
            id: 'prompt',
            nodeId: '1',
            inputName: 'text',
            label: 'Prompt',
            role: BindingRole.prompt,
            controlType: WorkflowControlType.multiline,
            required: true,
          ),
          WorkflowInputBinding(
            id: 'image',
            nodeId: '2',
            inputName: 'image',
            label: 'Reference image',
            role: BindingRole.inputImage,
            controlType: WorkflowControlType.file,
            required: false,
          ),
        ],
        createdAt: DateTime.utc(2026, 8, 20),
        updatedAt: DateTime.utc(2026, 8, 20),
      );
      final repository = _FakeGenerationRepository();

      await tester.pumpWidget(
        harness(
          repository: repository,
          workflow: imageWorkflow,
          characterContext: context,
        ),
      );

      await tester.enterText(
        find.byKey(const Key('binding-prompt')),
        'walking through rain',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('use-character-context')));
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const Key('binding-prompt')),
      );
      expect(
        field.controller!.text,
        'Silver hair and a blue coat.\n\nwalking through rain',
      );
      expect(
        find.text('Silver hair and a blue coat.\n\nwalking through rain'),
        findsWidgets,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
      await tester.pump();

      final request = repository.submitCalls.single;
      expect(request.useCharacterContext, isFalse);
      expect(
        request.submittedValues['prompt'],
        'Silver hair and a blue coat.\n\nwalking through rain',
      );
      expect(request.referenceImages['image']!.path, avatarFile.path);
    },
  );

  testWidgets('picking a reference image satisfies a required file binding', (
    tester,
  ) async {
    final fileWorkflow = ComfyWorkflowDefinition(
      id: 'workflow-1',
      name: 'Test workflow',
      kind: ComfyMediaKind.image,
      workingGraph: const {},
      sourceHash: 'hash',
      sourceFileName: 'workflow.json',
      bindings: const [
        WorkflowInputBinding(
          id: 'image',
          nodeId: '1',
          inputName: 'image',
          label: 'Reference image',
          role: BindingRole.inputImage,
          controlType: WorkflowControlType.file,
          required: true,
        ),
      ],
      createdAt: DateTime.utc(2026, 8, 20),
      updatedAt: DateTime.utc(2026, 8, 20),
    );
    final repository = _FakeGenerationRepository();
    final picker = _FakeImagePicker(File('picked.png'));

    await tester.pumpWidget(
      harness(
        repository: repository,
        workflow: fileWorkflow,
        imagePicker: picker,
      ),
    );

    final generate = find.widgetWithText(FilledButton, 'Generate');
    expect(tester.widget<FilledButton>(generate).onPressed, isNull);

    await tester.tap(find.text('Choose image'));
    await tester.pump();

    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
    await tester.tap(generate);
    await tester.pump();
    expect(
      repository.submitCalls.single.referenceImages['image']!.path,
      'picked.png',
    );
  });
}

final class _FakeImagePicker implements ImagePickerPort {
  _FakeImagePicker(this.file);

  final File? file;

  @override
  Future<File?> pickImage() async => file;
}

final class _FakeGenerationRepository implements GenerationRepository {
  final List<GenerationRequest> submitCalls = [];
  int _sequence = 0;

  /// When set, submit() doesn't resolve until [completePending] is called
  /// -- gives tests a deterministic in-flight window to assert the button
  /// disables, rather than racing a same-microtask resolve against a pump.
  bool blockSubmit = false;
  Completer<void>? _pending;

  void completePending() {
    _pending?.complete();
    _pending = null;
  }

  @override
  Future<GenerationJob> submit(GenerationRequest request) async {
    submitCalls.add(request);
    if (blockSubmit) {
      final completer = Completer<void>();
      _pending = completer;
      await completer.future;
    }
    final now = DateTime.utc(2026, 8, 20);
    return GenerationJob(
      localId: 'job-${_sequence++}',
      workflowId: request.workflowId,
      kind: request.kind,
      state: GenerationJobState.submitting,
      endpointFingerprint: 'fp',
      endpointSnapshot: 'http://host:8188',
      submittedValues: request.submittedValues,
      sourceSessionId: request.sourceSessionId,
      sourceMessageId: request.sourceMessageId,
      sourceContextId: request.sourceContextId,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> initialize() async {}

  @override
  Stream<List<ComfyWorkflowDefinition>> watchWorkflows() =>
      const Stream.empty();

  @override
  Stream<List<GenerationJob>> watchJobs() => const Stream.empty();

  @override
  Stream<List<MediaAsset>> watchMedia() => const Stream.empty();

  @override
  Stream<CharacterGenerationContext?> watchCharacterContext(String sessionId) =>
      const Stream.empty();

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
  Future<ComfyWorkflowDefinition?> getWorkflow(String workflowId) async => null;

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
  Future<void> dispose() async {}
}
