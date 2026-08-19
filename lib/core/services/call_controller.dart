// Phone-call-mode controller: a hands-free, turn-taking voice loop bound to a
// chat session. listen (speech_to_text) -> send (Gateway SSE stream) -> speak
// (XTTS) -> listen again, until hang-up. State machine exposed as [CallState]
// for the call screen to render.
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'call_audio.dart';
import 'call_route_policy.dart';
import 'connection_manager.dart';
import 'foreground_service_lease.dart';
import 'tts_provider.dart';
import 'xtts_service.dart';
import 'async_generation_gate.dart';
import 'speech_queue.dart';
import 'speech_recognition_coordinator.dart';
import 'speech_retry_backoff.dart';
import 'speech_segmenter.dart';

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

  final Object _speechOwner = Object();
  final SpeechRecognitionCoordinator _speechCoordinator =
      SpeechRecognitionCoordinator.instance;
  SpeechToText get _speech => _speechCoordinator.speech;
  late TtsProvider _xtts = XttsService(fallbackHost: connection.host);
  final AsyncGenerationGate _lifecycle = AsyncGenerationGate();
  bool _disposed = false;
  StreamSubscription<int>? _audioFocusSubscription;
  bool _ttsPausedForFocus = false;
  final SpeechRetryBackoff _speechRetryBackoff = SpeechRetryBackoff();
  Timer? _listenRetryTimer;
  DateTime _listenRetryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);
  bool _listenStarting = false;
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

  /// Reflects the device loudspeaker state for the active call. Seeded from
  /// `AudioManager.isSpeakerphoneOn` after `_applyCallAudio` so the UI matches
  /// the actual route on first render; updated by [toggleSpeaker].
  bool _speakerOn = true;
  bool _bluetoothActive = false;
  bool get speakerOn => _speakerOn;

  String? _status;
  String? get status => _status;

  bool _speechAvailable = false;
  bool _active = false;
  // Guards against a second native stopCallAudio: both hangUp() and dispose()
  // restore audio, and a normal exit runs both. Set on first teardown.
  bool _audioStopped = false;
  String _sttLocaleId = 'en-US';
  StreamCancelToken? _sendCancelToken;

  // Tail of the streaming reply not yet handed to the speech queue. Chunks are
  // cut off the front at sentence boundaries as tokens arrive.
  String _speakTail = '';

  // How much of [_speakTail] segmentSpeech has already examined without
  // finding a boundary, so each token's pump only scans the newly arrived
  // characters instead of the whole accumulated tail.
  int _speakTailScanned = 0;
  late final SpeechQueue _speechQueue = SpeechQueue(() => _xtts);

  // Don't speak a first chunk shorter than this — a bare "Hi." would otherwise
  // be synthesized on its own, wasting a round-trip on one word. Later chunks
  // have no minimum: by then audio is already playing, so the queue just needs
  // to stay fed.
  static const _firstChunkMinChars = 40;

  /// Enter the call: build the Gateway client, init the mic, start listening.
  Future<void> start() async {
    final lifecycle = _lifecycle.begin();
    _api = ApiClient(
      baseUrl: connection.baseUrl,
      apiKey: connection.apiKey,
      pathPrefix: connection.gatewayPrefix ?? '',
    );
    _gateway = GatewayChatClient(_api);

    _speechCoordinator.claim(
      _speechOwner,
      onStatus: _onSpeechStatus,
      onError: (e) => _onSpeechError(e, _listenEpoch),
    );
    _speechAvailable = await _speechCoordinator.initialize();
    if (!_lifecycle.isCurrent(lifecycle)) return;
    if (!_speechAvailable) {
      _status = 'Speech recognition unavailable on this device';
      _setState(CallState.error);
      return;
    }

    // Derive the STT locale from the saved XTTS language (same convention as
    // the chat screen's voice input).
    final prefs = await SharedPreferences.getInstance();
    if (!_lifecycle.isCurrent(lifecycle)) return;
    final lang = prefs.getString(XttsPrefs.language) ?? XttsPrefs.defaultLanguage;
    _sttLocaleId = _localeFor(lang);

    // Use the TTS backend selected in Settings (default XTTS).
    final tts = await ttsProviderForPrefs(prefs, fallbackHost: connection.host);
    if (!_lifecycle.isCurrent(lifecycle)) {
      tts.dispose();
      return;
    }
    if (tts is! XttsService) {
      _xtts.dispose();
      _xtts = tts;
    } else {
      // Already holding an XttsService (the default) — this freshly built
      // one won't be used, so release its AudioPlayer/http.Client now.
      tts.dispose();
    }

    _active = true;
    await _applyCallAudio();
    if (!_lifecycle.isCurrent(lifecycle)) {
      await CallAudio.stopCallAudio();
      return;
    }
    if (callAudioFocusStrategy() == CallAudioFocusStrategy.manualCall) {
      _audioFocusSubscription ??=
          CallAudio.audioFocusChanges.listen(_onAudioFocusChange);
      await CallAudio.requestAudioFocus();
    }
    if (!_lifecycle.isCurrent(lifecycle)) {
      await _audioFocusSubscription?.cancel();
      _audioFocusSubscription = null;
      await CallAudio.abandonAudioFocus();
      await CallAudio.stopCallAudio();
      return;
    }
    await _startForegroundService();
    if (!_lifecycle.isCurrent(lifecycle)) {
      await _stopForegroundService();
      await CallAudio.stopCallAudio();
      return;
    }
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
  ///
  /// On exit, native sets `isSpeakerphoneOn = false` (`MODE_IN_COMMUNICATION`).
  /// We seed `_speakerOn` from the actual native state so the UI matches audio
  /// routing on first render — toggling works the same regardless.
  Future<void> _applyCallAudio() async {
    final scoOn = await CallAudio.startCallAudio();
    _bluetoothActive = scoOn;
    debugPrint('[Call] SCO ready: $scoOn');
    final speakerState = await CallAudio.setSpeakerphone(enabled: false);
    if (speakerState != null) _speakerOn = speakerState;
  }

  /// Undo [_applyCallAudio]: stop SCO, return to normal mode + media playback.
  /// Idempotent — a second call (hangUp then dispose) is a no-op.
  Future<void> _restoreAudio() async {
    if (_audioStopped) return;
    _audioStopped = true;
    await _audioFocusSubscription?.cancel();
    _audioFocusSubscription = null;
    await CallAudio.abandonAudioFocus();
    await CallAudio.stopCallAudio();
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(usageType: AndroidUsageType.media),
        ),
      );
    } catch (_) {}
  }

  Future<void> _prepareAudioPhase(CallAudioPhase phase) async {
    final route = callRouteForPhase(
      phase: phase,
      bluetoothActive: _bluetoothActive,
      speakerOn: _speakerOn,
    );
    switch (route) {
      case CallNativeRoute.released:
        await CallAudio.stopCallAudio();
        break;
      case CallNativeRoute.handset:
        _bluetoothActive = await CallAudio.startCallAudio();
        if (!_bluetoothActive) {
          await CallAudio.setSpeakerphone(enabled: false);
        }
        break;
      case CallNativeRoute.speaker:
        await CallAudio.setSpeakerphone(enabled: true);
        break;
      case CallNativeRoute.bluetooth:
        break;
    }
  }

  Future<void> _onAudioFocusChange(int change) async {
    if (!_active) return;
    if (change == 1) {
      if (_ttsPausedForFocus) {
        _ttsPausedForFocus = false;
        await _xtts.resume();
      } else if (!_muted && _state != CallState.thinking) {
        await _listen();
      }
      return;
    }
    try {
      await _speech.cancel();
    } catch (_) {}
    if (_xtts.isPlaying) {
      _ttsPausedForFocus = true;
      await _xtts.pause();
    }
  }

  /// True once this controller holds the shared foreground-service lease --
  /// mirrors ForegroundServiceLease's acquire/release contract so hangUp()/
  /// dispose() release exactly once per successful acquire, the same
  /// discipline chat_screen.dart's _backgroundServiceActive uses. Without
  /// this, an unconditional stopService() call here could kill an
  /// unrelated overlapping chat background-send's protection (or vice
  /// versa) -- see ForegroundServiceLease's doc comment.
  bool _foregroundServiceActive = false;

  /// Acquires the microphone-type foreground service lease so the call
  /// survives backgrounding and screen lock. Called after the mic permission
  /// is granted (speech_to_text.initialize), which Android 14+ requires for
  /// a microphone foreground service. Best-effort: a failure does not block
  /// the call, only background persistence.
  Future<void> _startForegroundService() async {
    _foregroundServiceActive = await ForegroundServiceLease.acquire(
      notificationTitle: 'Hermes call',
      notificationText: 'Voice call in progress',
      serviceTypes: const [
        ForegroundServiceTypes.microphone,
        ForegroundServiceTypes.mediaPlayback,
      ],
      callback: callTaskStartCallback,
    );
  }

  Future<void> _stopForegroundService() async {
    if (!_foregroundServiceActive) return;
    _foregroundServiceActive = false;
    await ForegroundServiceLease.release();
  }

  /// Start one listening turn. This front guard is the single gate for
  /// re-arming — callers (onComplete, onError, status/error handlers) may call
  /// bare _listen() without repeating the active/muted checks.
  Future<void> _listen() async {
    if (!_active || _muted || !_speechAvailable || _listenStarting) return;
    // Don't open the mic while TTS is still playing — we'd capture our own
    // reply and send it as the next turn. Also covers the gaps between queued
    // chunks of a streaming reply, where the player is briefly idle but the
    // reply isn't finished; the queue's onAllSpoken re-calls _listen.
    if (_xtts.isPlaying || _speechQueue.isSpeaking) {
      debugPrint('[Call] defer listen: TTS still playing');
      return;
    }
    _listenStarting = true;
    try {
      await _prepareAudioPhase(CallAudioPhase.listening);
    } catch (e) {
      debugPrint('[Call] listening route failed: $e');
    }
    if (!_active || _muted) {
      _listenStarting = false;
      return;
    }
    final epoch = ++_listenEpoch;
    _lastTranscript = '';
    _setState(CallState.listening);
    _speechCoordinator.claim(
      _speechOwner,
      onStatus: _onSpeechStatus,
      onError: (e) => _onSpeechError(e, epoch),
    );
    try {
      await _speech.listen(
      onResult: (r) => _onResult(r, epoch),
      listenOptions: SpeechListenOptions(
        // 60s hard cap per turn so a stuck-open mic can't hang the call.
        listenFor: const Duration(seconds: 60),
        // 1.5s end-of-turn silence. Maps to
        // EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS — hard session
        // close after this much silence, not an energy-VAD knob. This keeps
        // call-mode replies responsive after the user stops talking.
        pauseFor: const Duration(milliseconds: 1500),
        localeId: _sttLocaleId,
        listenMode: ListenMode.dictation,
        // Enable partial results so we see the running transcript as Android
        // decodes it. With this off the recognizer only reports once at the
        // silence-timeout final — and at that exact moment the last ~200ms of
        // audio is often still in the decoder buffer, so trailing words get
        // truncated. With partials on we get intermediate results that
        // include those trailing words before the session closes.
        partialResults: true,
        // Use the on-device recognizer when available (Android 12+). This
        // routes through createOnDeviceSpeechRecognizer + EXTRA_PREFER_OFFLINE
        // — sidesteps the network recognizer's start/stop beep on devices
        // that ship an offline model (most modern Pixels/Samsungs). Falls
        // back to the cloud recognizer with a beep if no offline model.
        onDevice: true,
      ),
      );
    } catch (e) {
      if (!_active || epoch != _listenEpoch) return;
      _status = 'Microphone failed: $e';
      notifyListeners();
      final delay = _speechRetryBackoff.recordFailure();
      _listenRetryNotBefore = DateTime.now().add(delay);
      _scheduleListen();
    } finally {
      _listenStarting = false;
    }
  }

  // Latest non-empty transcript for the current listen session. Updated on
  // every onResult so we always send the freshest text when final fires.
  String _lastTranscript = '';

  void _onResult(SpeechRecognitionResult result, int epoch) {
    // _muted is redundant with the epoch bump setMuted() now does -- _muted
    // is only ever set there -- but kept as a direct, obviously-correct
    // guard rather than relying solely on the epoch invariant holding for
    // every future path that might touch _muted.
    if (!_active || _muted || epoch != _listenEpoch) return;
    final text = result.recognizedWords.trim();
    _speechRetryBackoff.reset();
    _listenRetryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);
    if (text.isNotEmpty) _lastTranscript = text;
    // partialResults: true → Android emits partials while speaking AND a final
    // at session close. Send on final; ignore empty finals (some recognizers
    // emit a final with empty text on pure silence).
    if (!result.finalResult) return;
    if (_lastTranscript.isEmpty) return;
    final toSend = _lastTranscript;
    _lastTranscript = '';
    _send(toSend);
  }

  /// Send a recognized turn to the Gateway and stream the reply.
  ///
  /// Speech starts at the first sentence boundary rather than waiting for the
  /// whole generation: on a slow backend the reply can take a minute or more,
  /// and holding all audio until the final token made the call feel dead. The
  /// mic stays closed until every queued chunk has played (see [_speechQueue]),
  /// so we still never record our own voice.
  Future<void> _send(String text) async {
    _setState(CallState.thinking);
    _speakTail = '';
    _speakTailScanned = 0;
    var speaking = false;
    final cancelToken = StreamCancelToken();
    _sendCancelToken = cancelToken;

    _speechQueue.start(onAllSpoken: () {
      if (_active && !_muted) _listen();
    });

    // Cuts every complete sentence off the tail and queues it. Called on each
    // token, and once more at end-of-stream to flush whatever is left.
    void pump({required bool flush}) {
      if (!_active) return;
      final segmentation = segmentSpeech(
        _speakTail,
        minChunkChars: speaking ? 0 : _firstChunkMinChars,
        alreadyScanned: _speakTailScanned,
        isFinal: flush,
      );
      _speakTail = segmentation.remainder;
      // Everything left over has now been scanned and yielded no boundary.
      _speakTailScanned = _speakTail.length;
      var chunks = segmentation.chunks;
      if (flush) {
        final tail = _speakTail.trim();
        _speakTail = '';
        _speakTailScanned = 0;
        if (tail.isNotEmpty) chunks = [...chunks, tail];
      }
      if (chunks.isEmpty) return;
      if (!speaking) {
        speaking = true;
        _setState(CallState.speaking);
        // Route audio for playback before the first chunk is synthesized.
        unawaited(_prepareAudioPhase(CallAudioPhase.speaking));
      }
      for (final chunk in chunks) {
        _speechQueue.enqueue(chunk);
      }
    }

    await _gateway.sendMessageStreaming(
      message: text,
      sessionId: session.id,
      cancelToken: cancelToken,
      onToken: (token) {
        if (!_active) return;
        _speakTail += token;
        pump(flush: false);
      },
      onDone: () {
        _sendCancelToken = null;
        if (!_active) return;
        pump(flush: true);
        // Nothing was speakable (empty reply, or stripped to nothing) — the
        // queue never got a chunk, so re-arm the mic directly.
        if (!speaking) {
          _speechQueue.markComplete();
          _listen();
          return;
        }
        _speechQueue.markComplete();
      },
      onError: (error) {
        _sendCancelToken = null;
        if (!_active) return;
        debugPrint('[Call] send error: $error');
        _status = 'Send failed: $error';
        notifyListeners();
        // Keep the call alive: finish anything already queued, else re-listen.
        if (speaking) {
          pump(flush: true);
          _speechQueue.markComplete();
        } else {
          unawaited(_speechQueue.cancel());
          _listen();
        }
      },
    );
  }

  // Grace period after a terminal status (done/notListening) with no result
  // or error yet, before the watchdog below force-rearms. Real
  // results/errors normally follow a terminal status within tens of
  // milliseconds; this is generous headroom, not a tuned deadline.
  static const _statusWatchdogGrace = Duration(milliseconds: 1200);

  void _onSpeechStatus(String status) {
    debugPrint('[Call] speech status: $status (epoch $_listenEpoch)');
    // Mic stopped. If we were mid-listen with no turn in flight (e.g. the 60s
    // listen window elapsed with no speech), re-arm so the call stays live.
    // Guard with the current epoch so a stale `done` from a listen session
    // that was already superseded doesn't trigger a second listen() racing
    // with the one that's actually live.
    if (status == 'listening') {
      _listenRetryTimer?.cancel();
      _listenRetryTimer = null;
    }
    if ((status == 'done' || status == 'notListening') &&
        _active &&
        !_muted &&
        _state == CallState.listening) {
      // shouldRearmAfterSpeechStatus is permanently false: rearming
      // immediately off this status raced _onResult/_onSpeechError, which
      // fire for the same session. But if a session ends with truly empty
      // audio, on-device recognizers can emit this terminal status with
      // neither a final result nor an error ever following -- nothing else
      // would ever rearm, and the call would sit at CallState.listening
      // forever. This watchdog is the deferred, epoch-scoped fallback: it
      // only acts if nothing resolved this exact session within the grace
      // window, so it can't race a genuine result/error the way an
      // immediate rearm would.
      final epoch = _listenEpoch;
      Timer(_statusWatchdogGrace, () {
        if (_active &&
            !_muted &&
            _state == CallState.listening &&
            epoch == _listenEpoch) {
          _scheduleListen();
        }
      });
    }
  }

  void _scheduleListen() {
    if (!_active || _muted || _state != CallState.listening) return;
    final remaining = _listenRetryNotBefore.difference(DateTime.now());
    final delay = remaining > const Duration(milliseconds: 150)
        ? remaining
        : const Duration(milliseconds: 150);
    _listenRetryTimer?.cancel();
    _listenRetryTimer = Timer(delay, () {
      _listenRetryTimer = null;
      _listen();
    });
  }

  void _onSpeechError(SpeechRecognitionError error, int epoch) {
    debugPrint(
      '[Call] speech error: ${error.errorMsg} (epoch $epoch, current $_listenEpoch)',
    );
    // Mirrors _onResult's epoch check: an error from a listen session already
    // superseded by a newer one (e.g. this callback still in flight from an
    // old _listen() call when a fresh one started) must not schedule a
    // rearm on top of the session that's actually live.
    if (epoch != _listenEpoch) return;
    if (_active && !_muted) {
      if (speechErrorNeedsBackoff(error.errorMsg)) {
        final delay = _speechRetryBackoff.recordFailure();
        _listenRetryNotBefore = DateTime.now().add(delay);
      } else {
        _speechRetryBackoff.reset();
        _listenRetryNotBefore = DateTime.fromMillisecondsSinceEpoch(0);
      }
      _scheduleListen();
    }
  }

  void setMuted(bool muted) {
    _muted = muted;
    notifyListeners();
    if (muted) {
      _listenRetryTimer?.cancel();
      _listenRetryTimer = null;
      // cancel(), not stop(): speech_to_text's own docs say cancel()
      // guarantees "there will be no final result returned from the
      // recognizer", implying (confirmed by reading the package source)
      // that stop() does NOT make that guarantee -- it still delivers one
      // more final result asynchronously after returning. That result would
      // otherwise sail past _onResult's epoch check (unchanged until now)
      // and get sent to the gateway as if the user hadn't muted at all.
      // Bumping the epoch and clearing the buffer here is belt-and-braces
      // on top of that, matching the same pattern _listen() already uses to
      // invalidate a superseded session.
      ++_listenEpoch;
      _lastTranscript = '';
      _speech.cancel();
    } else {
      _listen();
    }
  }

  Future<void> toggleSpeaker() async {
    // No-op once the call has ended: flipping isSpeakerphoneOn in MODE_NORMAL
    // would fight the restored media route.
    if (!_active) return;
    final next = !_speakerOn;
    final actual = await CallAudio.setSpeakerphone(enabled: next);
    if (actual == null) {
      _status = 'Speaker switch failed';
      notifyListeners();
      return;
    }
    _speakerOn = actual;
    notifyListeners();
  }

  /// End the call: stop mic + TTS, release the Gateway client.
  Future<void> hangUp() async {
    _lifecycle.cancel();
    _active = false;
    _listenRetryTimer?.cancel();
    _listenRetryTimer = null;
    await _speechQueue.cancel();
    _speechCoordinator.release(_speechOwner);
    _audioFocusSubscription?.cancel();
    CallAudio.abandonAudioFocus();
    await _restoreAudio();
    await _stopForegroundService();
    try {
      await _speech.stop();
    } catch (_) {}
    try {
      await _xtts.stop();
    } catch (_) {}
    try {
      _sendCancelToken?.cancel();
    } catch (_) {}
    try {
      _gateway.abort();
    } catch (_) {}
    _setState(CallState.connecting);
  }

  void _setState(CallState s) {
    if (_disposed) return;
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
    _disposed = true;
    _lifecycle.cancel();
    _active = false;
    _listenRetryTimer?.cancel();
    unawaited(_speechQueue.cancel());
    _speechCoordinator.release(_speechOwner);
    _audioFocusSubscription?.cancel();
    _audioFocusSubscription = null;
    CallAudio.abandonAudioFocus();
    try {
      _sendCancelToken?.cancel();
    } catch (_) {}
    unawaited(_stopForegroundService());
    // Idempotent: skips the native call if hangUp() already restored audio.
    if (!_audioStopped) {
      _audioStopped = true;
      CallAudio.stopCallAudio();
    }
    _speech.cancel();
    _xtts.dispose();
    try {
      _api.close();
    } catch (_) {}
    super.dispose();
  }
}
