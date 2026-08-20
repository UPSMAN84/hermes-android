import 'dart:async';

import 'package:flutter/material.dart';

import '../models/character_generation_context.dart';
import '../models/comfy_workflow.dart';
import '../models/connection.dart';
import '../models/generation_job.dart';
import '../services/generation_repository.dart';
import '../services/generation_repository_host.dart';
import '../services/media_export_service.dart';
import '../widgets/generation_form.dart';
import '../widgets/generation_job_card.dart';
import '../widgets/workflow_library_tab.dart';

/// Image/Video/Workflows creation shell. The repository is always the one
/// app-scoped instance ([GenerationRepositoryHost]) unless a test injects
/// its own -- this screen never constructs or disposes one itself.
final class CreateScreen extends StatefulWidget {
  const CreateScreen({
    super.key,
    required this.connection,
    this.initialTab = 0,
    this.repository,
    this.initialContext,
  });

  final SavedConnection connection;
  final int initialTab;
  final GenerationRepository? repository;
  final CharacterGenerationContext? initialContext;

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  GenerationRepository? _repository;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    _resolveRepository();
  }

  Future<void> _resolveRepository() async {
    final injected = widget.repository;
    if (injected != null) {
      setState(() => _repository = injected);
      return;
    }
    final host = await GenerationRepositoryHost.instance();
    if (!mounted) return;
    setState(() => _repository = host.repository);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Image'),
            Tab(text: 'Video'),
            Tab(text: 'Workflows'),
          ],
        ),
      ),
      body: repository == null
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _MediaKindTab(
                  kind: ComfyMediaKind.image,
                  repository: repository,
                  characterContext: widget.initialContext,
                  onJumpToWorkflows: () => _tabController.animateTo(2),
                ),
                _MediaKindTab(
                  kind: ComfyMediaKind.video,
                  repository: repository,
                  characterContext: widget.initialContext,
                  onJumpToWorkflows: () => _tabController.animateTo(2),
                ),
                WorkflowLibraryTab(repository: repository),
              ],
            ),
    );
  }
}

class _MediaKindTab extends StatefulWidget {
  const _MediaKindTab({
    required this.kind,
    required this.repository,
    required this.characterContext,
    required this.onJumpToWorkflows,
  });

  final ComfyMediaKind kind;
  final GenerationRepository repository;
  final CharacterGenerationContext? characterContext;
  final VoidCallback onJumpToWorkflows;

  @override
  State<_MediaKindTab> createState() => _MediaKindTabState();
}

class _MediaKindTabState extends State<_MediaKindTab> {
  late final StreamSubscription<List<ComfyWorkflowDefinition>>
  _workflowsSubscription;
  late final StreamSubscription<List<GenerationJob>> _jobsSubscription;
  List<ComfyWorkflowDefinition> _workflows = const [];
  List<GenerationJob> _jobs = const [];
  String? _selectedWorkflowId;

  @override
  void initState() {
    super.initState();
    _workflowsSubscription = widget.repository.watchWorkflows().listen((
      workflows,
    ) {
      if (!mounted) return;
      setState(() {
        _workflows = workflows
            .where((workflow) => workflow.kind == widget.kind)
            .toList(growable: false);
        if (_selectedWorkflowId == null && _workflows.isNotEmpty) {
          _selectedWorkflowId = _workflows.first.id;
        }
        if (_selectedWorkflowId != null &&
            !_workflows.any((w) => w.id == _selectedWorkflowId)) {
          _selectedWorkflowId = _workflows.isEmpty ? null : _workflows.first.id;
        }
      });
    });
    _jobsSubscription = widget.repository.watchJobs().listen((jobs) {
      if (!mounted) return;
      setState(() {
        _jobs = jobs
            .where((job) => job.kind == widget.kind)
            .toList(growable: false);
      });
    });
  }

  @override
  void dispose() {
    _workflowsSubscription.cancel();
    _jobsSubscription.cancel();
    super.dispose();
  }

  Future<void> _saveOutput(GenerationJob job, ComfyOutputRef output) async {
    try {
      final endpoint = ComfyEndpoint.parse(job.endpointSnapshot);
      final error = await MediaExportService.appDefault.saveRemote(
        endpoint.viewUri(output),
        isVideo: widget.kind == ComfyMediaKind.video,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error ?? 'Saved to Photos')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $error')));
    }
  }

  Future<void> _shareOutput(GenerationJob job, ComfyOutputRef output) async {
    try {
      final endpoint = ComfyEndpoint.parse(job.endpointSnapshot);
      await MediaExportService.appDefault.shareRemote(endpoint.viewUri(output));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Share failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_workflows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'No ${widget.kind.name} workflows yet.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: widget.onJumpToWorkflows,
                child: const Text('Go to Workflows'),
              ),
            ],
          ),
        ),
      );
    }

    final selected = _workflows.firstWhere(
      (workflow) => workflow.id == _selectedWorkflowId,
      orElse: () => _workflows.first,
    );

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_workflows.length > 1)
          DropdownButtonFormField<String>(
            initialValue: selected.id,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Workflow'),
            items: [
              for (final workflow in _workflows)
                DropdownMenuItem(
                  value: workflow.id,
                  child: Text(workflow.name),
                ),
            ],
            onChanged: (value) => setState(() => _selectedWorkflowId = value),
          ),
        GenerationForm(
          key: ValueKey(selected.id),
          repository: widget.repository,
          workflow: selected,
          characterContext: widget.characterContext,
          sourceContextId: widget.characterContext?.sessionId,
          onSubmitted: (_) {},
        ),
        const SizedBox(height: 16),
        for (final job in _jobs)
          GenerationJobCard(
            job: job,
            onCancel: ({required confirmSharedInterrupt}) =>
                widget.repository.cancel(
                  job.localId,
                  confirmSharedInterrupt: confirmSharedInterrupt,
                ),
            onRetry: () => widget.repository.retryAsNew(job.localId),
            onSave: (output) => _saveOutput(job, output),
            onShare: (output) => _shareOutput(job, output),
          ),
      ],
    );
  }
}
