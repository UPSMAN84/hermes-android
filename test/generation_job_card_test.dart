import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/widgets/generation_job_card.dart';

void main() {
  Widget harness(GenerationJobCard card) =>
      MaterialApp(home: Scaffold(body: card));

  GenerationJob job({
    required GenerationJobState state,
    List<ComfyOutputRef> outputs = const [],
    String? error,
    Map<String, Object?> nodeErrors = const {},
    ComfyMediaKind kind = ComfyMediaKind.image,
    int progressValue = 3,
    int progressMax = 10,
    String? currentNodeId = '7',
  }) => GenerationJob(
    localId: 'job-1',
    workflowId: 'workflow-1',
    kind: kind,
    state: state,
    endpointFingerprint: 'fp',
    endpointSnapshot: 'http://host:8188',
    submittedValues: const {},
    progressValue: progressValue,
    progressMax: progressMax,
    currentNodeId: currentNodeId,
    outputs: outputs,
    error: error,
    nodeErrors: nodeErrors,
    createdAt: DateTime.utc(2026, 8, 20),
    updatedAt: DateTime.utc(2026, 8, 20),
  );

  testWidgets(
    'running shows progress and node, no cancel confirmation needed for queued',
    (tester) async {
      var cancelledConfirmed = <bool>[];
      await tester.pumpWidget(
        harness(
          GenerationJobCard(
            job: job(state: GenerationJobState.queued),
            onCancel: ({required confirmSharedInterrupt}) =>
                cancelledConfirmed.add(confirmSharedInterrupt),
          ),
        ),
      );

      expect(find.text('Queued'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(cancelledConfirmed, [false]);
      expect(find.text('Stop this generation?'), findsNothing);
    },
  );

  testWidgets('running cancel requires confirmation before calling back', (
    tester,
  ) async {
    var cancelledConfirmed = <bool>[];
    await tester.pumpWidget(
      harness(
        GenerationJobCard(
          job: job(state: GenerationJobState.running),
          onCancel: ({required confirmSharedInterrupt}) =>
              cancelledConfirmed.add(confirmSharedInterrupt),
        ),
      ),
    );

    expect(find.text('Running'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Node 7'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Stop this generation?'), findsOneWidget);
    expect(cancelledConfirmed, isEmpty);

    await tester.tap(find.text('Keep running'));
    await tester.pumpAndSettle();
    expect(cancelledConfirmed, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(cancelledConfirmed, [true]);
  });

  testWidgets('retry is offered for failed, cancelled, and uncertain jobs', (
    tester,
  ) async {
    for (final state in [
      GenerationJobState.failed,
      GenerationJobState.cancelled,
      GenerationJobState.uncertain,
    ]) {
      var retried = false;
      await tester.pumpWidget(
        harness(
          GenerationJobCard(
            job: job(
              state: state,
              error: state == GenerationJobState.failed ? 'boom' : null,
            ),
            onRetry: () => retried = true,
          ),
        ),
      );
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(retried, isTrue, reason: state.name);
      expect(find.text('Cancel'), findsNothing);
    }
  });

  testWidgets('running and queued jobs do not offer retry', (tester) async {
    for (final state in [
      GenerationJobState.queued,
      GenerationJobState.running,
    ]) {
      await tester.pumpWidget(
        harness(GenerationJobCard(job: job(state: state))),
      );
      expect(find.text('Retry'), findsNothing);
    }
  });

  testWidgets('a failed job shows the error and node errors', (tester) async {
    await tester.pumpWidget(
      harness(
        GenerationJobCard(
          job: job(
            state: GenerationJobState.failed,
            error: 'graph invalid',
            nodeErrors: const {'12': 'out of memory'},
          ),
        ),
      ),
    );

    expect(find.text('graph invalid'), findsOneWidget);
    expect(find.text('12: out of memory'), findsOneWidget);
  });

  testWidgets('an uncertain job never claims success', (tester) async {
    await tester.pumpWidget(
      harness(GenerationJobCard(job: job(state: GenerationJobState.uncertain))),
    );

    expect(find.text('Unknown — did not resubmit'), findsOneWidget);
    expect(find.textContaining('Done'), findsNothing);
    expect(find.byIcon(Icons.save_alt), findsNothing);
  });

  testWidgets(
    'a succeeded image job offers save, share, and discuss for each output',
    (tester) async {
      final output = ComfyOutputRef(filename: 'r.png');
      ComfyOutputRef? savedOutput;
      ComfyOutputRef? sharedOutput;
      ComfyOutputRef? discussedOutput;
      await tester.pumpWidget(
        harness(
          GenerationJobCard(
            job: job(state: GenerationJobState.succeeded, outputs: [output]),
            onSave: (o) => savedOutput = o,
            onShare: (o) => sharedOutput = o,
            onDiscuss: (o) => discussedOutput = o,
          ),
        ),
      );

      expect(find.text('r.png'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.save_alt));
      await tester.tap(find.byIcon(Icons.ios_share));
      await tester.tap(find.byIcon(Icons.chat_bubble_outline));
      await tester.pump();

      expect(savedOutput, output);
      expect(sharedOutput, output);
      expect(discussedOutput, output);
    },
  );

  testWidgets('discuss is never offered for a video job', (tester) async {
    final output = ComfyOutputRef(filename: 'clip.mp4');
    await tester.pumpWidget(
      harness(
        GenerationJobCard(
          job: job(
            state: GenerationJobState.succeeded,
            outputs: [output],
            kind: ComfyMediaKind.video,
          ),
          onDiscuss: (_) {},
        ),
      ),
    );

    expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
  });
}
