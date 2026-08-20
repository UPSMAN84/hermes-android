import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'comfy_workflow.dart';

enum GenerationJobState {
  draft,
  submitting,
  queued,
  running,
  cancelling,
  reconciling,
  succeeded,
  failed,
  cancelled,
  uncertain,
}

final class GenerationRequest {
  /// [submittedValues] must never contain a [File] or raw binary bytes -- it
  /// is persisted verbatim onto the created [GenerationJob] record. Reference
  /// images (a file bound to a `file`-typed binding, keyed by binding id) are
  /// supplied out of band through [referenceImages] instead; the repository
  /// uploads them and substitutes the server-returned filename -- a plain
  /// string -- before the value is ever persisted.
  ///
  /// [useCharacterContext] is explicit rather than inferred from
  /// [sourceContextId] alone: a request can carry a context id for
  /// provenance (so the job/media record can link back to the character)
  /// without asking the repository to prefix the prompt or attach the avatar.
  GenerationRequest({
    required this.workflowId,
    required this.kind,
    required JsonObject submittedValues,
    this.sourceSessionId,
    this.sourceMessageId,
    this.sourceContextId,
    this.useCharacterContext = false,
    Map<String, File> referenceImages = const {},
  }) : submittedValues = _immutableObject(submittedValues),
       referenceImages = Map.unmodifiable(referenceImages);

  final String workflowId;
  final ComfyMediaKind kind;
  final JsonObject submittedValues;
  final String? sourceSessionId;
  final String? sourceMessageId;
  final String? sourceContextId;
  final bool useCharacterContext;
  final Map<String, File> referenceImages;

  Map<String, Object?> toJson() => {
    'workflowId': workflowId,
    'kind': kind.name,
    'submittedValues': submittedValues,
    'sourceSessionId': sourceSessionId,
    'sourceMessageId': sourceMessageId,
    'sourceContextId': sourceContextId,
    'useCharacterContext': useCharacterContext,
  };

  /// Reference images are process-local file handles and are never
  /// serialized; a request restored from JSON always has an empty
  /// [referenceImages] map.
  factory GenerationRequest.fromJson(Map<String, Object?> json) =>
      GenerationRequest(
        workflowId: _string(json['workflowId']),
        kind: _enumOr(
          ComfyMediaKind.values,
          json['kind'],
          ComfyMediaKind.image,
        ),
        submittedValues: _jsonObject(json['submittedValues']),
        sourceSessionId: _nullableString(json['sourceSessionId']),
        sourceMessageId: _nullableString(json['sourceMessageId']),
        sourceContextId: _nullableString(json['sourceContextId']),
        useCharacterContext: json['useCharacterContext'] == true,
      );
}

final class GenerationJob {
  GenerationJob({
    required this.localId,
    required this.workflowId,
    required this.kind,
    required this.state,
    required this.endpointFingerprint,
    required this.endpointSnapshot,
    required JsonObject submittedValues,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.promptId,
    this.progressValue = 0,
    this.progressMax = 0,
    this.currentNodeId,
    List<ComfyOutputRef> outputs = const [],
    this.sourceSessionId,
    this.sourceMessageId,
    this.sourceContextId,
    this.error,
    Map<String, Object?> nodeErrors = const {},
    DateTime? startedAt,
    DateTime? completedAt,
  }) : submittedValues = _immutableObject(submittedValues),
       outputs = List.unmodifiable(outputs),
       nodeErrors = _immutableObject(nodeErrors),
       createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc(),
       startedAt = startedAt?.toUtc(),
       completedAt = completedAt?.toUtc();

  final String localId;
  final String workflowId;
  final ComfyMediaKind kind;
  final GenerationJobState state;
  final String endpointFingerprint;
  final String endpointSnapshot;
  final JsonObject submittedValues;
  final String? promptId;
  final int progressValue;
  final int progressMax;
  final String? currentNodeId;
  final List<ComfyOutputRef> outputs;
  final String? sourceSessionId;
  final String? sourceMessageId;
  final String? sourceContextId;
  final String? error;
  final Map<String, Object?> nodeErrors;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;

  bool get isTerminal => const {
    GenerationJobState.succeeded,
    GenerationJobState.failed,
    GenerationJobState.cancelled,
    GenerationJobState.uncertain,
  }.contains(state);

  GenerationJob copyWith({
    GenerationJobState? state,
    Object? promptId = _absent,
    int? progressValue,
    int? progressMax,
    Object? currentNodeId = _absent,
    List<ComfyOutputRef>? outputs,
    Object? sourceSessionId = _absent,
    Object? sourceMessageId = _absent,
    Object? sourceContextId = _absent,
    Object? error = _absent,
    Map<String, Object?>? nodeErrors,
    DateTime? updatedAt,
    Object? startedAt = _absent,
    Object? completedAt = _absent,
  }) => GenerationJob(
    localId: localId,
    workflowId: workflowId,
    kind: kind,
    state: state ?? this.state,
    endpointFingerprint: endpointFingerprint,
    endpointSnapshot: endpointSnapshot,
    submittedValues: submittedValues,
    promptId: identical(promptId, _absent)
        ? this.promptId
        : promptId as String?,
    progressValue: progressValue ?? this.progressValue,
    progressMax: progressMax ?? this.progressMax,
    currentNodeId: identical(currentNodeId, _absent)
        ? this.currentNodeId
        : currentNodeId as String?,
    outputs: outputs ?? this.outputs,
    sourceSessionId: identical(sourceSessionId, _absent)
        ? this.sourceSessionId
        : sourceSessionId as String?,
    sourceMessageId: identical(sourceMessageId, _absent)
        ? this.sourceMessageId
        : sourceMessageId as String?,
    sourceContextId: identical(sourceContextId, _absent)
        ? this.sourceContextId
        : sourceContextId as String?,
    error: identical(error, _absent) ? this.error : error as String?,
    nodeErrors: nodeErrors ?? this.nodeErrors,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    startedAt: identical(startedAt, _absent)
        ? this.startedAt
        : startedAt as DateTime?,
    completedAt: identical(completedAt, _absent)
        ? this.completedAt
        : completedAt as DateTime?,
  );

  Map<String, Object?> toJson() => {
    'localId': localId,
    'workflowId': workflowId,
    'kind': kind.name,
    'state': state.name,
    'endpointFingerprint': endpointFingerprint,
    'endpointSnapshot': endpointSnapshot,
    'submittedValues': submittedValues,
    'promptId': promptId,
    'progressValue': progressValue,
    'progressMax': progressMax,
    'currentNodeId': currentNodeId,
    'outputs': outputs.map(_outputToJson).toList(growable: false),
    'sourceSessionId': sourceSessionId,
    'sourceMessageId': sourceMessageId,
    'sourceContextId': sourceContextId,
    'error': error,
    'nodeErrors': nodeErrors,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'startedAt': startedAt?.toUtc().toIso8601String(),
    'completedAt': completedAt?.toUtc().toIso8601String(),
  };

  factory GenerationJob.fromJson(Map<String, Object?> json) {
    final createdAt = _date(json['createdAt']);
    return GenerationJob(
      localId: _string(json['localId']),
      workflowId: _string(json['workflowId']),
      kind: _enumOr(ComfyMediaKind.values, json['kind'], ComfyMediaKind.image),
      state: _enumOr(
        GenerationJobState.values,
        json['state'],
        GenerationJobState.uncertain,
      ),
      endpointFingerprint: _string(json['endpointFingerprint']),
      endpointSnapshot: _string(json['endpointSnapshot']),
      submittedValues: _jsonObject(json['submittedValues']),
      promptId: _nullableNonBlankString(json['promptId']),
      progressValue: _nonNegativeInt(json['progressValue']),
      progressMax: _nonNegativeInt(json['progressMax']),
      currentNodeId: _nullableString(json['currentNodeId']),
      outputs: _outputs(json['outputs']),
      sourceSessionId: _nullableString(json['sourceSessionId']),
      sourceMessageId: _nullableString(json['sourceMessageId']),
      sourceContextId: _nullableString(json['sourceContextId']),
      error: _nullableString(json['error']),
      nodeErrors: _jsonObject(json['nodeErrors']),
      createdAt: createdAt,
      updatedAt: _date(json['updatedAt'], fallback: createdAt),
      startedAt: _nullableDate(json['startedAt']),
      completedAt: _nullableDate(json['completedAt']),
    );
  }
}

sealed class GenerationEvent {
  const GenerationEvent();
}

final class PromptAccepted extends GenerationEvent {
  const PromptAccepted(this.promptId);

  final String promptId;
}

final class PromptQueued extends GenerationEvent {
  const PromptQueued();
}

final class ExecutionStarted extends GenerationEvent {
  const ExecutionStarted();
}

final class ExecutionProgressed extends GenerationEvent {
  const ExecutionProgressed(this.nodeId, this.value, this.max);

  final String? nodeId;
  final int value;
  final int max;
}

final class ExecutionSucceeded extends GenerationEvent {
  const ExecutionSucceeded(this.outputs);

  final List<ComfyOutputRef> outputs;
}

final class ExecutionFailed extends GenerationEvent {
  factory ExecutionFailed(
    String message, {
    Map<String, Object?> nodeErrors = const {},
  }) => ExecutionFailed._(message, _immutableObject(nodeErrors));

  const ExecutionFailed._(this.message, this.nodeErrors);

  final String message;
  final Map<String, Object?> nodeErrors;
}

final class ExecutionInterrupted extends GenerationEvent {
  const ExecutionInterrupted();
}

final class SocketLost extends GenerationEvent {
  const SocketLost();
}

final class SubmissionUnknown extends GenerationEvent {
  const SubmissionUnknown(this.message);

  final String message;
}

final class QueueReconciled extends GenerationEvent {
  const QueueReconciled(this.present);

  final bool present;
}

final class HistoryReconciled extends GenerationEvent {
  const HistoryReconciled({
    required this.completed,
    this.outputs = const <ComfyOutputRef>[],
    this.error,
  });

  final bool completed;
  final List<ComfyOutputRef> outputs;
  final String? error;
}

final class QueueRemovalConfirmed extends GenerationEvent {
  const QueueRemovalConfirmed();
}

final class RestoreWithoutPromptId extends GenerationEvent {
  const RestoreWithoutPromptId();
}

final class CancelRequested extends GenerationEvent {
  const CancelRequested();
}

final class SubmissionFailed extends GenerationEvent {
  factory SubmissionFailed(
    String message, {
    Map<String, Object?> nodeErrors = const {},
  }) => SubmissionFailed._(message, _immutableObject(nodeErrors));

  const SubmissionFailed._(this.message, this.nodeErrors);

  final String message;
  final Map<String, Object?> nodeErrors;
}

final class ExecutionOutputsObserved extends GenerationEvent {
  const ExecutionOutputsObserved(this.outputs);

  final List<ComfyOutputRef> outputs;
}

GenerationJob reduceGenerationJob(
  GenerationJob job,
  GenerationEvent event,
  DateTime now,
) {
  final at = now.toUtc();
  final immutableTerminal =
      job.state == GenerationJobState.succeeded ||
      job.state == GenerationJobState.failed;
  if (immutableTerminal) return job;
  if (job.state == GenerationJobState.uncertain) return job;
  if (job.state == GenerationJobState.cancelled &&
      event is! ExecutionSucceeded &&
      event is! ExecutionFailed &&
      event is! HistoryReconciled) {
    return job;
  }

  switch (event) {
    case PromptAccepted(:final promptId):
      if (promptId.trim().isEmpty) return job;
      if (job.state != GenerationJobState.submitting &&
          job.state != GenerationJobState.reconciling) {
        return job;
      }
      return job.copyWith(
        state: GenerationJobState.queued,
        promptId: promptId,
        error: null,
        updatedAt: at,
      );
    case PromptQueued():
      if (!const {
        GenerationJobState.submitting,
        GenerationJobState.queued,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      return job.copyWith(state: GenerationJobState.queued, updatedAt: at);
    case ExecutionStarted():
      if (!const {
        GenerationJobState.submitting,
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      return job.copyWith(
        state: GenerationJobState.running,
        startedAt: job.startedAt ?? at,
        updatedAt: at,
      );
    case ExecutionProgressed(:final nodeId, :final value, :final max):
      if (!const {
        GenerationJobState.submitting,
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      final safeMax = max < 0 ? 0 : max;
      final safeValue = value.clamp(
        0,
        safeMax == 0 ? value.clamp(0, 1 << 31) : safeMax,
      );
      return job.copyWith(
        state: job.state == GenerationJobState.cancelling
            ? GenerationJobState.cancelling
            : GenerationJobState.running,
        currentNodeId: nodeId,
        progressValue: safeValue,
        progressMax: safeMax,
        startedAt: job.startedAt ?? at,
        updatedAt: at,
      );
    case ExecutionSucceeded(:final outputs):
      if (!_canReceiveExecutionTerminal(job.state)) return job;
      return job.copyWith(
        state: GenerationJobState.succeeded,
        outputs: outputs.isEmpty ? job.outputs : outputs,
        error: null,
        nodeErrors: const {},
        completedAt: at,
        updatedAt: at,
      );
    case ExecutionFailed(:final message, :final nodeErrors):
      if (!_canReceiveExecutionTerminal(job.state)) return job;
      return job.copyWith(
        state: GenerationJobState.failed,
        error: message,
        nodeErrors: nodeErrors,
        completedAt: at,
        updatedAt: at,
      );
    case ExecutionInterrupted():
      if (!const {
        GenerationJobState.running,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      return job.copyWith(
        state: GenerationJobState.cancelled,
        completedAt: at,
        updatedAt: at,
      );
    case SocketLost():
      if (!const {
        GenerationJobState.submitting,
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      return job.copyWith(
        state: job.promptId == null
            ? GenerationJobState.uncertain
            : GenerationJobState.reconciling,
        updatedAt: at,
      );
    case SubmissionUnknown(:final message):
      if (job.state != GenerationJobState.submitting) return job;
      return job.copyWith(
        state: GenerationJobState.uncertain,
        error: message,
        updatedAt: at,
      );
    case QueueReconciled(:final present):
      if (!const {
        GenerationJobState.queued,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      if (!present || job.state == GenerationJobState.cancelling) return job;
      return job.copyWith(state: GenerationJobState.queued, updatedAt: at);
    case HistoryReconciled(:final completed, :final outputs, :final error):
      if (!const {
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
        GenerationJobState.cancelled,
      }.contains(job.state)) {
        return job;
      }
      if (job.state == GenerationJobState.cancelled &&
          !completed &&
          error == null) {
        return job;
      }
      if (error != null) {
        return job.copyWith(
          state: GenerationJobState.failed,
          error: error,
          completedAt: at,
          updatedAt: at,
        );
      }
      if (completed) {
        return job.copyWith(
          state: GenerationJobState.succeeded,
          outputs: outputs.isEmpty ? job.outputs : outputs,
          error: null,
          nodeErrors: const {},
          completedAt: at,
          updatedAt: at,
        );
      }
      if (job.state == GenerationJobState.cancelling) return job;
      return job.copyWith(
        state: GenerationJobState.running,
        startedAt: job.startedAt ?? at,
        updatedAt: at,
      );
    case QueueRemovalConfirmed():
      if (!const {
        GenerationJobState.queued,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      return job.copyWith(
        state: GenerationJobState.cancelled,
        completedAt: at,
        updatedAt: at,
      );
    case RestoreWithoutPromptId():
      if (job.state != GenerationJobState.submitting || job.promptId != null) {
        return job;
      }
      return job.copyWith(state: GenerationJobState.uncertain, updatedAt: at);
    case CancelRequested():
      if (!const {
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      return job.copyWith(state: GenerationJobState.cancelling, updatedAt: at);
    case SubmissionFailed(:final message, :final nodeErrors):
      if (job.state != GenerationJobState.submitting) return job;
      return job.copyWith(
        state: GenerationJobState.failed,
        error: message,
        nodeErrors: nodeErrors,
        completedAt: at,
        updatedAt: at,
      );
    case ExecutionOutputsObserved(:final outputs):
      if (!const {
        GenerationJobState.submitting,
        GenerationJobState.queued,
        GenerationJobState.running,
        GenerationJobState.cancelling,
        GenerationJobState.reconciling,
      }.contains(job.state)) {
        return job;
      }
      if (outputs.isEmpty) return job;
      return job.copyWith(
        state: job.state == GenerationJobState.cancelling
            ? GenerationJobState.cancelling
            : GenerationJobState.running,
        outputs: _mergeOutputs(job.outputs, outputs),
        startedAt: job.startedAt ?? at,
        updatedAt: at,
      );
  }
}

List<ComfyOutputRef> _mergeOutputs(
  List<ComfyOutputRef> existing,
  List<ComfyOutputRef> incoming,
) {
  final seen = <String>{
    for (final output in existing)
      '${output.type} ${output.subfolder} ${output.filename}',
  };
  final merged = List<ComfyOutputRef>.of(existing);
  for (final output in incoming) {
    final key = '${output.type} ${output.subfolder} ${output.filename}';
    if (seen.add(key)) merged.add(output);
  }
  return List.unmodifiable(merged);
}

bool _canReceiveExecutionTerminal(GenerationJobState state) => const {
  GenerationJobState.queued,
  GenerationJobState.running,
  GenerationJobState.cancelling,
  GenerationJobState.reconciling,
  GenerationJobState.cancelled,
}.contains(state);

const Object _absent = Object();
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

JsonObject _immutableObject(Map<Object?, Object?> source) =>
    UnmodifiableMapView(
      source.map(
        (key, value) => MapEntry(key.toString(), _immutableJsonValue(value)),
      ),
    );

Object? _immutableJsonValue(Object? value) {
  if (value is File || value is Uint8List || value is ByteData) {
    throw ArgumentError.value(
      value,
      'value',
      'submittedValues/nodeErrors must be JSON-safe: no File or raw bytes',
    );
  }
  if (value is Map) return _immutableObject(value);
  if (value is List) {
    return UnmodifiableListView(value.map(_immutableJsonValue).toList());
  }
  return value;
}

Map<String, Object?> _outputToJson(ComfyOutputRef output) => {
  'filename': output.filename,
  'subfolder': output.subfolder,
  'type': output.type,
};

String _string(Object? value) => value is String ? value : '';

String? _nullableString(Object? value) => value is String ? value : null;

String? _nullableNonBlankString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

int _nonNegativeInt(Object? value) => value is int && value >= 0 ? value : 0;

T _enumOr<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is String) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
  }
  return fallback;
}

JsonObject _jsonObject(Object? raw) => raw is Map
    ? _immutableObject(raw)
    : UnmodifiableMapView(const <String, Object?>{});

List<ComfyOutputRef> _outputs(Object? raw) {
  if (raw is! List) return const [];
  final outputs = <ComfyOutputRef>[];
  for (final value in raw) {
    if (value is! Map) continue;
    try {
      outputs.add(
        ComfyOutputRef(
          filename: _string(value['filename']),
          subfolder: _string(value['subfolder']),
          type: _string(value['type']).isEmpty
              ? 'output'
              : _string(value['type']),
        ),
      );
    } on FormatException {
      // Preserve the rest of a record when one legacy output is unsafe.
    }
  }
  return List.unmodifiable(outputs);
}

DateTime _date(Object? raw, {DateTime? fallback}) {
  if (raw is String) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toUtc();
  }
  return fallback?.toUtc() ?? _epoch;
}

DateTime? _nullableDate(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}
