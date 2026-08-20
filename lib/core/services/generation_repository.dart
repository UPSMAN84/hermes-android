import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/character_generation_context.dart';
import '../models/comfy_workflow.dart';
import '../models/generation_job.dart';
import '../models/media_asset.dart';
import 'character_generation_context_store.dart';
import 'comfy_workflow_codec.dart';
import 'comfyui.dart';
import 'comfyui_client.dart';
import 'comfyui_socket.dart';
import 'generation_job_store.dart';
import 'media_asset_store.dart';
import 'media_cache_service.dart';
import 'workflow_store.dart';

enum WorkflowExportKind { originalSource, workingGraph, hermesSidecar }

/// Resolves the active ComfyUI endpoint and the stable per-installation
/// client ID used for `/prompt` submissions and `/ws` connections.
abstract interface class ComfyEndpointConfig {
  Future<ComfyEndpoint?> load();

  Future<String> stableClientId();
}

abstract interface class ComfyUiClientFactory {
  ComfyUiClient create({
    required ComfyEndpoint endpoint,
    required String clientId,
  });
}

/// A per-observation lease on the shared foreground service. Every
/// [acquire] that returns true must be matched by exactly one [release],
/// even on the failure paths -- the repository balances this itself so
/// callers only ever see the orchestration API.
abstract interface class ForegroundLeasePort {
  Future<bool> acquire({required String notificationText});

  Future<void> release();
}

abstract interface class GenerationRepository {
  Future<void> initialize();

  Stream<List<ComfyWorkflowDefinition>> watchWorkflows();
  Stream<List<GenerationJob>> watchJobs();
  Stream<List<MediaAsset>> watchMedia();
  Stream<CharacterGenerationContext?> watchCharacterContext(String sessionId);

  Future<GenerationJob> submit(GenerationRequest request);
  Future<void> cancel(String localJobId, {bool confirmSharedInterrupt = false});
  Future<GenerationJob> retryAsNew(String localJobId);
  Future<void> reconcilePending();

  Future<ComfyWorkflowDefinition?> getWorkflow(String workflowId);
  Future<void> saveWorkflow(
    ComfyWorkflowDefinition workflow, {
    required Uint8List sourceBytes,
  });
  Future<ComfyWorkflowDefinition> duplicateWorkflow(
    String workflowId, {
    required String name,
  });
  Future<WorkflowValidationResult> validateWorkflow(
    String workflowId, {
    required bool againstServer,
  });
  Future<Uint8List> exportWorkflow(String workflowId, WorkflowExportKind kind);
  Future<void> deleteWorkflow(String workflowId);

  Future<void> removeMedia(String assetId, {required bool clearCache});

  Future<CharacterGenerationContext?> getCharacterContext(String sessionId);
  Future<void> saveCharacterContext(
    CharacterGenerationContext context, {
    File? referenceImage,
  });
  Future<void> deleteCharacterContext(String sessionId);

  Future<void> upsertChatToolOutputs({
    required ComfyEndpoint endpoint,
    required String sessionId,
    required List<JsonObject> messages,
  });

  Future<void> dispose();
}

final class DefaultGenerationRepository implements GenerationRepository {
  DefaultGenerationRepository({
    required this.endpointConfig,
    required this.clientFactory,
    required this.socketFactory,
    required this.workflowStore,
    required this.jobStore,
    required this.mediaStore,
    required this.contextStore,
    required this.mediaCache,
    required this.foregroundLease,
    required DateTime Function() clock,
    // ignore: prefer_initializing_formals
  }) : _clock = clock;

  final ComfyEndpointConfig endpointConfig;
  final ComfyUiClientFactory clientFactory;
  final ComfyUiSocketFactory socketFactory;
  final WorkflowStore workflowStore;
  final GenerationJobStore jobStore;
  final MediaAssetStore mediaStore;
  final CharacterGenerationContextStore contextStore;
  final MediaCachePort mediaCache;
  final ForegroundLeasePort foregroundLease;
  final DateTime Function() _clock;

  bool _initialized = false;
  bool _disposed = false;
  int _localIdSequence = 0;

  final Map<String, GenerationJob> _jobs = {};
  final Map<String, ComfyWorkflowDefinition> _workflows = {};
  final Map<String, MediaAsset> _media = {};
  final Map<String, CharacterGenerationContext?> _contexts = {};
  final Map<String, _ReplaySubject<CharacterGenerationContext?>>
  _contextSubjects = {};

  final _ReplaySubject<List<GenerationJob>> _jobsSubject = _ReplaySubject(
    const [],
  );
  final _ReplaySubject<List<ComfyWorkflowDefinition>> _workflowsSubject =
      _ReplaySubject(const []);
  final _ReplaySubject<List<MediaAsset>> _mediaSubject = _ReplaySubject(
    const [],
  );

  final Map<String, ComfyUiClient> _clients = {};
  final Map<String, Future<void>> _jobLocks = {};
  final Map<String, Future<void>> _observationFutures = {};
  final Map<String, StreamIterator<ComfyExecutionEvent>> _activeIterators = {};

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    for (final workflow in await workflowStore.list()) {
      _workflows[workflow.id] = workflow;
    }
    _workflowsSubject.add(_workflowList());

    for (final job in await jobStore.list()) {
      _jobs[job.localId] = job;
    }
    _jobsSubject.add(_jobList());

    for (final asset in await mediaStore.list()) {
      _media[asset.id] = asset;
    }
    _mediaSubject.add(_mediaList());
  }

  List<GenerationJob> _jobList() => List.unmodifiable(
    _jobs.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );

  List<ComfyWorkflowDefinition> _workflowList() => List.unmodifiable(
    _workflows.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
  );

  List<MediaAsset> _mediaList() => List.unmodifiable(
    _media.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
  );

  @override
  Stream<List<ComfyWorkflowDefinition>> watchWorkflows() =>
      _workflowsSubject.stream;

  @override
  Stream<List<GenerationJob>> watchJobs() => _jobsSubject.stream;

  @override
  Stream<List<MediaAsset>> watchMedia() => _mediaSubject.stream;

  @override
  Stream<CharacterGenerationContext?> watchCharacterContext(String sessionId) {
    final subject = _contextSubjectFor(sessionId);
    if (!_contexts.containsKey(sessionId)) {
      unawaited(getCharacterContext(sessionId));
    }
    return subject.stream;
  }

  _ReplaySubject<CharacterGenerationContext?> _contextSubjectFor(
    String sessionId,
  ) => _contextSubjects[sessionId] ??=
      _ReplaySubject<CharacterGenerationContext?>(_contexts[sessionId]);

  // -- Submission, cancellation, retry, reconciliation --------------------

  @override
  Future<GenerationJob> submit(GenerationRequest request) async {
    await initialize();
    final workflow = await getWorkflow(request.workflowId);
    if (workflow == null) {
      throw StateError('Unknown workflow: ${request.workflowId}');
    }
    final endpoint = await endpointConfig.load();
    if (endpoint == null) {
      throw StateError('ComfyUI is not configured');
    }

    final values = <String, Object?>{...request.submittedValues};
    CharacterGenerationContext? context;
    if (request.useCharacterContext && request.sourceContextId != null) {
      context = await getCharacterContext(request.sourceContextId!);
    }
    final promptBinding = _bindingByRole(workflow, BindingRole.prompt);
    if (context != null && promptBinding != null) {
      values[promptBinding.id] = composeGenerationPrompt(
        userPrompt: (values[promptBinding.id] as String?) ?? '',
        context: context,
        useContext: true,
      );
    }

    final referenceImages = Map<String, File>.of(request.referenceImages);
    final avatarBinding = _bindingByRole(workflow, BindingRole.inputImage);
    final avatarPath = context?.referenceImagePath;
    if (avatarPath != null &&
        avatarBinding != null &&
        !referenceImages.containsKey(avatarBinding.id)) {
      referenceImages[avatarBinding.id] = File(avatarPath);
    }

    final now = _clock().toUtc();
    final localId = _newId('job');
    var job = GenerationJob(
      localId: localId,
      workflowId: workflow.id,
      kind: workflow.kind,
      state: GenerationJobState.submitting,
      endpointFingerprint: _resolveFingerprint(workflow, endpoint),
      endpointSnapshot: endpoint.baseUri.toString(),
      submittedValues: values,
      sourceSessionId: request.sourceSessionId,
      sourceMessageId: request.sourceMessageId,
      sourceContextId: request.sourceContextId,
      createdAt: now,
      updatedAt: now,
    );
    await _saveJob(job);

    final leaseHeld = await foregroundLease.acquire(
      notificationText: 'Generating…',
    );
    var handedOff = false;
    try {
      final client = await _clientFor(endpoint);

      for (final binding in workflow.bindings) {
        if (binding.controlType != WorkflowControlType.file) continue;
        final file = referenceImages[binding.id];
        if (file == null) continue;
        final ComfyOutputRef uploaded;
        try {
          final bytes = await file.readAsBytes();
          uploaded = await client.uploadImage(
            bytes,
            fileName: _uploadFileName(file, bytes),
          );
        } catch (error) {
          job = await _reduceAndSave(
            localId,
            SubmissionFailed('Reference image upload failed: $error'),
          );
          return job;
        }
        values[binding.id] = uploaded.subfolder.isEmpty
            ? uploaded.filename
            : '${uploaded.subfolder}/${uploaded.filename}';
      }

      job = _withValues(job, values, _clock().toUtc());
      await _saveJob(job);

      final JsonObject graph;
      try {
        graph = ComfyWorkflowCodec.applyBindings(
          workflow.workingGraph,
          workflow.bindings,
          values,
        );
      } on StateError catch (error) {
        job = await _reduceAndSave(localId, SubmissionFailed(error.message));
        return job;
      }

      late final ComfyPromptSubmission submission;
      try {
        submission = await client.submitPrompt(graph);
      } on ComfySubmissionUncertainException catch (error) {
        job = await _reduceAndSave(localId, SubmissionUnknown(error.message));
        return job;
      } on ComfyApiException catch (error) {
        job = await _reduceAndSave(
          localId,
          SubmissionFailed(error.message, nodeErrors: error.nodeErrors),
        );
        return job;
      }

      job = await _reduceAndSave(localId, PromptAccepted(submission.promptId));
      handedOff = true;
      _launchObserver(
        localId,
        endpoint: endpoint,
        releaseLeaseWhenDone: leaseHeld,
      );
      return job;
    } finally {
      if (!handedOff && leaseHeld) {
        unawaited(foregroundLease.release());
      }
    }
  }

  @override
  Future<void> cancel(
    String localJobId, {
    bool confirmSharedInterrupt = false,
  }) async {
    await initialize();
    return _withJobLock(localJobId, () async {
      final job = _jobs[localJobId];
      if (job == null) throw StateError('Unknown job: $localJobId');
      if (job.isTerminal) return;

      if (job.state == GenerationJobState.queued && job.promptId != null) {
        final endpoint = ComfyEndpoint.parse(job.endpointSnapshot);
        final client = await _clientFor(endpoint);
        await _reduceAndSave(localJobId, const CancelRequested());
        try {
          await client.deleteQueuedPrompt(job.promptId!);
        } catch (_) {
          return;
        }
        await _reduceAndSave(localJobId, const QueueRemovalConfirmed());
        return;
      }

      if (job.state == GenerationJobState.running) {
        if (!confirmSharedInterrupt) {
          throw StateError(
            'Interrupting a running prompt requires explicit confirmation',
          );
        }
        final endpoint = ComfyEndpoint.parse(job.endpointSnapshot);
        final client = await _clientFor(endpoint);
        await _reduceAndSave(localJobId, const CancelRequested());
        try {
          await client.interrupt();
        } catch (_) {
          // Reconciliation resolves the final state.
        }
        return;
      }

      if (job.state == GenerationJobState.reconciling ||
          job.state == GenerationJobState.cancelling) {
        await _reduceAndSave(localJobId, const CancelRequested());
        return;
      }
      // draft/submitting/uncertain: nothing server-side to cancel yet.
    });
  }

  @override
  Future<GenerationJob> retryAsNew(String localJobId) async {
    await initialize();
    final job = _jobs[localJobId] ?? await jobStore.get(localJobId);
    if (job == null) throw StateError('Unknown job: $localJobId');
    return submit(
      GenerationRequest(
        workflowId: job.workflowId,
        kind: job.kind,
        submittedValues: job.submittedValues,
        sourceSessionId: job.sourceSessionId,
        sourceMessageId: job.sourceMessageId,
        sourceContextId: job.sourceContextId,
      ),
    );
  }

  @override
  Future<void> reconcilePending() async {
    await initialize();
    for (final job in List<GenerationJob>.of(_jobs.values)) {
      if (job.state == GenerationJobState.submitting && job.promptId == null) {
        await _withJobLock(
          job.localId,
          () => _reduceAndSave(job.localId, const RestoreWithoutPromptId()),
        );
        continue;
      }
      if (job.promptId == null) continue;
      if (!const {
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        continue;
      }
      final endpoint = ComfyEndpoint.parse(job.endpointSnapshot);
      await _reconcileJob(job.localId, endpoint: endpoint);
    }
  }

  Future<void> _reconcileJob(
    String jobId, {
    required ComfyEndpoint endpoint,
  }) => _withJobLock(jobId, () async {
    final job = _jobs[jobId];
    if (job == null || job.promptId == null) return;
    final client = await _clientFor(endpoint);

    ComfyHistoryResult? history;
    try {
      history = await client.getHistory(job.promptId!);
    } catch (_) {
      history = null;
    }
    if (history != null && (history.completed || history.error != null)) {
      await _applyHistoryUnlocked(jobId, history, endpoint: endpoint);
      return;
    }

    ComfyQueueSnapshot? queue;
    try {
      queue = await client.getQueue();
    } catch (_) {
      queue = null;
    }
    if (queue == null) return; // Stay reconciling; a later call retries.

    if (queue.isRunning(job.promptId!)) {
      await _reduceAndSave(jobId, const ExecutionStarted());
      _launchObserver(jobId, endpoint: endpoint, releaseLeaseWhenDone: false);
      return;
    }
    if (queue.isPending(job.promptId!)) {
      await _reduceAndSave(jobId, const PromptQueued());
      _launchObserver(jobId, endpoint: endpoint, releaseLeaseWhenDone: false);
      return;
    }
    await _reduceAndSave(jobId, const QueueReconciled(false));
  });

  Future<void> _applyHistoryUnlocked(
    String jobId,
    ComfyHistoryResult history, {
    required ComfyEndpoint endpoint,
  }) async {
    final eventType = history.error?['event_type'];
    if (eventType == 'execution_interrupted') {
      await _reduceAndSave(jobId, const ExecutionInterrupted());
      return;
    }
    final errorMessage = history.error == null
        ? null
        : _historyErrorMessage(history.error!);
    await _reduceAndSave(
      jobId,
      HistoryReconciled(
        completed: history.completed,
        outputs: history.outputs,
        error: errorMessage,
      ),
    );
    if (history.completed && errorMessage == null) {
      await _indexJobOutputsUnlocked(jobId, endpoint: endpoint);
    }
  }

  // -- Live execution observation ------------------------------------------

  void _launchObserver(
    String jobId, {
    required ComfyEndpoint endpoint,
    required bool releaseLeaseWhenDone,
  }) {
    if (_disposed) {
      if (releaseLeaseWhenDone) unawaited(foregroundLease.release());
      return;
    }
    late final Future<void> future;
    future =
        _observeJob(
          jobId,
          endpoint: endpoint,
          releaseLeaseWhenDone: releaseLeaseWhenDone,
        ).whenComplete(() {
          if (identical(_observationFutures[jobId], future)) {
            _observationFutures.remove(jobId);
          }
        });
    _observationFutures[jobId] = future;
  }

  Future<void> _observeJob(
    String jobId, {
    required ComfyEndpoint endpoint,
    required bool releaseLeaseWhenDone,
  }) async {
    try {
      final job = _jobs[jobId];
      if (job == null || job.promptId == null) return;
      final clientId = await endpointConfig.stableClientId();
      final socket = socketFactory.create();
      final iterator = StreamIterator<ComfyExecutionEvent>(
        socket.watchExecution(
          endpoint,
          clientId: clientId,
          promptId: job.promptId!,
        ),
      );
      _activeIterators[jobId] = iterator;
      try {
        while (await iterator.moveNext()) {
          await _applyExecutionEvent(
            jobId,
            iterator.current,
            endpoint: endpoint,
          );
          final current = _jobs[jobId];
          if (current == null || current.isTerminal) break;
        }
      } finally {
        await iterator.cancel();
        if (identical(_activeIterators[jobId], iterator)) {
          _activeIterators.remove(jobId);
        }
      }
    } finally {
      if (releaseLeaseWhenDone) unawaited(foregroundLease.release());
    }
  }

  Future<void> _applyExecutionEvent(
    String jobId,
    ComfyExecutionEvent event, {
    required ComfyEndpoint endpoint,
  }) async {
    switch (event) {
      case ComfyStatus():
      case ComfyCachedNodes():
      case ComfyExecuting():
        return;
      case ComfyExecutionStarted():
        await _withJobLock(
          jobId,
          () => _reduceAndSave(jobId, const ExecutionStarted()),
        );
      case ComfyProgress(:final nodeId, :final value, :final max):
        await _withJobLock(
          jobId,
          () => _reduceAndSave(jobId, ExecutionProgressed(nodeId, value, max)),
        );
      case ComfyExecuted(:final outputs):
        if (outputs.isNotEmpty) {
          await _withJobLock(
            jobId,
            () => _reduceAndSave(jobId, ExecutionOutputsObserved(outputs)),
          );
        }
      case ComfySucceeded():
        await _withJobLock(
          jobId,
          () => _finalizeSuccessLocked(jobId, endpoint: endpoint),
        );
      case ComfyExecutionError(:final message):
        await _withJobLock(
          jobId,
          () => _reduceAndSave(jobId, ExecutionFailed(message)),
        );
      case ComfyInterrupted():
        await _withJobLock(
          jobId,
          () => _reduceAndSave(jobId, const ExecutionInterrupted()),
        );
      case ComfySocketLost():
        await _withJobLock(
          jobId,
          () => _reduceAndSave(jobId, const SocketLost()),
        );
        await _reconcileJob(jobId, endpoint: endpoint);
    }
  }

  Future<void> _finalizeSuccessLocked(
    String jobId, {
    required ComfyEndpoint endpoint,
  }) async {
    final job = _jobs[jobId];
    if (job == null || job.promptId == null) return;
    List<ComfyOutputRef> outputs = const [];
    try {
      final client = await _clientFor(endpoint);
      final history = await client.getHistory(job.promptId!);
      if (history != null) outputs = history.outputs;
    } catch (_) {
      // Fall back to whatever the socket already accumulated.
    }
    await _reduceAndSave(jobId, ExecutionSucceeded(outputs));
    await _indexJobOutputsUnlocked(jobId, endpoint: endpoint);
  }

  Future<void> _indexJobOutputsUnlocked(
    String jobId, {
    required ComfyEndpoint endpoint,
  }) async {
    final job = _jobs[jobId];
    if (job == null) return;
    final now = _clock().toUtc();
    for (final output in job.outputs) {
      final asset = MediaAsset(
        id: _newId('media'),
        jobId: job.localId,
        workflowId: job.workflowId,
        kind: _classifyKind(job.kind, output.filename),
        endpointSnapshot: endpoint.baseUri.toString(),
        filename: output.filename,
        subfolder: output.subfolder,
        type: output.type,
        contentType: _classifyContentType(output.filename),
        sourceSessionId: job.sourceSessionId,
        sourceMessageId: job.sourceMessageId,
        createdAt: now,
        updatedAt: now,
      );
      final saved = await mediaStore.upsert(asset);
      _media[saved.id] = saved;
    }
    _mediaSubject.add(_mediaList());
  }

  // -- Workflows ------------------------------------------------------------

  @override
  Future<ComfyWorkflowDefinition?> getWorkflow(String workflowId) async {
    if (_workflows.containsKey(workflowId)) return _workflows[workflowId];
    final loaded = await workflowStore.get(workflowId);
    if (loaded != null) {
      _workflows[workflowId] = loaded;
      _workflowsSubject.add(_workflowList());
    }
    return loaded;
  }

  @override
  Future<void> saveWorkflow(
    ComfyWorkflowDefinition workflow, {
    required Uint8List sourceBytes,
  }) async {
    await workflowStore.save(workflow, originalSource: sourceBytes);
    _workflows[workflow.id] = workflow;
    _workflowsSubject.add(_workflowList());
  }

  @override
  Future<ComfyWorkflowDefinition> duplicateWorkflow(
    String workflowId, {
    required String name,
  }) async {
    final source = await getWorkflow(workflowId);
    if (source == null) throw StateError('Unknown workflow: $workflowId');
    final originalBytes = await workflowStore.getOriginalSource(workflowId);
    if (originalBytes == null) {
      throw StateError('Missing workflow source: $workflowId');
    }
    final now = _clock().toUtc();
    final duplicate = ComfyWorkflowDefinition(
      id: _newId('workflow'),
      name: name,
      kind: source.kind,
      workingGraph: source.workingGraph,
      sourceHash: source.sourceHash,
      sourceFileName: source.sourceFileName,
      bindings: source.bindings,
      createdAt: now,
      updatedAt: now,
    );
    await saveWorkflow(duplicate, sourceBytes: originalBytes);
    return duplicate;
  }

  @override
  Future<WorkflowValidationResult> validateWorkflow(
    String workflowId, {
    required bool againstServer,
  }) async {
    final workflow = await getWorkflow(workflowId);
    if (workflow == null) throw StateError('Unknown workflow: $workflowId');
    if (!againstServer) {
      return ComfyWorkflowCodec.validateLocal(
        graph: workflow.workingGraph,
        bindings: workflow.bindings,
      );
    }
    final endpoint = await endpointConfig.load();
    if (endpoint == null) throw StateError('ComfyUI is not configured');
    final client = await _clientFor(endpoint);
    final objectInfo = await client.getObjectInfo();
    final result = ComfyWorkflowCodec.validateObjectInfo(
      definition: workflow,
      endpoint: endpoint,
      objectInfo: objectInfo,
    );
    final updated = workflow.copyWith(
      validation: result,
      updatedAt: _clock().toUtc(),
    );
    final bytes = await workflowStore.getOriginalSource(workflowId);
    if (bytes != null) {
      await saveWorkflow(updated, sourceBytes: bytes);
    }
    return result;
  }

  @override
  Future<Uint8List> exportWorkflow(
    String workflowId,
    WorkflowExportKind kind,
  ) async {
    switch (kind) {
      case WorkflowExportKind.originalSource:
        final bytes = await workflowStore.getOriginalSource(workflowId);
        if (bytes == null) throw StateError('Unknown workflow: $workflowId');
        return bytes;
      case WorkflowExportKind.workingGraph:
        final graph = await workflowStore.getWorkingGraph(workflowId);
        if (graph == null) throw StateError('Unknown workflow: $workflowId');
        return Uint8List.fromList(utf8.encode(jsonEncode(graph)));
      case WorkflowExportKind.hermesSidecar:
        final workflow = await getWorkflow(workflowId);
        if (workflow == null) {
          throw StateError('Unknown workflow: $workflowId');
        }
        return Uint8List.fromList(utf8.encode(jsonEncode(workflow.toJson())));
    }
  }

  @override
  Future<void> deleteWorkflow(String workflowId) async {
    await workflowStore.delete(workflowId);
    _workflows.remove(workflowId);
    _workflowsSubject.add(_workflowList());
  }

  // -- Media ------------------------------------------------------------------

  @override
  Future<void> removeMedia(String assetId, {required bool clearCache}) async {
    final asset = _media[assetId] ?? await mediaStore.get(assetId);
    await mediaStore.delete(assetId);
    _media.remove(assetId);
    _mediaSubject.add(_mediaList());
    if (clearCache && asset != null) {
      final endpoint = ComfyEndpoint.parse(asset.endpointSnapshot);
      await mediaCache.remove(endpoint.viewUri(asset.outputRef));
    }
  }

  @override
  Future<void> upsertChatToolOutputs({
    required ComfyEndpoint endpoint,
    required String sessionId,
    required List<JsonObject> messages,
  }) async {
    final endpointSnapshot = endpoint.baseUri.toString();
    final now = _clock().toUtc();
    for (final message in messages) {
      if (message['role'] != 'tool') continue;
      final content = message['content'];
      if (content is! String) continue;
      final messageId = message['id']?.toString();
      for (final filename in ComfyUi.extractMediaFilenames(content)) {
        final ComfyOutputRef ref;
        try {
          ref = ComfyOutputRef(filename: filename);
        } on FormatException {
          continue;
        }
        final asset = MediaAsset(
          id: _newId('media'),
          kind: ComfyUi.isVideo(filename)
              ? ComfyMediaKind.video
              : ComfyMediaKind.image,
          endpointSnapshot: endpointSnapshot,
          filename: ref.filename,
          subfolder: ref.subfolder,
          type: ref.type,
          contentType: _classifyContentType(filename),
          sourceSessionId: sessionId,
          sourceMessageId: messageId,
          createdAt: now,
          updatedAt: now,
        );
        final saved = await mediaStore.upsert(asset);
        _media[saved.id] = saved;
      }
    }
    _mediaSubject.add(_mediaList());
  }

  // -- Character context --------------------------------------------------

  @override
  Future<CharacterGenerationContext?> getCharacterContext(
    String sessionId,
  ) async {
    if (_contexts.containsKey(sessionId)) return _contexts[sessionId];
    final loaded = await contextStore.get(sessionId);
    _contexts[sessionId] = loaded;
    _contextSubjectFor(sessionId).add(loaded);
    return loaded;
  }

  @override
  Future<void> saveCharacterContext(
    CharacterGenerationContext context, {
    File? referenceImage,
  }) async {
    final saved = await contextStore.save(
      context,
      referenceImage: referenceImage,
    );
    _contexts[context.sessionId] = saved;
    _contextSubjectFor(context.sessionId).add(saved);
  }

  @override
  Future<void> deleteCharacterContext(String sessionId) async {
    await contextStore.delete(sessionId);
    _contexts[sessionId] = null;
    _contextSubjectFor(sessionId).add(null);
  }

  // -- Lifecycle ------------------------------------------------------------

  @override
  Future<void> dispose() async {
    _disposed = true;
    final iterators = _activeIterators.values.toList(growable: false);
    for (final iterator in iterators) {
      await iterator.cancel();
    }
    final pending = _observationFutures.values.toList(growable: false);
    await Future.wait(pending, eagerError: false);
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }

  // -- Internal helpers -----------------------------------------------------

  Future<void> _saveJob(GenerationJob job) async {
    await jobStore.save(job);
    _jobs[job.localId] = job;
    _jobsSubject.add(_jobList());
  }

  Future<GenerationJob> _reduceAndSave(
    String jobId,
    GenerationEvent event,
  ) async {
    final current = _jobs[jobId];
    if (current == null) throw StateError('Unknown job: $jobId');
    final updated = reduceGenerationJob(current, event, _clock().toUtc());
    await _saveJob(updated);
    return updated;
  }

  Future<T> _withJobLock<T>(String jobId, Future<T> Function() action) {
    final previous = _jobLocks[jobId] ?? Future<void>.value();
    final completer = Completer<void>();
    _jobLocks[jobId] = completer.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
        if (identical(_jobLocks[jobId], completer.future)) {
          _jobLocks.remove(jobId);
        }
      }
    });
  }

  Future<ComfyUiClient> _clientFor(ComfyEndpoint endpoint) async {
    final key = endpoint.baseUri.toString();
    final existing = _clients[key];
    if (existing != null) return existing;
    final clientId = await endpointConfig.stableClientId();
    final client = clientFactory.create(endpoint: endpoint, clientId: clientId);
    _clients[key] = client;
    return client;
  }

  String _newId(String prefix) {
    final stamp = _clock().toUtc().microsecondsSinceEpoch;
    final sequence = _localIdSequence++;
    return '$prefix-$stamp-$sequence';
  }
}

WorkflowInputBinding? _bindingByRole(
  ComfyWorkflowDefinition workflow,
  BindingRole role,
) {
  for (final binding in workflow.bindings) {
    if (binding.role == role) return binding;
  }
  return null;
}

String _resolveFingerprint(
  ComfyWorkflowDefinition workflow,
  ComfyEndpoint endpoint,
) {
  final validation = workflow.validation;
  final normalized = endpoint.baseUri.toString();
  final fingerprint = validation?.fingerprint;
  if (fingerprint != null && validation?.endpoint == normalized) {
    return fingerprint;
  }
  return 'endpoint:${sha256.convert(utf8.encode(normalized))}';
}

GenerationJob _withValues(
  GenerationJob job,
  Map<String, Object?> values,
  DateTime at,
) => GenerationJob(
  localId: job.localId,
  workflowId: job.workflowId,
  kind: job.kind,
  state: job.state,
  endpointFingerprint: job.endpointFingerprint,
  endpointSnapshot: job.endpointSnapshot,
  submittedValues: values,
  promptId: job.promptId,
  progressValue: job.progressValue,
  progressMax: job.progressMax,
  currentNodeId: job.currentNodeId,
  outputs: job.outputs,
  sourceSessionId: job.sourceSessionId,
  sourceMessageId: job.sourceMessageId,
  sourceContextId: job.sourceContextId,
  error: job.error,
  nodeErrors: job.nodeErrors,
  createdAt: job.createdAt,
  updatedAt: at,
  startedAt: job.startedAt,
  completedAt: job.completedAt,
);

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

/// [ComfyUiClient.uploadImage] requires a filename with an extension that
/// matches the image's magic bytes. Most reference-image files carry one
/// already, but the character context store deliberately saves its owned
/// copy under a fixed extension-less name (`reference-image`) -- sniff the
/// real format from the bytes instead of trusting the path in that case.
String _uploadFileName(File file, Uint8List bytes) {
  final base = _basename(file.path);
  final dot = base.lastIndexOf('.');
  if (dot > 0 && dot < base.length - 1) return base;
  return '$base.${_sniffImageExtension(bytes)}';
}

String _sniffImageExtension(Uint8List bytes) {
  if (_matchesAt(bytes, 0, const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ])) {
    return 'png';
  }
  if (_matchesAt(bytes, 0, const [0xff, 0xd8, 0xff])) return 'jpg';
  if (_matchesAt(bytes, 0, const [0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (_matchesAt(bytes, 0, const [0x52, 0x49, 0x46, 0x46]) &&
      _matchesAt(bytes, 8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'webp';
  }
  if (_matchesAt(bytes, 0, const [0x42, 0x4d])) return 'bmp';
  if (_matchesAt(bytes, 0, const [0x49, 0x49, 0x2a, 0x00]) ||
      _matchesAt(bytes, 0, const [0x4d, 0x4d, 0x00, 0x2a])) {
    return 'tiff';
  }
  return 'png';
}

bool _matchesAt(Uint8List bytes, int offset, List<int> signature) {
  if (bytes.length < offset + signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}

final RegExp _imageExtension = RegExp(
  r'\.(png|jpe?g|webp|gif|bmp|tiff?)$',
  caseSensitive: false,
);

ComfyMediaKind _classifyKind(ComfyMediaKind fallback, String filename) {
  if (ComfyUi.isVideo(filename)) return ComfyMediaKind.video;
  if (_imageExtension.hasMatch(filename)) return ComfyMediaKind.image;
  return fallback;
}

const Map<String, String> _contentTypesByExtension = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'bmp': 'image/bmp',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'mov': 'video/quicktime',
};

String? _classifyContentType(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return null;
  return _contentTypesByExtension[filename.substring(dot + 1).toLowerCase()];
}

String _historyErrorMessage(JsonObject error) {
  for (final key in const ['exception_message', 'message', 'exception_type']) {
    final value = error[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return 'ComfyUI execution failed';
}

final class _ReplaySubject<T> {
  _ReplaySubject(this._value);

  T _value;
  final Set<MultiStreamController<T>> _controllers = {};

  Stream<T> get stream => Stream<T>.multi((controller) {
    controller.add(_value);
    _controllers.add(controller);
    controller.onCancel = () => _controllers.remove(controller);
  }, isBroadcast: true);

  void add(T value) {
    _value = value;
    for (final controller in _controllers.toList(growable: false)) {
      controller.add(value);
    }
  }
}
