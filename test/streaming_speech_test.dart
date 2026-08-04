import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/speech_queue.dart';
import 'package:hermes_android/core/services/speech_segmenter.dart';
import 'package:hermes_android/core/services/tts_provider.dart';

/// Records what it was asked to speak and lets each utterance be completed
/// on demand, so ordering and the "still speaking" gate can be asserted.
class FakeTts implements TtsProvider {
  final List<String> spoken = [];
  final List<void Function()> _pending = [];
  int stopCalls = 0;
  bool _playing = false;

  @override
  bool get isPlaying => _playing;

  @override
  Future<void> speak(String text, {void Function()? onComplete}) async {
    spoken.add(text);
    _playing = true;
    if (onComplete != null) _pending.add(onComplete);
  }

  /// Finish the oldest in-flight utterance.
  void finishOne() {
    if (_pending.isEmpty) return;
    _playing = false;
    _pending.removeAt(0)();
  }

  bool get hasPending => _pending.isNotEmpty;

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing = false;
    _pending.clear();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  void dispose() {}
}

void main() {
  group('segmentSpeech', () {
    test('emits complete sentences and keeps the incomplete tail', () {
      final r = segmentSpeech('Hello there. How are you doing');
      expect(r.chunks, ['Hello there.']);
      expect(r.remainder, ' How are you doing');
    });

    test('holds a sentence back until it is terminated', () {
      final r = segmentSpeech('Still going');
      expect(r.chunks, isEmpty);
      expect(r.remainder, 'Still going');
    });

    test('splits on ! and ? and keeps trailing quotes with the sentence', () {
      final r = segmentSpeech('Really? Yes! "Quoted." Next');
      expect(r.chunks, ['Really?', 'Yes!', '"Quoted."']);
      expect(r.remainder, ' Next');
    });

    test('does not split decimals, file names, or abbreviations', () {
      expect(segmentSpeech('It costs 3.14 dollars total').chunks, isEmpty);
      expect(segmentSpeech('Open file.png now').chunks, isEmpty);
      expect(segmentSpeech('Ask Dr. Smith about it').chunks, isEmpty);
      expect(segmentSpeech('By J. R. R. Tolkien here').chunks, isEmpty);
    });

    test('minChunkChars defers short leading sentences', () {
      // "Hi." alone is too short to be worth a synthesis round-trip; it should
      // be merged with the following sentence instead.
      final r = segmentSpeech(
        'Hi. Here is the actual substantive answer you asked for. Rest',
        minChunkChars: 40,
      );
      expect(r.chunks.length, 1);
      expect(r.chunks.single.startsWith('Hi.'), isTrue);
      expect(r.chunks.single.endsWith('asked for.'), isTrue);
      expect(r.remainder, ' Rest');
    });

    test('newlines end a chunk even with no terminator', () {
      final r = segmentSpeech('A list item\nnext line');
      expect(r.chunks, ['A list item']);
      expect(r.remainder, 'next line');
    });
  });

  group('SpeechQueue', () {
    test('is not speaking before the first reply, so listen is not blocked', () {
      final tts = FakeTts();
      expect(SpeechQueue(() => tts).isSpeaking, isFalse);
    });

    test('plays chunks in order, one at a time', () async {
      final tts = FakeTts();
      final queue = SpeechQueue(() => tts);
      queue.start(onAllSpoken: () {});

      queue.enqueue('First.');
      queue.enqueue('Second.');
      await Future<void>.delayed(Duration.zero);

      // Only the first is in flight — the second waits for it to finish.
      expect(tts.spoken, ['First.']);
      tts.finishOne();
      await Future<void>.delayed(Duration.zero);
      expect(tts.spoken, ['First.', 'Second.']);
    });

    test('signals completion only after the last chunk has played', () async {
      final tts = FakeTts();
      final queue = SpeechQueue(() => tts);
      var allSpoken = false;
      queue.start(onAllSpoken: () => allSpoken = true);

      queue.enqueue('Only chunk.');
      await Future<void>.delayed(Duration.zero);
      queue.markComplete();
      await Future<void>.delayed(Duration.zero);

      // Audio is still playing, so the mic must stay closed.
      expect(allSpoken, isFalse);
      expect(queue.isSpeaking, isTrue);

      tts.finishOne();
      await Future<void>.delayed(Duration.zero);
      expect(allSpoken, isTrue);
      expect(queue.isSpeaking, isFalse);
    });

    test('stays speaking between chunks so the mic cannot reopen mid-reply',
        () async {
      final tts = FakeTts();
      final queue = SpeechQueue(() => tts);
      queue.start(onAllSpoken: () {});
      queue.enqueue('One.');
      queue.enqueue('Two.');
      await Future<void>.delayed(Duration.zero);

      tts.finishOne(); // first chunk done; player briefly idle
      expect(tts.isPlaying, isFalse);
      // The reply is not over, so the queue still reports speaking.
      expect(queue.isSpeaking, isTrue);
    });

    test('completes immediately when a reply produced no chunks', () async {
      final tts = FakeTts();
      final queue = SpeechQueue(() => tts);
      var allSpoken = false;
      queue.start(onAllSpoken: () => allSpoken = true);
      queue.markComplete();
      await Future<void>.delayed(Duration.zero);
      expect(allSpoken, isTrue);
      expect(tts.spoken, isEmpty);
    });

    test('a failing chunk does not stall the rest of the reply', () async {
      final tts = _ThrowingOnceTts();
      final queue = SpeechQueue(() => tts);
      var allSpoken = false;
      queue.start(onAllSpoken: () => allSpoken = true);
      queue.enqueue('Bad.');
      queue.enqueue('Good.');
      await Future<void>.delayed(Duration.zero);
      queue.markComplete();
      await Future<void>.delayed(Duration.zero);
      tts.finishOne();
      await Future<void>.delayed(Duration.zero);

      expect(tts.spoken, ['Good.']);
      expect(allSpoken, isTrue);
    });

    test('cancel drops pending chunks and never fires completion', () async {
      final tts = FakeTts();
      final queue = SpeechQueue(() => tts);
      var allSpoken = false;
      queue.start(onAllSpoken: () => allSpoken = true);
      queue.enqueue('One.');
      queue.enqueue('Two.');
      await Future<void>.delayed(Duration.zero);

      await queue.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(tts.stopCalls, greaterThan(0));
      expect(allSpoken, isFalse);
      expect(queue.isSpeaking, isFalse);
      // "Two." was dropped rather than played after hang-up.
      expect(tts.spoken, ['One.']);
    });

    test('enqueue after markComplete is ignored', () async {
      final tts = FakeTts();
      final queue = SpeechQueue(() => tts);
      queue.start(onAllSpoken: () {});
      queue.markComplete();
      queue.enqueue('Too late.');
      await Future<void>.delayed(Duration.zero);
      expect(tts.spoken, isEmpty);
    });
  });
}

/// Throws on its first speak() call, succeeds afterwards.
class _ThrowingOnceTts extends FakeTts {
  bool _thrown = false;

  @override
  Future<void> speak(String text, {void Function()? onComplete}) async {
    if (!_thrown) {
      _thrown = true;
      throw Exception('synthesis failed');
    }
    return super.speak(text, onComplete: onComplete);
  }
}
