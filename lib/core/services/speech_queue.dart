// Serialises TTS chunks for streaming call replies. Chunks arrive while the
// generation is still running; this queue guarantees they are synthesized and
// played strictly in order, one at a time, and that the "reply finished
// speaking" signal fires only after the last chunk has actually played.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tts_provider.dart';

/// Plays queued utterances through a [TtsProvider], one after another.
///
/// [enqueue] appends a chunk and starts the pump if idle. [markComplete] says
/// no further chunks are coming, so once the queue drains the completion
/// callback passed to [start] fires. [cancel] abandons everything pending.
///
/// The provider is resolved per chunk rather than captured, because the owning
/// controller may swap backends (XTTS ↔ Chatterbox) after this queue is built.
class SpeechQueue {
  SpeechQueue(this._resolveTts);

  final TtsProvider Function() _resolveTts;
  final List<String> _pending = [];

  bool _draining = false;
  bool _inputClosed = false;
  bool _cancelled = false;
  bool _finished = false;
  bool _started = false;
  void Function()? _onAllSpoken;

  /// True from [start] until every queued chunk has played (or the reply was
  /// cancelled). False before the first reply, so it never blocks the initial
  /// listen. Callers gate mic re-arming on this.
  bool get isSpeaking => _started && !_finished && !_cancelled;

  /// Begin a new reply. [onAllSpoken] fires once, after the final chunk plays.
  void start({required void Function() onAllSpoken}) {
    _pending.clear();
    _draining = false;
    _inputClosed = false;
    _cancelled = false;
    _finished = false;
    _started = true;
    _onAllSpoken = onAllSpoken;
  }

  void enqueue(String chunk) {
    if (_cancelled || _inputClosed) return;
    final text = chunk.trim();
    if (text.isEmpty) return;
    _pending.add(text);
    unawaited(_drain());
  }

  /// No more chunks will be enqueued for this reply.
  void markComplete() {
    if (_cancelled) return;
    _inputClosed = true;
    // Nothing queued and nothing playing — the reply is already done.
    if (!_draining) _finish();
  }

  /// Abandon the current reply: drop pending chunks and stop playback. Does
  /// not fire the completion callback.
  Future<void> cancel() async {
    _cancelled = true;
    _pending.clear();
    _onAllSpoken = null;
    try {
      await _resolveTts().stop();
    } catch (_) {}
  }

  Future<void> _drain() async {
    if (_draining || _cancelled) return;
    _draining = true;
    while (_pending.isNotEmpty && !_cancelled) {
      final chunk = _pending.removeAt(0);
      final done = Completer<void>();
      try {
        await _resolveTts().speak(chunk, onComplete: () {
          if (!done.isCompleted) done.complete();
        });
        // speak() returns once playback has been handed to the player; the
        // completion callback is what tells us the audio actually ended.
        await done.future;
      } catch (e) {
        debugPrint('[SpeechQueue] chunk failed: $e');
        // Skip the failed chunk and keep the reply going.
      }
    }
    _draining = false;
    if (_inputClosed && !_cancelled) _finish();
  }

  void _finish() {
    if (_finished || _cancelled) return;
    if (_pending.isNotEmpty || _draining) return;
    _finished = true;
    final cb = _onAllSpoken;
    _onAllSpoken = null;
    cb?.call();
  }
}
