import '../models/comfy_ui_graph.dart';
import '../models/comfy_workflow.dart';

/// Converts a parsed [UiFormatGraph] (ComfyUI's own "Save" export) into the
/// flat `{nodeId: {class_type, inputs}}` map ComfyUI's `/prompt` endpoint
/// expects -- mirroring what ComfyUI's own frontend does when it submits a
/// graph, using a fresh `/object_info` schema fetch to disambiguate which
/// inputs are live sockets versus positional widget values.
///
/// This is the single most fragile part of the whole node-canvas feature:
/// see the module-level notes on `_isWidgetCapable`/`_hasControlAfterGenerate`
/// for why. Get it wrong and a seed/steps/cfg value silently lands on the
/// wrong field instead of failing loudly -- so every path that can't resolve
/// a value confidently returns a named [WorkflowValidationIssue] instead of
/// guessing.
sealed class GraphConversionResult {
  const GraphConversionResult();
}

final class ConvertedPrompt extends GraphConversionResult {
  const ConvertedPrompt(this.prompt);

  final JsonObject prompt;
}

final class ConversionFailed extends GraphConversionResult {
  const ConversionFailed(this.issues);

  final List<WorkflowValidationIssue> issues;
}

/// Which kind of editor control a widget-capable input should render as on
/// the canvas -- matches ComfyUI's own widget vocabulary closely enough for
/// direct in-place editing (a dropdown for a combo, a real text box for a
/// prompt, etc.) rather than a generic value-as-text row.
enum WidgetEditorKind { text, multiline, integer, decimal, toggle, dropdown }

/// One schema-declared input in class-schema order, with enough information
/// to decide whether it's ever a positional widget slot, and how to render
/// it as a live editor when it is.
final class SchemaInput {
  const SchemaInput({
    required this.name,
    required this.isWidgetCapable,
    required this.hasControlAfterGenerate,
    required this.editorKind,
    required this.required,
    this.choices = const [],
  });

  final String name;
  final bool isWidgetCapable;
  final bool hasControlAfterGenerate;
  final WidgetEditorKind editorKind;

  /// True for ComfyUI's own `required` schema section, false for `optional`.
  /// An unwired/unset *optional* input is valid in ComfyUI (the node just
  /// runs with its own default), so it must never fail conversion the way
  /// an unwired required one does -- confirmed via a real failure where a
  /// workflow that runs fine directly in ComfyUI failed here because an
  /// optional socket was treated as mandatory.
  final bool required;

  /// Populated only when [editorKind] is [WidgetEditorKind.dropdown].
  final List<String> choices;
}

abstract final class ComfyUiGraphConverter {
  /// Overrides are keyed by (nodeId as string, inputName) -- the same
  /// addressing [WorkflowInputBinding] already uses. A bound value always
  /// wins over whatever the graph would otherwise supply, but the input it
  /// replaces still consumes its positional `widgets_values` slot if it
  /// would have (see [resolveNodeInputs]), so later inputs on the same node
  /// stay aligned.
  static GraphConversionResult convert({
    required UiFormatGraph graph,
    required JsonObject objectInfo,
    Map<(String, String), Object?> overrides = const {},
  }) {
    final issues = <WorkflowValidationIssue>[];
    final prompt = <String, dynamic>{};

    final dependedOn = <int>{};
    for (final link in graph.links) {
      dependedOn.add(link.originNodeId);
    }

    final excludedNodeIds = <int>{};
    for (final node in graph.nodes) {
      if (node.mode == 2) {
        excludedNodeIds.add(node.id);
        continue;
      }
      if (node.mode == 4 && !dependedOn.contains(node.id)) {
        excludedNodeIds.add(node.id);
      }
    }

    for (final node in graph.nodes) {
      if (excludedNodeIds.contains(node.id)) continue;

      if (node.mode == 4) {
        issues.add(
          WorkflowValidationIssue(
            code: 'unsupported_bypass',
            message:
                'Node ${node.id} (${node.displayTitle}) is bypassed but still '
                'has active downstream connections. Un-bypass it in ComfyUI '
                'and re-export -- feed-through rewiring is not supported.',
            nodeId: node.id.toString(),
          ),
        );
        continue;
      }

      final classType = resolveClassType(node, objectInfo);
      if (classType == null) {
        issues.add(
          WorkflowValidationIssue(
            code: 'missing_class',
            message: 'Server does not provide node class ${node.type}',
            nodeId: node.id.toString(),
          ),
        );
        continue;
      }

      final schema = objectInfo[classType];
      if (schema is! Map) {
        issues.add(
          WorkflowValidationIssue(
            code: 'missing_class',
            message: 'Server does not provide node class $classType',
            nodeId: node.id.toString(),
          ),
        );
        continue;
      }

      final nodeOverrides = <String, Object?>{
        for (final entry in overrides.entries)
          if (entry.key.$1 == node.id.toString()) entry.key.$2: entry.value,
      };

      final resolved = resolveNodeInputs(
        node: node,
        schema: schema,
        graph: graph,
        excludedNodeIds: excludedNodeIds,
        overrides: nodeOverrides,
      );
      issues.addAll(resolved.issues);
      if (resolved.issues.isEmpty) {
        prompt[node.id.toString()] = {
          'class_type': classType,
          'inputs': resolved.inputs,
        };
      }
    }

    if (issues.isNotEmpty) return ConversionFailed(List.unmodifiable(issues));
    return ConvertedPrompt(prompt);
  }

  /// `node.type`, falling back to `properties['Node name for S&R']` --
  /// ComfyUI's own escape hatch for renamed/legacy node types -- when the
  /// server's `/object_info` doesn't recognize the raw type string.
  static String? resolveClassType(UiGraphNode node, JsonObject objectInfo) {
    if (objectInfo[node.type] is Map) return node.type;
    final alias = node.properties['Node name for S&R'];
    if (alias is String && objectInfo[alias] is Map) return alias;
    return null;
  }

  /// Ordered (required-then-optional, hidden excluded) schema inputs for one
  /// node class. Hidden inputs (e.g. `prompt`, `unique_id`) are backend-
  /// injected and never occupy a socket or a `widgets_values` slot, so they
  /// must never be walked here.
  static List<SchemaInput> orderedSchemaInputs(Map<dynamic, dynamic> schema) {
    final input = schema['input'];
    if (input is! Map) return const [];
    final result = <SchemaInput>[];
    for (final sectionName in const ['required', 'optional']) {
      final section = input[sectionName];
      if (section is! Map) continue;
      for (final entry in section.entries) {
        final name = entry.key.toString();
        final descriptor = entry.value;
        result.add(
          SchemaInput(
            name: name,
            isWidgetCapable: _isWidgetCapable(descriptor),
            hasControlAfterGenerate: _hasControlAfterGenerate(descriptor),
            editorKind: _editorKindFor(descriptor),
            required: sectionName == 'required',
            choices: _choicesFor(descriptor),
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  /// Resolves every schema input for one node into either a live connection
  /// (`[originNodeId, originSlot]`) or a value, walking `widgets_values`
  /// positionally only for inputs that actually consume a slot -- a widget
  /// currently satisfied by a live link never did, matching a confirmed
  /// ComfyUI frontend behavior change (widgets converted to a connected
  /// input are removed from `widgets_values` entirely, not left as a gap).
  static ResolvedNodeInputs resolveNodeInputs({
    required UiGraphNode node,
    required Map<dynamic, dynamic> schema,
    required UiFormatGraph graph,
    required Set<int> excludedNodeIds,
    Map<String, Object?> overrides = const {},
  }) {
    final issues = <WorkflowValidationIssue>[];
    final inputs = <String, Object?>{};
    var widgetIndex = 0;

    for (final schemaInput in orderedSchemaInputs(schema)) {
      final name = schemaInput.name;
      final controlSlots = schemaInput.hasControlAfterGenerate ? 2 : 1;
      final socket = _findSocket(node.inputs, name);

      if (socket != null && socket.link != null) {
        final link = _findLink(graph.links, socket.link!);
        if (link == null || excludedNodeIds.contains(link.originNodeId)) {
          if (schemaInput.required) {
            issues.add(
              WorkflowValidationIssue(
                code: 'missing_link',
                message:
                    'Input $name on node ${node.id} (${node.displayTitle}) '
                    'has no resolvable connection.',
                nodeId: node.id.toString(),
                inputName: name,
              ),
            );
          }
          continue;
        }
        inputs[name] = [link.originNodeId.toString(), link.originSlot];
        continue; // A live-linked input never occupies a widgets_values slot.
      }

      final canFallBackToWidget =
          schemaInput.isWidgetCapable || (socket?.hasWidgetMarker ?? false);
      if (!canFallBackToWidget) {
        // An unwired *optional* socket is valid ComfyUI: the node runs with
        // its own default. Only a required one failing to connect is a
        // real problem -- confirmed via a workflow that runs fine directly
        // in ComfyUI but was wrongly failed here before this fix.
        if (schemaInput.required) {
          issues.add(
            WorkflowValidationIssue(
              code: 'missing_link',
              message:
                  'Required input $name on node ${node.id} '
                  '(${node.displayTitle}) is not connected.',
              nodeId: node.id.toString(),
              inputName: name,
            ),
          );
        }
        continue;
      }

      if (overrides.containsKey(name)) {
        inputs[name] = overrides[name];
      } else {
        final named = node.widgetsValuesNamed;
        if (named != null && named.containsKey(name)) {
          inputs[name] = named[name];
        } else if (widgetIndex < node.widgetsValues.length) {
          inputs[name] = node.widgetsValues[widgetIndex];
        } else if (schemaInput.required) {
          issues.add(
            WorkflowValidationIssue(
              code: 'missing_value',
              message:
                  'No value available for $name on node ${node.id} '
                  '(${node.displayTitle}).',
              nodeId: node.id.toString(),
              inputName: name,
            ),
          );
        }
      }
      // Whether the value came from an override, the named dict, or a
      // position, the slot is consumed either way -- overrides stand in for
      // what the widget would have supplied, they don't remove the slot.
      widgetIndex += controlSlots;
    }

    return ResolvedNodeInputs(inputs: inputs, issues: issues);
  }
}

final class ResolvedNodeInputs {
  const ResolvedNodeInputs({required this.inputs, required this.issues});


  final Map<String, Object?> inputs;
  final List<WorkflowValidationIssue> issues;
}

UiGraphSocket? _findSocket(List<UiGraphSocket> sockets, String name) {
  for (final socket in sockets) {
    if (socket.name == name) return socket;
  }
  return null;
}

UiGraphLink? _findLink(List<UiGraphLink> links, int id) {
  for (final link in links) {
    if (link.id == id) return link;
  }
  return null;
}

/// ComfyUI's own built-in "shared object" types -- the ones that can only
/// ever come from another node's output, never a widget. Everything else,
/// including a custom node's own made-up scalar type name (e.g. a dynamic
/// "ASPECT_RATIO" combo populated in Python rather than declared as a plain
/// list), defaults to widget-capable: real ComfyUI custom nodes routinely
/// register their own widget for a type nobody outside that node's own JS
/// extension knows about, and `/object_info` can't tell us that either way.
/// Confirmed via a real failure: `ResolutionSelector`'s `aspect_ratio`
/// input was misclassified as an unwired hard socket under an earlier
/// allow-list approach (INT/FLOAT/STRING/BOOLEAN/enum-only), even though the
/// file had a real widget value sitting right there -- defaulting to
/// "probably a widget" is far more often correct than defaulting to
/// "must be wired".
const _hardSocketTypes = {
  'MODEL',
  'CLIP',
  'VAE',
  'CONDITIONING',
  'LATENT',
  'IMAGE',
  'MASK',
  'CONTROL_NET',
  'CLIP_VISION',
  'CLIP_VISION_OUTPUT',
  'STYLE_MODEL',
  'GLIGEN',
  'UPSCALE_MODEL',
  'SAMPLER',
  'SIGMAS',
  'NOISE',
  'GUIDER',
  'PHOTOMAKER',
  'AUDIO',
  'VIDEO',
  'WEBCAM',
  'POINT',
  'MESH',
  'VOXEL',
  'HOOKS',
};

/// A schema input is a positional widget candidate unless its declared type
/// is a known hard-socket-only type ([_hardSocketTypes]), or its options
/// explicitly force it to be a socket (`forceInput`/`defaultInput`).
bool _isWidgetCapable(Object? descriptor) {
  if (descriptor is! List || descriptor.isEmpty) return false;
  final type = descriptor.first;
  final options = descriptor.length > 1 && descriptor[1] is Map
      ? descriptor[1] as Map
      : const {};
  if (options['forceInput'] == true || options['defaultInput'] == true) {
    return false;
  }
  if (type is List) return true;
  if (type is String) {
    return !_hardSocketTypes.contains(type.toUpperCase());
  }
  return false;
}

/// Which editor control a schema descriptor implies. An unrecognized custom
/// scalar type (already treated as widget-capable by [_isWidgetCapable])
/// renders as a dropdown when its options carry an explicit choice list
/// (some custom nodes do this for a type not shaped like ComfyUI's own
/// plain-list enum), otherwise a plain text field so it's still editable.
WidgetEditorKind _editorKindFor(Object? descriptor) {
  if (descriptor is! List || descriptor.isEmpty) return WidgetEditorKind.text;
  final type = descriptor.first;
  final options = descriptor.length > 1 && descriptor[1] is Map
      ? descriptor[1] as Map
      : const {};
  if (type is List) return WidgetEditorKind.dropdown;
  if (type is String) {
    switch (type.toUpperCase()) {
      case 'INT':
        return WidgetEditorKind.integer;
      case 'FLOAT':
        return WidgetEditorKind.decimal;
      case 'BOOLEAN':
        return WidgetEditorKind.toggle;
      case 'STRING':
        return options['multiline'] == true
            ? WidgetEditorKind.multiline
            : WidgetEditorKind.text;
      default:
        return _rawChoices(options) != null
            ? WidgetEditorKind.dropdown
            : WidgetEditorKind.text;
    }
  }
  return WidgetEditorKind.text;
}

List<String> _choicesFor(Object? descriptor) {
  if (descriptor is! List || descriptor.isEmpty) return const [];
  final type = descriptor.first;
  if (type is List) return type.map((choice) => choice.toString()).toList();
  final options = descriptor.length > 1 && descriptor[1] is Map
      ? descriptor[1] as Map
      : const {};
  final raw = _rawChoices(options);
  return raw?.map((choice) => choice.toString()).toList() ?? const [];
}

List<dynamic>? _rawChoices(Map<dynamic, dynamic> options) {
  final choices = options['choices'] ?? options['values'];
  return choices is List ? choices : null;
}

/// ComfyUI's frontend adds a synthetic, schema-invisible second widget
/// (the "randomize/increment/decrement/fixed" control) immediately after any
/// input whose declared options carry a truthy (or string-named)
/// `control_after_generate` flag -- confirmed present in real `/object_info`
/// responses for seed-style inputs. That extra widget consumes its own
/// `widgets_values` slot but is never itself a named schema input.
bool _hasControlAfterGenerate(Object? descriptor) {
  if (descriptor is! List || descriptor.length < 2 || descriptor[1] is! Map) {
    return false;
  }
  final value = (descriptor[1] as Map)['control_after_generate'];
  return value == true || (value is String && value.isNotEmpty);
}
