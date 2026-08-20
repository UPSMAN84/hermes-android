import 'package:flutter/material.dart';

import '../models/comfy_workflow.dart';
import '../models/generation_job.dart';

/// Renders exactly the durable state carried on [job] -- it never infers
/// success from a socket closing or any other client-side signal, since the
/// repository's reducer is the only thing allowed to decide that.
class GenerationJobCard extends StatelessWidget {
  const GenerationJobCard({
    super.key,
    required this.job,
    this.onCancel,
    this.onRetry,
    this.onSave,
    this.onShare,
    this.onDiscuss,
  });

  final GenerationJob job;

  /// Called with `confirmSharedInterrupt: true` only after the running-job
  /// confirmation dialog is accepted; called with `false` directly for a
  /// queued job (queue removal doesn't touch shared execution).
  final void Function({required bool confirmSharedInterrupt})? onCancel;
  final VoidCallback? onRetry;
  final void Function(ComfyOutputRef output)? onSave;
  final void Function(ComfyOutputRef output)? onShare;
  final void Function(ComfyOutputRef output)? onDiscuss;

  bool get _canCancel => const {
    GenerationJobState.queued,
    GenerationJobState.running,
  }.contains(job.state);

  bool get _canRetry => const {
    GenerationJobState.failed,
    GenerationJobState.cancelled,
    GenerationJobState.uncertain,
  }.contains(job.state);

  Future<void> _cancel(BuildContext context) async {
    final cancel = onCancel;
    if (cancel == null) return;
    if (job.state == GenerationJobState.queued) {
      cancel(confirmSharedInterrupt: false);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop this generation?'),
        content: const Text(
          'ComfyUI is a shared server. Interrupting affects whatever is '
          'currently executing there, even if another client started it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep running'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (confirmed == true) cancel(confirmSharedInterrupt: true);
  }

  String get _stateLabel => switch (job.state) {
    GenerationJobState.draft => 'Draft',
    GenerationJobState.submitting => 'Submitting…',
    GenerationJobState.queued => 'Queued',
    GenerationJobState.running => 'Running',
    GenerationJobState.cancelling => 'Stopping…',
    GenerationJobState.reconciling => 'Reconnecting…',
    GenerationJobState.succeeded => 'Done',
    GenerationJobState.failed => 'Failed',
    GenerationJobState.cancelled => 'Stopped',
    GenerationJobState.uncertain => 'Unknown — did not resubmit',
  };

  @override
  Widget build(BuildContext context) {
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
                    _stateLabel,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_canCancel)
                  TextButton(
                    onPressed: () => _cancel(context),
                    child: const Text('Cancel'),
                  ),
                if (_canRetry)
                  TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
            if (job.state == GenerationJobState.running &&
                job.progressMax > 0) ...[
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: job.progressValue / job.progressMax,
              ),
              if (job.currentNodeId != null)
                Text(
                  'Node ${job.currentNodeId}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
            if (job.state == GenerationJobState.failed &&
                job.error != null) ...[
              const SizedBox(height: 4),
              Text(
                job.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              for (final entry in job.nodeErrors.entries)
                Text(
                  '${entry.key}: ${entry.value}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
            if (job.state == GenerationJobState.uncertain)
              Text(
                'The connection was lost before this could be confirmed. '
                'It was never resubmitted automatically.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (job.state == GenerationJobState.succeeded &&
                job.outputs.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final output in job.outputs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          output.filename,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (onSave != null)
                        IconButton(
                          icon: const Icon(Icons.save_alt),
                          tooltip: 'Save',
                          onPressed: () => onSave!(output),
                        ),
                      if (onShare != null)
                        IconButton(
                          icon: const Icon(Icons.ios_share),
                          tooltip: 'Share',
                          onPressed: () => onShare!(output),
                        ),
                      if (onDiscuss != null && job.kind == ComfyMediaKind.image)
                        IconButton(
                          icon: const Icon(Icons.chat_bubble_outline),
                          tooltip: 'Discuss in chat',
                          onPressed: () => onDiscuss!(output),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
