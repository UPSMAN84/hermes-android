import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

class SpeechEventRouter {
  Object? _owner;
  void Function(String)? _status;
  void Function(SpeechRecognitionError)? _error;

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
  }) => _router.claim(owner, onStatus: onStatus, onError: onError);

  void release(Object owner) => _router.release(owner);

  Future<bool> initialize() => _initialization ??= speech.initialize(
        onStatus: _router.dispatchStatus,
        onError: _router.dispatchError,
      );
}
