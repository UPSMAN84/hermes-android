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
  Future<void> _claimTail = Future<void>.value();

  Future<void> claim(
    Object owner, {
    void Function(String)? onStatus,
    void Function(SpeechRecognitionError)? onError,
  }) {
    final previous = _claimTail;
    final current = () async {
      try {
        await previous;
      } catch (_) {}
      // Serialize owner hand-off with the outgoing recognizer stop. Otherwise
      // a new listen can overlap the old session's asynchronous shutdown.
      if (!identical(owner, _router.owner) && speech.isListening) {
        try {
          await speech.stop();
        } catch (_) {}
      }
      _router.claim(owner, onStatus: onStatus, onError: onError);
    }();
    _claimTail = current.then<void>((_) {}, onError: (_, _) {});
    return current;
  }

  void release(Object owner) => _router.release(owner);

  Future<bool> initialize() => _initialization ??= speech.initialize(
        onStatus: _router.dispatchStatus,
        onError: _router.dispatchError,
      );
}
