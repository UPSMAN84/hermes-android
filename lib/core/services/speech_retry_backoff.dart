class SpeechRetryBackoff {
  int _failures = 0;

  Duration recordFailure() {
    _failures++;
    final shift = (_failures - 1).clamp(0, 4);
    return Duration(milliseconds: 500 * (1 << shift));
  }

  void reset() => _failures = 0;
}

bool speechErrorNeedsBackoff(String errorMsg) =>
    errorMsg != 'error_speech_timeout' && errorMsg != 'error_no_match';

