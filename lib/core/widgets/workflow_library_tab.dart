import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/comfy_workflow.dart';
import '../models/generation_job.dart';
import '../services/comfy_workflow_codec.dart';
import '../services/comfy_ui_graph_converter.dart';
import '../services/generation_repository.dart';
import '../services/workflow_document_port.dart';
import 'workflow_binding_editor.dart';

/// The Workflows tab, hosted inside Create (Task 10 wires this in). Owns
/// import/paste, per-workflow binding editing, local/server validation,
/// duplicate, export, delete, and a trust-per-content-hash confirmation
/// before the first run of each imported or materially changed graph.
class WorkflowLibraryTab extends StatefulWidget {
  const WorkflowLibraryTab({
    super.key,
    required this.repository,
    this.documents = const FilePickerWorkflowDocumentPort(),
    this.clock = DateTime.now,
  });

  final GenerationRepository repository;
  final WorkflowDocumentPort documents;
  final DateTime Function() clock;

  @override
  State<WorkflowLibraryTab> createState() => _WorkflowLibraryTabState();
}

class _WorkflowLibraryTabState extends State<WorkflowLibraryTab> {
  static const _trustedHashesKey = 'comfyui_trusted_workflow_hashes';

  List<ComfyWorkflowDefinition> _workflows = const [];
  late final StreamSubscription<List<ComfyWorkflowDefinition>> _subscription;
  String? _banner;

  @override
  void initState() {
    super.initState();
    _subscription = widget.repository.watchWorkflows().listen((workflows) {
      if (!mounted) return;
      setState(() => _workflows = workflows);
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  void _showBanner(String message) {
    if (!mounted) return;
    setState(() => _banner = message);
  }

  Future<Set<String>> _loadTrustedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_trustedHashesKey) ?? const []).toSet();
  }

  Future<void> _trustHash(String hash) async {
    final prefs = await SharedPreferences.getInstance();
    final trusted = await _loadTrustedHashes();
    trusted.add(hash);
    await prefs.setStringList(_trustedHashesKey, trusted.toList());
  }

  Future<void> _import() async {
    final ImportedWorkflowDocument? doc;
    try {
      doc = await widget.documents.pickJson();
    } catch (error) {
      _showBanner('Import failed: $error');
      return;
    }
    if (doc == null) return;
    await _startDraft(doc.bytes, sourceFileName: doc.fileName);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _showBanner('Clipboard is empty.');
      return;
    }
    await _startDraft(
      Uint8List.fromList(utf8.encode(text)),
      sourceFileName: 'pasted-workflow.json',
    );
  }

  Future<void> _startDraft(
    Uint8List bytes, {
    required String sourceFileName,
  }) async {
    final ImportedWorkflow imported;
    try {
      imported = ComfyWorkflowCodec.decode(
        bytes,
        sourceFileName: sourceFileName,
      );
    } on FormatException catch (error) {
      _showBanner('Invalid workflow JSON: ${error.message}');
      return;
    }
    final normalized = await widget.repository.normalizeImportedGraph(
      imported.graph,
    );
    if (!mounted) return;
    final JsonObject flatGraph;
    switch (normalized) {
      case ConversionFailed(:final issues):
        _showBanner(issues.map((issue) => issue.message).join('; '));
        return;
      case ConvertedPrompt(:final prompt):
        flatGraph = prompt;
    }

    final suggested = ComfyWorkflowCodec.suggestBindings(flatGraph);
    if (!mounted) return;
    final result = await Navigator.of(context).push<WorkflowBindingEditorResult>(
      MaterialPageRoute<WorkflowBindingEditorResult>(
        builder: (_) => WorkflowBindingEditorScreen(
          graph: flatGraph,
          initialBindings: suggested,
          title: 'Review workflow inputs',
          showNameAndKind: true,
          initialName: sourceFileName,
          initialKind: ComfyMediaKind.image,
        ),
      ),
    );
    if (result == null) return;
    final now = widget.clock().toUtc();
    final definition = ComfyWorkflowDefinition(
      id: const Uuid().v4(),
      name: result.name ?? sourceFileName,
      kind: result.kind ?? ComfyMediaKind.image,
      workingGraph: result.graph,
      sourceHash: imported.sourceHash,
      sourceFileName: sourceFileName,
      bindings: result.bindings,
      createdAt: now,
      updatedAt: now,
    );
    try {
      await widget.repository.saveWorkflow(
        definition,
        sourceBytes: imported.sourceBytes,
      );
      _showBanner('Saved "${definition.name}".');
    } catch (error) {
      _showBanner('Save failed: $error');
    }
  }

  Future<void> _editBindings(ComfyWorkflowDefinition workflow) async {
    final result = await Navigator.of(context).push<WorkflowBindingEditorResult>(
      MaterialPageRoute<WorkflowBindingEditorResult>(
        builder: (_) => WorkflowBindingEditorScreen(
          graph: workflow.workingGraph,
          initialBindings: workflow.bindings,
          title: '${workflow.name} — bindings',
        ),
      ),
    );
    if (result == null) return;
    final updated = workflow.copyWith(
      workingGraph: result.graph,
      bindings: result.bindings,
      updatedAt: widget.clock().toUtc(),
    );
    try {
      final source = await widget.repository.exportWorkflow(
        workflow.id,
        WorkflowExportKind.originalSource,
      );
      await widget.repository.saveWorkflow(updated, sourceBytes: source);
      _showBanner('Bindings updated.');
    } catch (error) {
      _showBanner('Save failed: $error');
    }
  }

  Future<void> _editRawGraph(ComfyWorkflowDefinition workflow) async {
    final result = await showDialog<_RawGraphEditResult>(
      context: context,
      builder: (_) => _RawGraphEditDialog(workflow: workflow),
    );
    if (result == null) return;
    final draft = ComfyWorkflowCodec.applyDraft(
      savedGraph: workflow.workingGraph,
      draftBytes: utf8.encode(result.text),
    );
    if (!draft.accepted) {
      _showBanner('Invalid JSON, not saved: ${draft.error}');
      return;
    }
    final updated = workflow.copyWith(
      workingGraph: draft.graph,
      updatedAt: widget.clock().toUtc(),
    );
    final source = await widget.repository.exportWorkflow(
      workflow.id,
      WorkflowExportKind.originalSource,
    );
    await widget.repository.saveWorkflow(updated, sourceBytes: source);
    _showBanner('Working graph updated.');
  }

  Future<void> _validateLocal(ComfyWorkflowDefinition workflow) async {
    final result = await widget.repository.validateWorkflow(
      workflow.id,
      againstServer: false,
    );
    _showBanner(
      result.isValid
          ? 'Local validation passed.'
          : 'Local validation found ${result.issues.length} issue(s).',
    );
  }

  Future<void> _validateServer(ComfyWorkflowDefinition workflow) async {
    try {
      final result = await widget.repository.validateWorkflow(
        workflow.id,
        againstServer: true,
      );
      _showBanner(
        result.isValid
            ? 'Server validation passed.'
            : 'Server validation found ${result.issues.length} issue(s).',
      );
    } catch (error) {
      _showBanner('Server validation failed: $error');
    }
  }

  Future<void> _duplicate(ComfyWorkflowDefinition workflow) async {
    final name = await _promptText(
      title: 'Duplicate workflow',
      initial: '${workflow.name} copy',
    );
    if (name == null || name.trim().isEmpty) return;
    await widget.repository.duplicateWorkflow(workflow.id, name: name.trim());
    _showBanner('Duplicated as "$name".');
  }

  Future<void> _export(
    ComfyWorkflowDefinition workflow,
    WorkflowExportKind kind,
  ) async {
    final bytes = await widget.repository.exportWorkflow(workflow.id, kind);
    final suffix = switch (kind) {
      WorkflowExportKind.originalSource => 'source',
      WorkflowExportKind.workingGraph => 'graph',
      WorkflowExportKind.hermesSidecar => 'hermes',
    };
    await widget.documents.saveJson(
      fileName: '${workflow.name}.$suffix.json',
      bytes: bytes,
    );
  }

  Future<void> _delete(ComfyWorkflowDefinition workflow) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete workflow?'),
        content: Text(
          'Delete "${workflow.name}"? This cannot be undone. Jobs and '
          'media that already used it are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.repository.deleteWorkflow(workflow.id);
    _showBanner('Deleted "${workflow.name}".');
  }

  Future<void> _testRun(ComfyWorkflowDefinition workflow) async {
    final trusted = await _loadTrustedHashes();
    if (!trusted.contains(workflow.sourceHash)) {
      if (!mounted) return;
      final confirmedTrust = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Trust this workflow?'),
          content: Text(
            'This imported workflow is an executable server program. '
            'Running it sends it to your configured ComfyUI endpoint.\n\n'
            'Content hash: ${workflow.sourceHash}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Trust and run'),
            ),
          ],
        ),
      );
      if (confirmedTrust != true) return;
      await _trustHash(workflow.sourceHash);
    }
    try {
      await widget.repository.submit(
        GenerationRequest(
          workflowId: workflow.id,
          kind: workflow.kind,
          submittedValues: {
            for (final binding in workflow.bindings)
              if (binding.defaultValue != null)
                binding.id: binding.defaultValue,
          },
        ),
      );
      _showBanner('Test run submitted.');
    } catch (error) {
      _showBanner('Test run failed: $error');
    }
  }

  Future<String?> _promptText({
    required String title,
    required String initial,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.file_open),
                label: const Text('Import workflow'),
              ),
              OutlinedButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.paste),
                label: const Text('Paste workflow JSON'),
              ),
            ],
          ),
        ),
        if (_banner != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_banner!),
          ),
        Expanded(
          child: _workflows.isEmpty
              ? const Center(child: Text('No saved workflows yet.'))
              : ListView.builder(
                  itemCount: _workflows.length,
                  itemBuilder: (context, index) => _WorkflowCard(
                    workflow: _workflows[index],
                    onEditBindings: () => _editBindings(_workflows[index]),
                    onEditRawGraph: () => _editRawGraph(_workflows[index]),
                    onValidateLocal: () => _validateLocal(_workflows[index]),
                    onValidateServer: () => _validateServer(_workflows[index]),
                    onDuplicate: () => _duplicate(_workflows[index]),
                    onExport: (kind) => _export(_workflows[index], kind),
                    onDelete: () => _delete(_workflows[index]),
                    onTestRun: () => _testRun(_workflows[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _WorkflowCard extends StatelessWidget {
  const _WorkflowCard({
    required this.workflow,
    required this.onEditBindings,
    required this.onEditRawGraph,
    required this.onValidateLocal,
    required this.onValidateServer,
    required this.onDuplicate,
    required this.onExport,
    required this.onDelete,
    required this.onTestRun,
  });

  final ComfyWorkflowDefinition workflow;
  final VoidCallback onEditBindings;
  final VoidCallback onEditRawGraph;
  final VoidCallback onValidateLocal;
  final VoidCallback onValidateServer;
  final VoidCallback onDuplicate;
  final void Function(WorkflowExportKind kind) onExport;
  final VoidCallback onDelete;
  final VoidCallback onTestRun;

  @override
  Widget build(BuildContext context) {
    final validation = workflow.validation;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    workflow.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(label: Text(workflow.kind.name)),
              ],
            ),
            if (validation != null)
              Text(
                validation.isValid
                    ? 'Server-validated'
                    : '${validation.issues.length} validation issue(s)',
                style: TextStyle(
                  color: validation.isValid
                      ? Colors.green
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: onEditBindings,
                  child: const Text('Edit bindings'),
                ),
                TextButton(
                  onPressed: onEditRawGraph,
                  child: const Text('Advanced: edit raw JSON'),
                ),
                TextButton(
                  onPressed: onValidateLocal,
                  child: const Text('Validate locally'),
                ),
                TextButton(
                  onPressed: onValidateServer,
                  child: const Text('Validate against server'),
                ),
                TextButton(
                  onPressed: onDuplicate,
                  child: const Text('Duplicate'),
                ),
                PopupMenuButton<WorkflowExportKind>(
                  onSelected: onExport,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: WorkflowExportKind.originalSource,
                      child: Text('Export original source'),
                    ),
                    PopupMenuItem(
                      value: WorkflowExportKind.workingGraph,
                      child: Text('Export working graph'),
                    ),
                    PopupMenuItem(
                      value: WorkflowExportKind.hermesSidecar,
                      child: Text('Export Hermes sidecar'),
                    ),
                  ],
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text('Export'), Icon(Icons.arrow_drop_down)],
                  ),
                ),
                TextButton(onPressed: onTestRun, child: const Text('Test run')),
                TextButton(onPressed: onDelete, child: const Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _RawGraphEditResult {
  const _RawGraphEditResult(this.text);

  final String text;
}

class _RawGraphEditDialog extends StatefulWidget {
  const _RawGraphEditDialog({required this.workflow});

  final ComfyWorkflowDefinition workflow;

  @override
  State<_RawGraphEditDialog> createState() => _RawGraphEditDialogState();
}

class _RawGraphEditDialogState extends State<_RawGraphEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: const JsonEncoder.withIndent(
      '  ',
    ).convert(widget.workflow.workingGraph),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit working graph JSON'),
      content: SizedBox(
        width: 560,
        height: 400,
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_RawGraphEditResult(_controller.text)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

