// The global media library: every generated asset the repository knows
// about, independent of any one chat session. Covers filtering, the
// delete-with-confirmation flow, jumping back to a source message, and
// degrading gracefully when an asset's endpoint no longer parses.
//
// CachedMediaThumbnail's disk-cache lookup fails in a test (no
// path_provider), which is fine -- it renders its broken-image state and the
// tile is still there to press. That coverage is unrelated to
// MediaGalleryScreen and is kept standalone below.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/character_generation_context.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/models/generation_job.dart';
import 'package:hermes_android/core/models/media_asset.dart';
import 'package:hermes_android/core/screens/media_gallery_screen.dart';
import 'package:hermes_android/core/services/generation_repository.dart';
import 'package:hermes_android/core/services/media_cache_service.dart';
import 'package:hermes_android/core/widgets/cached_media_thumbnail.dart';

const _base = 'http://comfy:8188';

MediaAsset _asset({
  required String id,
  ComfyMediaKind kind = ComfyMediaKind.image,
  String endpointSnapshot = _base,
  String? filename,
  String? sourceSessionId,
  String? sourceMessageId,
}) {
  final now = DateTime.utc(2026, 8, 20);
  return MediaAsset(
    id: id,
    kind: kind,
    endpointSnapshot: endpointSnapshot,
    filename: filename ?? '$id.png',
    createdAt: now,
    updatedAt: now,
    sourceSessionId: sourceSessionId,
    sourceMessageId: sourceMessageId,
  );
}

class _FakeGenerationRepository implements GenerationRepository {
  final _mediaController = StreamController<List<MediaAsset>>.broadcast();
  List<MediaAsset> _latestMedia = const [];
  // Records, not MapEntry -- MapEntry has no value equality, so a
  // list-equality assertion against it always compares by identity.
  final List<(String, bool)> removed = [];

  void emitMedia(List<MediaAsset> media) {
    _latestMedia = media;
    _mediaController.add(media);
  }

  // Replays the latest value to a new subscriber -- tests call emitMedia()
  // before pumpWidget() (the widget only subscribes in initState, once
  // pumped), and a plain broadcast stream drops events with no listener yet.
  @override
  Stream<List<MediaAsset>> watchMedia() async* {
    yield _latestMedia;
    yield* _mediaController.stream;
  }

  @override
  Future<void> removeMedia(String assetId, {required bool clearCache}) async {
    removed.add((assetId, clearCache));
  }

  @override
  Future<void> initialize() async {}

  @override
  Stream<List<ComfyWorkflowDefinition>> watchWorkflows() =>
      const Stream.empty();

  @override
  Stream<List<GenerationJob>> watchJobs() => const Stream.empty();

  @override
  Stream<CharacterGenerationContext?> watchCharacterContext(String sessionId) =>
      const Stream.empty();

  @override
  Future<GenerationJob> submit(GenerationRequest request) =>
      throw UnimplementedError();

  @override
  Future<void> cancel(
    String localJobId, {
    bool confirmSharedInterrupt = false,
  }) => throw UnimplementedError();

  @override
  Future<GenerationJob> retryAsNew(String localJobId) =>
      throw UnimplementedError();

  @override
  Future<void> reconcilePending() async {}

  @override
  Future<ComfyWorkflowDefinition?> getWorkflow(String workflowId) async => null;

  @override
  Future<void> saveWorkflow(
    ComfyWorkflowDefinition workflow, {
    required Uint8List sourceBytes,
  }) => throw UnimplementedError();

  @override
  Future<ComfyWorkflowDefinition> duplicateWorkflow(
    String workflowId, {
    required String name,
  }) => throw UnimplementedError();

  @override
  Future<WorkflowValidationResult> validateWorkflow(
    String workflowId, {
    required bool againstServer,
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> exportWorkflow(
    String workflowId,
    WorkflowExportKind kind,
  ) => throw UnimplementedError();

  @override
  Future<void> deleteWorkflow(String workflowId) => throw UnimplementedError();

  @override
  Future<CharacterGenerationContext?> getCharacterContext(
    String sessionId,
  ) async => null;

  @override
  Future<void> saveCharacterContext(
    CharacterGenerationContext context, {
    File? referenceImage,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteCharacterContext(String sessionId) async {}

  @override
  Future<void> upsertChatToolOutputs({
    required ComfyEndpoint endpoint,
    required String sessionId,
    required List<JsonObject> messages,
  }) async {}

  @override
  Future<void> dispose() async {
    await _mediaController.close();
  }
}

class _RecordingMediaCache implements MediaCachePort {
  final List<Uri> uris = [];

  @override
  Future<File?> cache(Uri uri, {Map<String, String> headers = const {}}) async {
    uris.add(uri);
    return null;
  }

  @override
  Future<void> remove(Uri uri) async {}
}

Future<void> _settle(WidgetTester tester) async {
  // Bounded pumps rather than pumpAndSettle: image tiles sit on a
  // CircularProgressIndicator (the injected cache never resolves to a file
  // in these tests), and an indeterminate spinner never settles.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('ignores a cache completion after the thumbnail is disposed', (
    tester,
  ) async {
    final completer = Completer<File?>();
    final cache = _CompleterMediaCache(completer);

    await tester.pumpWidget(
      CachedMediaThumbnail(
        url: 'http://comfy:8188/view?filename=still.png&type=output',
        headers: const {'Authorization': 'Bearer test'},
        mediaCache: cache,
      ),
    );

    expect(cache.uris, [
      Uri.parse('http://comfy:8188/view?filename=still.png&type=output'),
    ]);
    expect(cache.headers, [
      {'Authorization': 'Bearer test'},
    ]);

    await tester.pumpWidget(const SizedBox());
    completer.complete(null);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('filter chips narrow the list to images or videos', (
    tester,
  ) async {
    final repository = _FakeGenerationRepository();
    addTearDown(repository.dispose);
    repository.emitMedia([
      _asset(id: 'img-1', kind: ComfyMediaKind.image),
      _asset(id: 'vid-1', kind: ComfyMediaKind.video, filename: 'vid-1.mp4'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaGalleryScreen(
          repository: repository,
          mediaCache: _RecordingMediaCache(),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('Media (2)'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Videos'));
    await _settle(tester);
    expect(find.text('Media (1)'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Images'));
    await _settle(tester);
    expect(find.text('Media (1)'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await _settle(tester);
    expect(find.text('Media (2)'), findsOneWidget);
  });

  testWidgets('an empty library says so', (tester) async {
    final repository = _FakeGenerationRepository();
    addTearDown(repository.dispose);
    repository.emitMedia(const []);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaGalleryScreen(
          repository: repository,
          mediaCache: _RecordingMediaCache(),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('Media (0)'), findsOneWidget);
    expect(find.text('No media yet'), findsOneWidget);
  });

  testWidgets('an asset whose endpoint no longer parses shows a fallback '
      'instead of crashing', (tester) async {
    final repository = _FakeGenerationRepository();
    addTearDown(repository.dispose);
    repository.emitMedia([
      _asset(id: 'stale-1', endpointSnapshot: 'ftp://not-http.example'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaGalleryScreen(
          repository: repository,
          mediaCache: _RecordingMediaCache(),
        ),
      ),
    );
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('This endpoint is unavailable.'), findsOneWidget);
  });

  testWidgets(
    'the source-message button hands the asset back and pops the screen',
    (tester) async {
      final repository = _FakeGenerationRepository();
      addTearDown(repository.dispose);
      final asset = _asset(
        id: 'img-1',
        sourceSessionId: 'session-1',
        sourceMessageId: 'msg-1',
      );
      repository.emitMedia([asset]);

      MediaAsset? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MediaGalleryScreen(
                    repository: repository,
                    mediaCache: _RecordingMediaCache(),
                    onOpenSourceMessage: (a) async {
                      opened = a;
                    },
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);

      await tester.tap(find.byTooltip('Open source message'));
      await tester.pumpAndSettle();

      expect(opened, isNotNull);
      expect(opened!.id, 'img-1');
      // The gallery pops itself before invoking the callback.
      expect(find.byType(MediaGalleryScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    },
  );

  testWidgets('no source-message button is offered without a callback', (
    tester,
  ) async {
    final repository = _FakeGenerationRepository();
    addTearDown(repository.dispose);
    repository.emitMedia([_asset(id: 'img-1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaGalleryScreen(
          repository: repository,
          mediaCache: _RecordingMediaCache(),
        ),
      ),
    );
    await _settle(tester);

    expect(find.byTooltip('Open source message'), findsNothing);
  });

  testWidgets(
    'source jump requires both a session id and a message id, not just a '
    'callback',
    (tester) async {
      final repository = _FakeGenerationRepository();
      addTearDown(repository.dispose);
      repository.emitMedia([
        _asset(
          id: 'has-both',
          sourceSessionId: 'session-1',
          sourceMessageId: 'msg-1',
        ),
        _asset(id: 'has-neither'),
        _asset(id: 'session-only', sourceSessionId: 'session-1'),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaGalleryScreen(
            repository: repository,
            mediaCache: _RecordingMediaCache(),
            onOpenSourceMessage: (_) async {},
          ),
        ),
      );
      await _settle(tester);

      expect(find.byTooltip('Open source message'), findsOneWidget);
    },
  );

  testWidgets(
    'deleting and choosing "Keep cache" removes the asset without clearing '
    'the cache',
    (tester) async {
      final repository = _FakeGenerationRepository();
      addTearDown(repository.dispose);
      repository.emitMedia([_asset(id: 'img-1')]);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaGalleryScreen(
            repository: repository,
            mediaCache: _RecordingMediaCache(),
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byTooltip('Remove'));
      await tester.pump();

      expect(find.text('Remove from Hermes?'), findsOneWidget);
      await tester.tap(find.text('Keep cache'));
      await tester.pump();

      expect(repository.removed, [('img-1', false)]);
    },
  );

  testWidgets(
    'deleting and choosing "Remove and clear cache" clears the cache too',
    (tester) async {
      final repository = _FakeGenerationRepository();
      addTearDown(repository.dispose);
      repository.emitMedia([_asset(id: 'img-1')]);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaGalleryScreen(
            repository: repository,
            mediaCache: _RecordingMediaCache(),
          ),
        ),
      );
      await _settle(tester);

      await tester.tap(find.byTooltip('Remove'));
      await tester.pump();
      await tester.tap(find.text('Remove and clear cache'));
      await tester.pump();

      expect(repository.removed, [('img-1', true)]);
    },
  );

  testWidgets('cancelling the delete dialog removes nothing', (tester) async {
    final repository = _FakeGenerationRepository();
    addTearDown(repository.dispose);
    repository.emitMedia([_asset(id: 'img-1')]);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaGalleryScreen(
          repository: repository,
          mediaCache: _RecordingMediaCache(),
        ),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(repository.removed, isEmpty);
  });
}

class _CompleterMediaCache implements MediaCachePort {
  _CompleterMediaCache(this.completer);

  final Completer<File?> completer;
  final List<Uri> uris = [];
  final List<Map<String, String>> headers = [];

  @override
  Future<File?> cache(Uri uri, {Map<String, String> headers = const {}}) {
    uris.add(uri);
    this.headers.add(Map<String, String>.of(headers));
    return completer.future;
  }

  @override
  Future<void> remove(Uri uri) async {}
}
