import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';

abstract final class ComfyWorkflowCodec {
  static const int maxSourceBytes = 5 * 1024 * 1024;

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
    _requireGraphShape(decoded);

    return ImportedWorkflow(
      sourceBytes: sourceBytes,
      graph: _deepCopy(decoded),
      sourceHash: sha256.convert(sourceBytes).toString(),
      sourceFileName: sourceFileName,
    );
  }

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
        if (_isConnection(value)) continue;
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
        suggestions.add(
          WorkflowInputBinding(
            id: '${entry.key}_$inputName',
            nodeId: entry.key,
            inputName: inputName,
            label: definition.$3,
            role: definition.$1,
            controlType: definition.$2,
            required: false,
            defaultValue: inputs[inputName],
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

  static bool _isConnection(Object? value) =>
      value is List && value.length == 2 && value.first is String;

  static bool _matchesPrimitive(String type, Object? value) => switch (type) {
    'STRING' => value is String,
    'INT' => value is int,
    'FLOAT' => value is num,
    'BOOLEAN' => value is bool,
    _ => true,
  };

  static bool _looksLikeModelInput(String inputName) {
    final normalized = inputName.toLowerCase();
    return normalized.contains('model') ||
        normalized.contains('checkpoint') ||
        normalized.contains('ckpt') ||
        normalized.contains('lora') ||
        normalized.contains('vae');
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
