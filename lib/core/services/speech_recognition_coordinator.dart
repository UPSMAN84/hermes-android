import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

class SpeechEventRouter {
  Object? _owner;
  void Function(String)? _status;
  void Function(SpeechRecognitionError)? _error;

  Object? get owner => _owner;

  void claim(
    Object owner, {
    void Function(String)? onStatus,
    void Function(SpeechRecognitionError)? onError,
  }) {
    _owner = owner;
    _status = onStatus;
    _error = onError;
  }

  void release(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _status = null;
    _error = null;
  }

  void dispatchStatus(String status) => _status?.call(status);
  void dispatchError(SpeechRecognitionError error) => _error?.call(error);
}

class SpeechRecognitionCoordinator {
  SpeechRecognitionCoordinator._();
  static final instance = SpeechRecognitionCoordinator._();

  final SpeechToText speech = SpeechToText();
  final SpeechEventRouter _router = SpeechEventRouter();
  Future<bool>? _initialization;

  void claim(
    Object owner, {
    void Function(String)? onStatus,
    void Function(SpeechRecognitionError)? onError,
  }) {
    // claim() only used to swap which owner's callbacks the router forwards
    // to -- it never touched the actual mic. Two owners (e.g. chat's inline
    // voice input and call mode) could each call speech.listen() on this one
    // shared SpeechToText instance, since the plugin has no re-entrancy guard
    // of its own. Stopping the outgoing owner's session here, before its
    // callbacks are detached, makes it the outgoing owner's own onStatus that
    // observes the resulting done/notListening (not silently dropped), so
    // its "am I still listening" state resolves correctly instead of getting
    // stuck on whatever it was at hand-off.
    if (!identical(owner, _router.owner) && speech.isListening) {
      speech.stop();
    }
    _router.claim(owner, onStatus: onStatus, onError: onError);
  }

  void release(Object owner) => _router.release(owner);

  /// Concurrent callers within one attempt share the same in-flight Future
  /// (the whole point of caching), but a FAILED attempt must not stick: the
  /// underlying plugin's own initialize() only short-circuits on a prior
  /// *success* (see speech_to_text's _initWorked guard), so it already
  /// supports being retried after returning false -- e.g. the mic permission
  /// wasn't granted yet on first launch, then was granted from Settings.
  /// Caching `false` here forever would silently break voice input for the
  /// rest of the app process past that point, with no way to recover short
  /// of a restart.
  Future<bool> initialize() {
    final cached = _initialization;
    if (cached != null) return cached;
    // Cache the plugin's own Future directly, so callers see its exact
    // value/error semantics. A second listener below only clears the cache
    // on failure -- multiple listeners on one Future is normal Dart, so this
    // doesn't alter what the caller observes.
    final attempt = speech.initialize(
      onStatus: _router.dispatchStatus,
      onError: _router.dispatchError,
    );
    _initialization = attempt;
    attempt.then(
      (ok) {
        if (!ok) _initialization = null;
      },
      onError: (Object _, StackTrace _) {
        _initialization = null;
      },
    );
    return attempt;
  }
}
