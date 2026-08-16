// Serialises TTS chunks for streaming call replies. Chunks arrive while the
// generation is still running; this queue guarantees they are synthesized and
// played strictly in order, one at a time, and that the "reply finished
// speaking" signal fires only after the last chunk has actually played.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'tts_provider.dart';
export 'tts_provider.dart' show PreparedSpeech;

/// Plays queued utterances through a [TtsProvider], one after another.
///
/// [enqueue] appends a chunk and starts the pump if idle. [markComplete] says
/// no further chunks are coming, so once the queue drains the completion
/// callback passed to [start] fires. [cancel] abandons everything pending.
///
/// The provider is resolved per chunk rather than captured, because the owning
/// controller may swap backends (XTTS ↔ Chatterbox) after this queue is built.
/// One queued utterance plus its synthesis, once started.
class _QueuedChunk {
  _QueuedChunk(this.text);

  final String text;

  /// Non-null once synthesis has been kicked off for this chunk — possibly
  /// while an earlier chunk is still playing. Never completes with an error:
  /// see [SpeechQueue._safePrepare].
  Future<PreparedSpeech?>? prepared;
}

class SpeechQueue {
  SpeechQueue(this._resolveTts);

  final TtsProvider Function() _resolveTts;
  final List<_QueuedChunk> _pending = [];

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
    _pending.add(_QueuedChunk(text));
    // Start synthesizing it now if nothing else is queued ahead of it, even
    // when the player is busy with the previous chunk.
    _startLookahead();
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

  // Upper bound on how long one chunk is allowed to sit "playing": synthesis
  // itself already has its own HTTP timeout, but if the platform player wedges
  // *after* a successful handoff (no error, no completion event -- rare, but
  // seen on some devices/players), nothing else would ever complete `done`,
  // parking the whole call at CallState.speaking indefinitely.
  static const _playbackWatchdog = Duration(seconds: 60);

  /// Begin synthesizing the chunk at the head of the queue, if it hasn't
  /// started already. This is the whole point of the split provider API: a
  /// sentence boundary used to cost a full synthesis round trip of silence,
  /// because the next chunk's HTTP request only started after the previous
  /// chunk had finished *playing*. One chunk of lookahead is enough to keep
  /// the player fed as long as synthesis is no slower than playback.
  void _startLookahead() {
    if (_cancelled || _pending.isEmpty) return;
    final next = _pending.first;
    next.prepared ??= _safePrepare(next.text);
  }

  /// Synthesis that never completes with an error, so a lookahead future that
  /// nobody ends up awaiting (cancelled reply) can't surface as an unhandled
  /// async error. A failed chunk resolves to null and gets skipped.
  Future<PreparedSpeech?> _safePrepare(String text) async {
    try {
      return await _resolveTts().prepare(text);
    } catch (e) {
      debugPrint('[SpeechQueue] synthesis failed: $e');
      return null;
    }
  }

  Future<void> _drain() async {
    if (_draining || _cancelled) return;
    _draining = true;
    while (_pending.isNotEmpty && !_cancelled) {
      final chunk = _pending.removeAt(0);
      final synthesis = chunk.prepared ??= _safePrepare(chunk.text);
      // Get the following chunk's synthesis moving now, so it overlaps this
      // one's fetch and playback rather than starting after them.
      _startLookahead();

      final prepared = await synthesis;
      if (_cancelled) break;
      // Nothing speakable, or synthesis failed — skip it and keep the reply
      // going rather than stalling the call.
      if (prepared == null) continue;

      final done = Completer<void>();
      try {
        await _resolveTts().speakPrepared(prepared, onComplete: () {
          if (!done.isCompleted) done.complete();
        });
        // speakPrepared() returns once playback has been handed to the player;
        // the completion callback is what tells us the audio actually ended.
        await done.future.timeout(_playbackWatchdog);
      } on TimeoutException {
        debugPrint(
          '[SpeechQueue] chunk playback wedged past '
          '${_playbackWatchdog.inSeconds}s -- forcing stop and moving on',
        );
        try {
          await _resolveTts().stop();
        } catch (_) {}
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
