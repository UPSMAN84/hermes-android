import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/comfy_workflow.dart';
import '../services/comfy_workflow_codec.dart';

/// Result of a [WorkflowBindingEditorScreen] session: the flat graph with
/// every row's value edit applied, plus the bindings built from rows the
/// user exposed as app controls. `name`/`kind` are only meaningful when the
/// screen was opened with `showNameAndKind: true` (the import flow).
final class WorkflowBindingEditorResult {
  const WorkflowBindingEditorResult({
    this.name,
    this.kind,
    required this.graph,
    required this.bindings,
  });

  final String? name;
  final ComfyMediaKind? kind;
  final JsonObject graph;
  final List<WorkflowInputBinding> bindings;
}

/// One screen, used both to review a freshly-imported workflow's suggested
/// bindings and to edit an existing workflow's bindings -- a flat scrollable
/// list, grouped by node, one row per literal input. Every row's current
/// value is always editable; a per-row "Expose as app control" toggle
/// reveals the binding metadata fields. Operates purely on local state and
/// pops a single [WorkflowBindingEditorResult] on Save -- the caller
/// persists once, in one repository round-trip.
class WorkflowBindingEditorScreen extends StatefulWidget {
  const WorkflowBindingEditorScreen({
    super.key,
    required this.graph,
    required this.initialBindings,
    required this.title,
    this.showNameAndKind = false,
    this.initialName,
    this.initialKind,
  });

  /// Already-flat `{nodeId: {class_type, inputs}}` graph.
  final JsonObject graph;
  final List<WorkflowInputBinding> initialBindings;
  final String title;
  final bool showNameAndKind;
  final String? initialName;
  final ComfyMediaKind? initialKind;

  @override
  State<WorkflowBindingEditorScreen> createState() =>
      _WorkflowBindingEditorScreenState();
}

class _WorkflowBindingEditorScreenState
    extends State<WorkflowBindingEditorScreen> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName ?? '',
  );
  late ComfyMediaKind _kind = widget.initialKind ?? ComfyMediaKind.image;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _collapsedNodeIds = {};
  late final List<_NodeGroup> _groups = _buildGroups();

  List<_NodeGroup> _buildGroups() {
    final groups = <_NodeGroup>[];
    for (final entry in widget.graph.entries) {
      if (entry.key.startsWith('_')) continue;
      final node = entry.value;
      if (node is! Map) continue;
      final classType = node['class_type'];
      final inputs = node['inputs'];
      if (classType is! String || inputs is! Map) continue;
      final rows = <_BindingRow>[];
      for (final inputEntry in inputs.entries) {
        final inputName = inputEntry.key.toString();
        final value = inputEntry.value;
        if (ComfyWorkflowCodec.isConnectionValue(value)) continue;
        rows.add(
          _BindingRow(
            nodeId: entry.key,
            inputName: inputName,
            currentValue: value,
            existing: _findBinding(entry.key, inputName),
          ),
        );
      }
      if (rows.isEmpty) continue;
      groups.add(
        _NodeGroup(nodeId: entry.key, classType: classType, rows: rows),
      );
    }
    return groups;
  }

  WorkflowInputBinding? _findBinding(String nodeId, String inputName) {
    for (final binding in widget.initialBindings) {
      if (binding.nodeId == nodeId && binding.inputName == inputName) {
        return binding;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    for (final group in _groups) {
      for (final row in group.rows) {
        row.dispose();
      }
    }
    super.dispose();
  }

  void _save() {
    final copy = jsonDecode(jsonEncode(widget.graph)) as JsonObject;
    final bindings = <WorkflowInputBinding>[];
    for (final group in _groups) {
      for (final row in group.rows) {
        final node = copy[row.nodeId];
        if (node is Map) {
          final inputs = node['inputs'];
          if (inputs is Map) inputs[row.inputName] = row.parsedValue();
        }
        if (row.exposed) bindings.add(row.toBinding());
      }
    }
    Navigator.of(context).pop(
      WorkflowBindingEditorResult(
        name: widget.showNameAndKind
            ? (_nameController.text.trim().isEmpty
                  ? widget.initialName
                  : _nameController.text.trim())
            : null,
        kind: widget.showNameAndKind ? _kind : null,
        graph: copy,
        bindings: bindings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = _searchController.text.trim().toLowerCase();
    final searching = filter.isNotEmpty;
    final visibleGroups = <(_NodeGroup, List<_BindingRow>, bool)>[];
    for (final group in _groups) {
      List<_BindingRow> rows;
      if (!searching) {
        rows = group.rows;
      } else {
        final groupMatches =
            group.classType.toLowerCase().contains(filter) ||
            group.nodeId.toLowerCase().contains(filter);
        rows = groupMatches
            ? group.rows
            : group.rows
                  .where(
                    (row) =>
                        row.inputName.toLowerCase().contains(filter) ||
                        row.labelController.text.toLowerCase().contains(
                          filter,
                        ),
                  )
                  .toList(growable: false);
      }
      if (rows.isEmpty) continue;
      final expanded = searching || !_collapsedNodeIds.contains(group.nodeId);
      visibleGroups.add((group, rows, expanded));
    }

    var hasErrors = false;
    for (final group in _groups) {
      for (final row in group.rows) {
        if (row.validate() != null) {
          hasErrors = true;
          break;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            key: const Key('binding-editor-save'),
            onPressed: hasErrors ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (widget.showNameAndKind) ...[
                  TextField(
                    key: const Key('binding-editor-name'),
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ComfyMediaKind>(
                    segments: const [
                      ButtonSegment(
                        value: ComfyMediaKind.image,
                        label: Text('Image'),
                      ),
                      ButtonSegment(
                        value: ComfyMediaKind.video,
                        label: Text('Video'),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (selection) =>
                        setState(() => _kind = selection.first),
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  key: const Key('binding-editor-search'),
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'Search inputs',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          Expanded(
            child: visibleGroups.isEmpty
                ? const Center(child: Text('No matching inputs.'))
                : ListView(
                    children: [
                      for (final (group, rows, expanded) in visibleGroups)
                        _buildGroup(group, rows: rows, expanded: expanded),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroup(
    _NodeGroup group, {
    required List<_BindingRow> rows,
    required bool expanded,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: Key('binding-group-${group.nodeId}'),
            onTap: () => setState(() {
              if (_collapsedNodeIds.contains(group.nodeId)) {
                _collapsedNodeIds.remove(group.nodeId);
              } else {
                _collapsedNodeIds.add(group.nodeId);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Icon(expanded ? Icons.expand_more : Icons.chevron_right),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${group.classType} (#${group.nodeId})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
              child: Column(
                children: [for (final row in rows) _buildRow(row)],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(_BindingRow row) {
    final error = row.validate();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.inputName,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                if (row.exposed) const Icon(Icons.link, size: 16),
              ],
            ),
            TextField(
              key: Key('binding-row-${row.nodeId}-${row.inputName}-value'),
              controller: row.valueController,
              decoration: const InputDecoration(labelText: 'Value'),
              onChanged: (_) => setState(() {}),
            ),
            CheckboxListTile(
              key: Key('binding-row-${row.nodeId}-${row.inputName}-expose'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Expose as app control'),
              value: row.exposed,
              onChanged: (value) =>
                  setState(() => row.exposed = value ?? false),
            ),
            if (row.exposed) ...[
              TextField(
                key: Key('binding-row-${row.nodeId}-${row.inputName}-label'),
                controller: row.labelController,
                decoration: const InputDecoration(labelText: 'Label'),
                onChanged: (_) => setState(() {}),
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<BindingRole>(
                      key: Key('binding-row-${row.nodeId}-${row.inputName}-role'),
                      initialValue: row.role,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Role'),
                      items: [
                        for (final value in BindingRole.values)
                          DropdownMenuItem(
                            value: value,
                            child: Text(value.name),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => row.role = value ?? row.role),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<WorkflowControlType>(
                      key: Key(
                        'binding-row-${row.nodeId}-${row.inputName}-controlType',
                      ),
                      initialValue: row.controlType,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Control'),
                      items: [
                        for (final value in WorkflowControlType.values)
                          DropdownMenuItem(
                            value: value,
                            child: Text(value.name),
                          ),
                      ],
                      onChanged: (value) => setState(
                        () => row.controlType = value ?? row.controlType,
                      ),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                key: Key('binding-row-${row.nodeId}-${row.inputName}-required'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Required'),
                value: row.required,
                onChanged: (value) =>
                    setState(() => row.required = value ?? false),
              ),
              if (row.isNumeric)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: Key(
                          'binding-row-${row.nodeId}-${row.inputName}-min',
                        ),
                        controller: row.minController,
                        decoration: const InputDecoration(labelText: 'Min'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: Key(
                          'binding-row-${row.nodeId}-${row.inputName}-max',
                        ),
                        controller: row.maxController,
                        decoration: const InputDecoration(labelText: 'Max'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              if (row.controlType == WorkflowControlType.enumeration)
                TextField(
                  key: Key(
                    'binding-row-${row.nodeId}-${row.inputName}-choices',
                  ),
                  controller: row.choicesController,
                  decoration: const InputDecoration(
                    labelText: 'Choices (comma-separated)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _NodeGroup {
  const _NodeGroup({
    required this.nodeId,
    required this.classType,
    required this.rows,
  });

  final String nodeId;
  final String classType;
  final List<_BindingRow> rows;
}

/// Mutable editing state for one input row. `exposed` starts true iff
/// [existing] is non-null (import-suggested or previously-saved binding).
class _BindingRow {
  _BindingRow({
    required this.nodeId,
    required this.inputName,
    required Object? currentValue,
    WorkflowInputBinding? existing,
  }) : id = existing?.id ?? const Uuid().v4(),
       exposed = existing != null,
       role = existing?.role ?? _inferBindingRole(inputName),
       controlType = existing?.controlType ?? _inferControlType(currentValue),
       required = existing?.required ?? false,
       valueController = TextEditingController(
         text: currentValue?.toString() ?? '',
       ),
       labelController = TextEditingController(
         text: existing?.label ?? inputName,
       ),
       minController = TextEditingController(
         text: existing?.minimum?.toString() ?? '',
       ),
       maxController = TextEditingController(
         text: existing?.maximum?.toString() ?? '',
       ),
       choicesController = TextEditingController(
         text: (existing?.choices ?? const []).join(', '),
       );

  final String id;
  final String nodeId;
  final String inputName;
  bool exposed;
  BindingRole role;
  WorkflowControlType controlType;
  bool required;
  final TextEditingController valueController;
  final TextEditingController labelController;
  final TextEditingController minController;
  final TextEditingController maxController;
  final TextEditingController choicesController;

  bool get isNumeric =>
      controlType == WorkflowControlType.integer ||
      controlType == WorkflowControlType.decimal;

  void dispose() {
    valueController.dispose();
    labelController.dispose();
    minController.dispose();
    maxController.dispose();
    choicesController.dispose();
  }

  Object? parsedValue() {
    final text = valueController.text;
    return switch (controlType) {
      WorkflowControlType.integer => int.tryParse(text) ?? text,
      WorkflowControlType.decimal => double.tryParse(text) ?? text,
      WorkflowControlType.toggle => text.toLowerCase() == 'true',
      WorkflowControlType.text ||
      WorkflowControlType.multiline ||
      WorkflowControlType.enumeration ||
      WorkflowControlType.file => text,
    };
  }

  List<String> get parsedChoices => choicesController.text
      .split(',')
      .map((choice) => choice.trim())
      .where((choice) => choice.isNotEmpty)
      .toList(growable: false);

  /// Blocks Save on an exposed row that would otherwise persist a broken
  /// binding: an empty required value, an inverted/violated numeric range,
  /// or a dropdown control with no choices to pick from.
  String? validate() {
    if (!exposed) return null;
    if (required && valueController.text.trim().isEmpty) {
      return 'Required value is empty.';
    }
    if (isNumeric) {
      final min = num.tryParse(minController.text);
      final max = num.tryParse(maxController.text);
      if (min != null && max != null && min > max) {
        return 'Min must not be greater than max.';
      }
      final value = parsedValue();
      if (value is num) {
        if (min != null && value < min) return 'Value is below min.';
        if (max != null && value > max) return 'Value is above max.';
      }
    }
    if (controlType == WorkflowControlType.enumeration &&
        parsedChoices.isEmpty) {
      return 'A dropdown control needs at least one choice.';
    }
    return null;
  }

  WorkflowInputBinding toBinding() => WorkflowInputBinding(
    id: id,
    nodeId: nodeId,
    inputName: inputName,
    label: labelController.text.trim().isEmpty
        ? inputName
        : labelController.text.trim(),
    role: role,
    controlType: controlType,
    required: required,
    defaultValue: parsedValue(),
    minimum: num.tryParse(minController.text),
    maximum: num.tryParse(maxController.text),
    choices: parsedChoices,
  );
}

BindingRole _inferBindingRole(String inputName) {
  const roles = {
    'text': BindingRole.prompt,
    'seed': BindingRole.seed,
    'width': BindingRole.width,
    'height': BindingRole.height,
    'steps': BindingRole.steps,
    'cfg': BindingRole.cfg,
    'frames': BindingRole.frames,
    'fps': BindingRole.fps,
    'image': BindingRole.inputImage,
  };
  return roles[inputName] ?? BindingRole.custom;
}

WorkflowControlType _inferControlType(Object? value) {
  if (value is int) return WorkflowControlType.integer;
  if (value is double) return WorkflowControlType.decimal;
  if (value is bool) return WorkflowControlType.toggle;
  return WorkflowControlType.text;
}
