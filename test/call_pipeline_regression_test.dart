import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/async_generation_gate.dart';
import 'package:hermes_android/core/services/call_route_policy.dart';
import 'package:hermes_android/core/services/speech_recognition_coordinator.dart';
import 'package:hermes_android/core/services/speech_retry_backoff.dart';
import 'package:hermes_android/core/services/tts_url.dart';

void main() {
  test('latest speech owner receives status', () {
    final router = SpeechEventRouter();
    final events = <String>[];
    router.claim(Object(), onStatus: (value) => events.add('old:$value'));
    router.claim(Object(), onStatus: (value) => events.add('new:$value'));
    router.dispatchStatus('done');
    expect(events, ['new:done']);
  });

  test('releasing stale speech owner preserves current owner', () {
    final router = SpeechEventRouter();
    final oldOwner = Object();
    final currentOwner = Object();
    final events = <String>[];
    router.claim(oldOwner, onStatus: (_) => events.add('old'));
    router.claim(currentOwner, onStatus: (_) => events.add('current'));
    router.release(oldOwner);
    router.dispatchStatus('done');
    expect(events, ['current']);
  });

  test('generation gate invalidates work after cancellation', () {
    final gate = AsyncGenerationGate();
    final generation = gate.begin();
    gate.cancel();
    expect(gate.isCurrent(generation), isFalse);
  });

  test('wildcard TTS URL falls back to gateway host', () {
    expect(resolveTtsBaseUrl(configured: 'http://0.0.0.0:8020', fallbackHost: '100.64.0.9', defaultPort: 8020), 'http://100.64.0.9:8020');
    expect(resolveTtsBaseUrl(configured: 'https://voice.example.test', fallbackHost: '100.64.0.9', defaultPort: 8020), 'https://voice.example.test');
  });

  test('speech client failures back off instead of tight-looping', () {
    final backoff = SpeechRetryBackoff();

    expect(backoff.recordFailure(), const Duration(milliseconds: 500));
    expect(backoff.recordFailure(), const Duration(seconds: 1));
    expect(backoff.recordFailure(), const Duration(seconds: 2));
    backoff.reset();
    expect(backoff.recordFailure(), const Duration(milliseconds: 500));
  });

  test('normal silence does not trigger client-failure backoff', () {
    expect(speechErrorNeedsBackoff('error_speech_timeout'), isFalse);
    expect(speechErrorNeedsBackoff('error_no_match'), isFalse);
    expect(speechErrorNeedsBackoff('error_client'), isTrue);
  });

  test('handset listening releases native communication routing', () {
    expect(
      callRouteForPhase(
        phase: CallAudioPhase.listening,
        bluetoothActive: false,
        speakerOn: false,
      ),
      CallNativeRoute.released,
    );
    expect(
      callRouteForPhase(
        phase: CallAudioPhase.speaking,
        bluetoothActive: false,
        speakerOn: false,
      ),
      CallNativeRoute.handset,
    );
  });

  test('Bluetooth and speaker routes stay active while listening', () {
    expect(
      callRouteForPhase(
        phase: CallAudioPhase.listening,
        bluetoothActive: true,
        speakerOn: false,
      ),
      CallNativeRoute.bluetooth,
    );
    expect(
      callRouteForPhase(
        phase: CallAudioPhase.listening,
        bluetoothActive: false,
        speakerOn: true,
      ),
      CallNativeRoute.speaker,
    );
  });

  test('terminal status waits for final result or error before rearming', () {
    expect(shouldRearmAfterSpeechStatus('done'), isFalse);
    expect(shouldRearmAfterSpeechStatus('notListening'), isFalse);
  });

  test('call delegates audio focus to recognizer and player', () {
    expect(
      callAudioFocusStrategy(),
      CallAudioFocusStrategy.platformComponents,
    );
  });
}
