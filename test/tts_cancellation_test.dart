// Regression coverage for the audit finding "Stop cannot cancel pending
// XTTS/Chatterbox synthesis": pressing Stop while speak()'s network request
// is still in flight must abort promptly (not wait out the request's full
// timeout) and must still fire onComplete exactly once, without surfacing a
// spurious "TTS failed" error for what was an intentional interruption.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/xtts_service.dart';
import 'package:hermes_android/core/services/chatterbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Both services eagerly construct a real audioplayers `AudioPlayer` even
  // though these tests never reach the play step (cancellation short-
  // circuits speak() before speakPrepared() is called) -- without a mock
  // handler, the player's own platform-channel init throws
  // MissingPluginException as an unhandled async error and fails the test
  // for a reason unrelated to what's being tested here.
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (call) async => null,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('XttsService', () {
    test(
      'stop() aborts a pending speak() instead of waiting out the request',
      () async {
        SharedPreferences.setMockInitialValues({'xtts_speaker': 'nova.wav'});
        final synthesisGate = Completer<http.Response>();
        final client = MockClient((request) async {
          // /set_tts_settings must resolve normally so the test reaches the
          // actual synthesis POST; /tts_to_audio/ hangs until the test ends,
          // simulating a slow server -- proving stop() unblocks speak()
          // without the request ever completing.
          if (request.url.path.contains('set_tts_settings')) {
            return http.Response('{}', 200);
          }
          return synthesisGate.future;
        });
        final tts = XttsService(httpClient: client);

        var completeCalls = 0;
        final speakFuture = tts.speak(
          'hello world',
          onComplete: () => completeCalls++,
        );

        // Let speak() run up through the in-flight synthesis POST.
        await Future.delayed(Duration.zero);
        await tts.stop();

        await speakFuture.timeout(const Duration(seconds: 2));
        expect(completeCalls, 1);
      },
    );
  });

  group('ChatterboxService', () {
    test(
      'stop() aborts a pending speak() instead of waiting out the request',
      () async {
        SharedPreferences.setMockInitialValues({'chatterbox_voice': 'deep_male.wav'});
        final synthesisGate = Completer<http.StreamedResponse>();
        final client = MockClient((request) async {
          final streamed = await synthesisGate.future;
          return http.Response.bytes(
            await streamed.stream.toBytes(),
            streamed.statusCode,
          );
        });
        final tts = ChatterboxService(httpClient: client);

        var completeCalls = 0;
        final speakFuture = tts.speak(
          'hello world',
          onComplete: () => completeCalls++,
        );

        await Future.delayed(Duration.zero);
        await tts.stop();

        await speakFuture.timeout(const Duration(seconds: 2));
        expect(completeCalls, 1);
      },
    );
  });
}
