// Phone-call-mode controller: a hands-free, turn-taking voice loop bound to a
// chat session. listen (speech_to_text) -> send (Gateway SSE stream) -> speak
// (XTTS) -> listen again, until hang-up. State machine exposed as [CallState]
// for the call screen to render.
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'call_audio.dart';
import 'connection_manager.dart';
import 'tts_provider.dart';
import 'xtts_service.dart';

/// Entry point for the foreground-service task isolate. The call's actual loop
/// runs in the main isolate; this handler just lets the service exist
/// (notification + foreground status + wake lock) so background mic access and
/// playback keep working. It does no repetitive work.
@pragma('vm:entry-point')
void callTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(_CallTaskHandler());
}

class _CallTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Coarse phase of the call loop, for the UI.
enum CallState { connecting, listening, thinking, speaking, error }

/// Drives a single hands-free voice call over an existing chat session.
///
/// One instance per [CallScreen]. Call [start] on enter, [hangUp] on exit.
/// All configuration (speaker, language) is read from SharedPreferences as the
/// call runs, matching how the chat screen + XTTS service behave.
class CallController extends ChangeNotifier {
  final SavedConnection connection;
  final Session session;

  CallController({required this.connection, required this.session});

  final SpeechToText _speech = SpeechToText();
  TtsProvider _xtts = XttsService();
  late final ApiClient _api;
  late final GatewayChatClient _gateway;

  CallState _state = CallState.connecting;
  CallState get state => _state;

  bool _muted = false;
  bool get muted => _muted;

  // Bumped on every _listen() call. Speech callbacks check this to avoid
  // re-arming listen() based on stale `done`/`notListening` events from a
  // previous listen session (e.g. one already superseded by a speak→listen
  // transition that happened to fire its own status event).
  int _listenEpoch = 0;

  /// Speaker is always on in v1 (audioplayers media channel). Kept as a field
  /// so the UI can show/toggle it later without an API change.
  bool _speakerOn = true;
  bool get speakerOn => _speakerOn;

  String? _status;
  String? get status => _status;

  bool _speechAvailable = false;
  bool _active = false;
  String _sttLocaleId = 'en-US';
  final StringBuffer _replyBuffer = StringBuffer();

  /// Enter the call: build the Gateway client, init the mic, start listening.
  Future<void> start() async {
    _api = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      pathPrefix: connection.gatewayPrefix ?? '',
    );
    _gateway = GatewayChatClient(_api);

    _speechAvailable = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
    );
    if (!_speechAvailable) {
      _status = 'Speech recognition unavailable on this device';
      _setState(CallState.error);
      return;
    }

    // Derive the STT locale from the saved XTTS language (same convention as
    // the chat screen's voice input).
    final prefs = await SharedPreferences.getInstance();
    final lang = prefs.getString(XttsPrefs.language) ?? XttsPrefs.defaultLanguage;
    _sttLocaleId = _localeFor(lang);

    // Use the TTS backend selected in Settings (default XTTS).
    final tts = await ttsProviderForPrefs(prefs);
    if (tts is! XttsService) {
      _xtts.dispose();
      _xtts = tts;
    }

    _active = true;
    await _applyCallAudio();
    await _startForegroundService();
    _listen();
  }

  /// Route mic + playback through a connected Bluetooth earpiece: ask native
  /// AudioManager to enter call mode + open Bluetooth SCO, wait for SCO to
  /// actually connect. The order matters — starting the recognizer before SCO
  /// is up makes Android grab the phone mic and ignore the BT earpiece. We
  /// intentionally do NOT push an audioplayers AudioContext here: the native
  /// AudioManager already set MODE_IN_COMMUNICATION + routed to SCO, and a
  /// competing AudioContextAndroid call from the Dart side would race the
  /// Kotlin route and can flip speaker back on.
  Future<void> _applyCallAudio() async {
    final scoOn = await CallAudio.startCallAudio();
    debugPrint('[Call] SCO ready: $scoOn');
  }

  /// Undo [_applyCallAudio]: stop SCO, return to normal mode + media playback.
  Future<void> _restoreAudio() async {
    await CallAudio.stopCallAudio();
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(usageType: AndroidUsageType.media),
        ),
      );
    } catch (_) {}
  }

  /// Start the microphone-type foreground service so the call survives
  /// backgrounding and screen lock. Called after the mic permission is granted
  /// (speech_to_text.initialize), which Android 14+ requires for a microphone
  /// foreground service. Best-effort: a failure does not block the call, only
  /// background persistence.
  Future<void> _startForegroundService() async {
    try {
      final notifPerm =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notifPerm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'Hermes call',
        notificationText: 'Voice call in progress',
        serviceTypes: const [ForegroundServiceTypes.microphone],
        callback: callTaskStartCallback,
      );
    } catch (e) {
      debugPrint('[Call] foreground service start failed: $e');
    }
  }

  /// Start one listening turn.
  void _listen() {
    if (!_active || _muted || !_speechAvailable) return;
    // Don't open the mic while TTS is still playing — we'd capture our own
    // reply and send it as the next turn. If TTS is busy, schedule a re-arm
    // for after it finishes (caller's onComplete path will re-call _listen).
    if (_xtts.isPlaying) {
      debugPrint('[Call] defer listen: TTS still playing');
      return;
    }
    final epoch = ++_listenEpoch;
    _setState(CallState.listening);
    _speech.listen(
      onResult: (r) => _onResult(r, epoch),
      listenOptions: SpeechListenOptions(
        // 60s hard cap per turn so a stuck-open mic can't hang the call.
        listenFor: const Duration(seconds: 60),
        // 1.5s end-of-turn silence. The chat screen uses 3s, but a real call
        // needs a tighter window or back-and-forth feels dead. speech_to_text
        // does energy-based VAD internally — this is the only knob we have.
        pauseFor: const Duration(milliseconds: 1500),
        localeId: _sttLocaleId,
        listenMode: ListenMode.dictation,
        partialResults: false,
      ),
    );
  }

  void _onResult(SpeechRecognitionResult result, int epoch) {
    if (!_active || epoch != _listenEpoch) return;
    final text = result.recognizedWords.trim();
    if (text.isEmpty || !result.finalResult) return;
    _send(text);
  }

  /// Send a recognized turn to the Gateway and stream the reply.
  Future<void> _send(String text) async {
    _setState(CallState.thinking);
    _replyBuffer.clear();
    await _gateway.sendMessageStreaming(
      message: text,
      sessionId: session.id,
      onToken: (token) => _replyBuffer.write(token),
      onDone: () => _speak(_replyBuffer.toString()),
      onError: (error) {
        debugPrint('[Call] send error: $error');
        _status = 'Send failed: $error';
        notifyListeners();
        // Keep the call alive: resume listening after a failed turn.
        _listen();
      },
    );
  }

  /// Speak the agent reply, then resume listening on completion.
  Future<void> _speak(String reply) async {
    final spoken = reply.trim();
    if (spoken.isEmpty) {
      _listen();
      return;
    }
    _setState(CallState.speaking);
    try {
      await _xtts.speak(
        spoken,
        onComplete: () {
          if (_active && !_muted) _listen();
        },
      );
    } catch (e) {
      debugPrint('[Call] speak failed: $e');
      _status = 'Voice offline — replies silent';
      notifyListeners();
      // TTS down should not end the call; keep listening.
      _listen();
    }
  }

  void _onSpeechStatus(String status) {
    debugPrint('[Call] speech status: $status (epoch $_listenEpoch)');
    // Mic stopped. If we were mid-listen with no turn in flight (e.g. the 60s
    // listen window elapsed with no speech), re-arm so the call stays live.
    // Guard with the current epoch so a stale `done` from a listen session
    // that was already superseded doesn't trigger a second listen() racing
    // with the one that's actually live.
    if ((status == 'done' || status == 'notListening') &&
        _active &&
        !_muted &&
        _state == CallState.listening) {
      _listen();
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    debugPrint('[Call] speech error: ${error.errorMsg} (epoch $_listenEpoch)');
    if (_active && !_muted) {
      Future.delayed(const Duration(milliseconds: 500), _listen);
    }
  }

  void setMuted(bool muted) {
    _muted = muted;
    notifyListeners();
    if (muted) {
      _speech.stop();
    } else {
      _listen();
    }
  }

  void toggleSpeaker() {
    _speakerOn = !_speakerOn;
    notifyListeners();
  }

  /// End the call: stop mic + TTS, release the Gateway client.
  Future<void> hangUp() async {
    _active = false;
    await _restoreAudio();
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
    try {
      await _speech.stop();
    } catch (_) {}
    try {
      await _xtts.stop();
    } catch (_) {}
    try {
      _gateway.abort();
    } catch (_) {}
    _setState(CallState.connecting);
  }

  void _setState(CallState s) {
    _state = s;
    notifyListeners();
  }

  /// Map an XTTS language code (e.g. 'en') to a speech_to_text locale id.
  String _localeFor(String lang) {
    if (lang.contains('-')) return lang;
    const map = <String, String>{
      'en': 'en-US',
      'es': 'es-ES',
      'fr': 'fr-FR',
      'de': 'de-DE',
      'it': 'it-IT',
      'pt': 'pt-BR',
      'nl': 'nl-NL',
      'pl': 'pl-PL',
      'ru': 'ru-RU',
      'tr': 'tr-TR',
      'ja': 'ja-JP',
      'zh': 'zh-CN',
      'ko': 'ko-KR',
      'ar': 'ar-SA',
      'hi': 'hi-IN',
      'cs': 'cs-CZ',
    };
    return map[lang] ?? 'en-US';
  }

  @override
  void dispose() {
    _active = false;
    try {
      FlutterForegroundTask.stopService();
    } catch (_) {}
    CallAudio.stopCallAudio();
    _speech.cancel();
    _xtts.dispose();
    try {
      _api.close();
    } catch (_) {}
    super.dispose();
  }
}
