import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/services/media_cache_service.dart';
import 'package:hermes_android/core/services/media_export_service.dart';
import 'package:hermes_android/core/widgets/generated_media_view.dart';

void main() {
  group('DefaultGeneratedVideoCoordinator', () {
    test('starting a second video pauses the first', () {
      final coordinator = DefaultGeneratedVideoCoordinator();
      final pausedIds = <String>[];

      coordinator.notifyPlaying('video-1', () => pausedIds.add('video-1'));
      expect(pausedIds, isEmpty);

      coordinator.notifyPlaying('video-2', () => pausedIds.add('video-2'));
      expect(pausedIds, ['video-1']);
    });

    test('notifying the same id again does not pause itself', () {
      final coordinator = DefaultGeneratedVideoCoordinator();
      final pausedIds = <String>[];

      coordinator.notifyPlaying('video-1', () => pausedIds.add('video-1'));
      coordinator.notifyPlaying('video-1', () => pausedIds.add('video-1'));

      expect(pausedIds, isEmpty);
    });

    test('a stopped video no longer pauses a later one that starts', () {
      final coordinator = DefaultGeneratedVideoCoordinator();
      final pausedIds = <String>[];

      coordinator.notifyPlaying('video-1', () => pausedIds.add('video-1'));
      coordinator.notifyStopped('video-1');
      coordinator.notifyPlaying('video-2', () => pausedIds.add('video-2'));

      expect(pausedIds, isEmpty);
    });
  });

  group('GeneratedMediaView', () {
    Widget harness(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('renders an image asset via the injected media cache', (
      tester,
    ) async {
      final cache = _RecordingMediaCache();
      await tester.pumpWidget(
        harness(
          GeneratedMediaView(
            id: 'asset-1',
            kind: ComfyMediaKind.image,
            uri: Uri.parse('http://host:8188/view?filename=r.png'),
            mediaCache: cache,
            mediaExport: MediaExportService.appDefault,
          ),
        ),
      );
      await tester.pump();

      expect(cache.uris, [Uri.parse('http://host:8188/view?filename=r.png')]);
    });

    testWidgets(
      'a video asset degrades to an unavailable placeholder instead of crashing '
      'when the native video backend is unavailable',
      (tester) async {
        await tester.pumpWidget(
          harness(
            GeneratedMediaView(
              id: 'asset-2',
              kind: ComfyMediaKind.video,
              uri: Uri.parse('http://host:8188/view?filename=r.mp4'),
              mediaCache: _RecordingMediaCache(),
              mediaExport: MediaExportService.appDefault,
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );
  });
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
