import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hermes_android/core/models/comfy_ui_graph.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';

final class WorkflowDraftResult {
  const WorkflowDraftResult({
    required this.graph,
    required this.accepted,
    this.error,
  });

  final JsonObject graph;
  final bool accepted;
  final String? error;
}

abstract final class ComfyWorkflowCodec {
  static const int maxSourceBytes = 5 * 1024 * 1024;

  /// Whether [graph] is the legacy flat API-format map or ComfyUI's own
  /// "Save" export (nodes/links/positions). Derived from the JSON itself,
  /// never stored, so a raw-JSON edit can't leave a stale shape behind.
  static ComfyGraphShape shapeOf(JsonObject graph) => detectGraphShape(graph);

  static ImportedWorkflow decode(
    List<int> sourceBytes, {
    required String sourceFileName,
  }) {
    if (sourceBytes.length > maxSourceBytes) {
      throw const FormatException('Workflow JSON exceeds the 5 MiB limit');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(sourceBytes));
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Invalid workflow JSON', error);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Workflow root must be an object');
    }
    switch (detectGraphShape(decoded)) {
      case ComfyGraphShape.uiFormat:
        UiFormatGraph.parse(decoded);
      case ComfyGraphShape.flatApi:
        _requireGraphShape(decoded);
    }

    return ImportedWorkflow(
      sourceBytes: sourceBytes,
      graph: _deepCopy(decoded),
      sourceHash: sha256.convert(sourceBytes).toString(),
      sourceFileName: sourceFileName,
    );
  }

  static WorkflowDraftResult applyDraft({
    required JsonObject savedGraph,
    required List<int> draftBytes,
  }) {
    _requireGraphShape(savedGraph);
    try {
      final imported = decode(draftBytes, sourceFileName: 'draft.json');
      return WorkflowDraftResult(graph: imported.graph, accepted: true);
    } on FormatException catch (error) {
      return WorkflowDraftResult(
        graph: savedGraph,
        accepted: false,
        error: error.message.toString(),
      );
    }
  }

  /// Writes binding values directly into the flat graph's `inputs`. Every
  /// stored `workingGraph` is flat API-format by the time this runs --
  /// UI-format imports are normalized once, at import time (see
  /// `GenerationRepository.normalizeImportedGraph`).
  static JsonObject applyBindings(
    JsonObject graph,
    List<WorkflowInputBinding> bindings,
    Map<String, Object?> values,
  ) {
    final copy = _deepCopy(graph);
    for (final binding in bindings) {
      _bindingTarget(copy, binding);
    }
    for (final binding in bindings) {
      final hasValue = values.containsKey(binding.id);
      final value = hasValue ? values[binding.id] : binding.defaultValue;
      if (!hasValue && binding.defaultValue == null) {
        if (binding.required) {
          throw StateError('Missing required binding value: ${binding.id}');
        }
        continue;
      }
      _bindingTarget(copy, binding)[binding.inputName] = value;
    }
    return copy;
  }

  /// Directly writes one input's literal value on a flat API-format graph --
  /// the canvas's inline value editor (Stage 4) for legacy workflows.
  static JsonObject updateFlatGraphInput({
    required JsonObject graph,
    required String nodeId,
    required String inputName,
    required Object? value,
  }) {
    final copy = _deepCopy(graph);
    final node = copy[nodeId];
    if (node is! Map) {
      throw StateError('Unknown node: $nodeId');
    }
    final inputs = node['inputs'];
    if (inputs is! Map || !inputs.containsKey(inputName)) {
      throw StateError('Node $nodeId has no input $inputName');
    }
    inputs[inputName] = value;
    return copy;
  }

  static WorkflowValidationResult validateLocal({
    required JsonObject graph,
    required List<WorkflowInputBinding> bindings,
  }) {
    final issues = <WorkflowValidationIssue>[];
    try {
      _requireGraphShape(graph);
    } on FormatException catch (error) {
      issues.add(
        WorkflowValidationIssue(
          code: 'invalid_graph',
          message: error.message.toString(),
        ),
      );
      return WorkflowValidationResult(issues: issues);
    }

    for (final binding in bindings) {
      final node = graph[binding.nodeId];
      if (node is! Map) {
        issues.add(
          WorkflowValidationIssue(
            code: 'missing_node',
            message:
                'Binding ${binding.id} targets missing node ${binding.nodeId}',
            nodeId: binding.nodeId,
            inputName: binding.inputName,
          ),
        );
        continue;
      }
      final inputs = node['inputs'];
      if (inputs is! Map || !inputs.containsKey(binding.inputName)) {
        issues.add(
          WorkflowValidationIssue(
            code: 'missing_input',
            message:
                'Binding ${binding.id} targets missing input ${binding.inputName}',
            nodeId: binding.nodeId,
            inputName: binding.inputName,
          ),
        );
      }
    }
    return WorkflowValidationResult(issues: issues);
  }

  static WorkflowValidationResult validateObjectInfo({
    required ComfyWorkflowDefinition definition,
    required ComfyEndpoint endpoint,
    required JsonObject objectInfo,
  }) {
    final issues = <WorkflowValidationIssue>[];
    final mappedInputs = {
      for (final binding in definition.bindings)
        (binding.nodeId, binding.inputName),
    };

    for (final entry in definition.workingGraph.entries) {
      if (_isMetadata(entry.key)) continue;
      final node = entry.value;
      if (node is! Map) continue;
      final classType = node['class_type'];
      if (classType is! String) continue;
      final rawClassSchema = objectInfo[classType];
      if (rawClassSchema is! Map) {
        issues.add(
          WorkflowValidationIssue(
            code: 'missing_class',
            message: 'Server does not provide node class $classType',
            nodeId: entry.key,
          ),
        );
        continue;
      }

      final schemaInputs = _schemaInputs(rawClassSchema);
      for (final binding in definition.bindings.where(
        (binding) => binding.nodeId == entry.key,
      )) {
        if (!schemaInputs.containsKey(binding.inputName)) {
          issues.add(
            WorkflowValidationIssue(
              code: 'missing_input',
              message:
                  '$classType does not expose mapped input ${binding.inputName}',
              nodeId: entry.key,
              inputName: binding.inputName,
            ),
          );
        }
      }

      final nodeInputs = node['inputs'];
      if (nodeInputs is! Map) continue;
      for (final input in nodeInputs.entries) {
        final descriptor = schemaInputs[input.key];
        if (descriptor is! List || descriptor.isEmpty) continue;
        final value = input.value;
        if (isConnectionValue(value)) continue;
        final type = descriptor.first;
        final isMapped = mappedInputs.contains((entry.key, input.key));
        if (type is List) {
          if (!type.contains(value)) {
            final model = _looksLikeModelInput(input.key.toString());
            if (isMapped || model) {
              issues.add(
                WorkflowValidationIssue(
                  code: model ? 'missing_model' : 'enum_mismatch',
                  message: '$value is not offered for ${input.key}',
                  nodeId: entry.key,
                  inputName: input.key.toString(),
                ),
              );
            }
          }
          continue;
        }
        if (!isMapped || type is! String) continue;
        if (!_matchesPrimitive(type, value)) {
          issues.add(
            WorkflowValidationIssue(
              code: 'type_mismatch',
              message: '${input.key} does not match server type $type',
              nodeId: entry.key,
              inputName: input.key.toString(),
            ),
          );
          continue;
        }
        if (value is num && descriptor.length > 1 && descriptor[1] is Map) {
          final options = descriptor[1] as Map;
          final minimum = options['min'];
          final maximum = options['max'];
          if ((minimum is num && value < minimum) ||
              (maximum is num && value > maximum)) {
            issues.add(
              WorkflowValidationIssue(
                code: 'out_of_range',
                message: '${input.key} is outside the server range',
                nodeId: entry.key,
                inputName: input.key.toString(),
              ),
            );
          }
        }
      }
    }

    final normalizedEndpoint = endpoint.baseUri.toString();
    final canonicalObjectInfo = jsonEncode(_sortJson(objectInfo));
    final fingerprint = sha256
        .convert(utf8.encode('$normalizedEndpoint\n$canonicalObjectInfo'))
        .toString();
    return WorkflowValidationResult(
      issues: issues,
      fingerprint: fingerprint,
      endpoint: normalizedEndpoint,
    );
  }

  static List<WorkflowInputBinding> suggestBindings(JsonObject graph) {
    const definitions = <String, (BindingRole, WorkflowControlType, String)>{
      'text': (BindingRole.prompt, WorkflowControlType.multiline, 'Prompt'),
      'seed': (BindingRole.seed, WorkflowControlType.integer, 'Seed'),
      'width': (BindingRole.width, WorkflowControlType.integer, 'Width'),
      'height': (BindingRole.height, WorkflowControlType.integer, 'Height'),
      'steps': (BindingRole.steps, WorkflowControlType.integer, 'Steps'),
      'cfg': (BindingRole.cfg, WorkflowControlType.decimal, 'CFG'),
      'frames': (BindingRole.frames, WorkflowControlType.integer, 'Frames'),
      'fps': (BindingRole.fps, WorkflowControlType.integer, 'FPS'),
      'image': (
        BindingRole.inputImage,
        WorkflowControlType.file,
        'Input image',
      ),
    };
    final suggestions = <WorkflowInputBinding>[];
    for (final entry in graph.entries) {
      if (_isMetadata(entry.key) || entry.value is! Map) continue;
      final inputs = (entry.value as Map)['inputs'];
      if (inputs is! Map) continue;
      for (final inputName in inputs.keys.whereType<String>()) {
        final definition = definitions[inputName];
        if (definition == null) continue;
        final value = inputs[inputName];
        if (isConnectionValue(value)) continue;
        suggestions.add(
          WorkflowInputBinding(
            id: '${entry.key}_$inputName',
            nodeId: entry.key,
            inputName: inputName,
            label: definition.$3,
            role: definition.$1,
            controlType: definition.$2,
            required: false,
            defaultValue: value,
          ),
        );
      }
    }
    return suggestions;
  }

  static Map<dynamic, dynamic> _bindingTarget(
    JsonObject graph,
    WorkflowInputBinding binding,
  ) {
    final node = graph[binding.nodeId];
    if (node is! Map) {
      throw StateError('Binding ${binding.id} targets a missing node');
    }
    final inputs = node['inputs'];
    if (inputs is! Map || !inputs.containsKey(binding.inputName)) {
      throw StateError('Binding ${binding.id} targets a missing input');
    }
    return inputs;
  }

  static void _requireGraphShape(JsonObject graph) {
    for (final entry in graph.entries) {
      if (_isMetadata(entry.key)) continue;
      final node = entry.value;
      if (node is! Map ||
          node['class_type'] is! String ||
          node['inputs'] is! Map) {
        throw FormatException(
          'Node ${entry.key} must contain string class_type and object inputs',
        );
      }
    }
  }

  static JsonObject _deepCopy(JsonObject graph) =>
      jsonDecode(jsonEncode(graph)) as JsonObject;

  static bool _isMetadata(String key) => key.startsWith('_');

  static Map<dynamic, dynamic> _schemaInputs(
    Map<dynamic, dynamic> classSchema,
  ) {
    final input = classSchema['input'];
    if (input is! Map) return <dynamic, dynamic>{};
    final result = <dynamic, dynamic>{};
    for (final sectionName in const ['required', 'optional', 'hidden']) {
      final section = input[sectionName];
      if (section is Map) result.addAll(section);
    }
    return result;
  }

  /// Whether a flat graph input's value is a `[originNodeId, slot]` graph
  /// connection rather than a literal value.
  static bool isConnectionValue(Object? value) =>
      value is List && value.length == 2 && value.first is String;

  static bool _matchesPrimitive(String type, Object? value) => switch (type) {
    'STRING' => value is String,
    'INT' => value is int,
    'FLOAT' => value is num,
    'BOOLEAN' => value is bool,
    _ => true,
  };

  static bool _looksLikeModelInput(String inputName) {
    return const {
      'model_name',
      'checkpoint_name',
      'ckpt_name',
      'unet_name',
      'clip_name',
      'clip_name1',
      'clip_name2',
      'clip_name3',
      'control_net_name',
      'controlnet_name',
      'lora_name',
      'vae_name',
    }.contains(inputName.toLowerCase());
  }

  static Object? _sortJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _sortJson(value[key]),
      };
    }
    if (value is List) return value.map(_sortJson).toList(growable: false);
    return value;
  }
}
