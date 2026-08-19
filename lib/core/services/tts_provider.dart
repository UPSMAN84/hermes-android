// Common surface for the TTS backends the app can talk to. The chat screen and
// call controller hold a [TtsProvider] and call speak/stop/dispose without
// caring whether it is XTTS-v2 or Chatterbox behind it. Which one is built is
// decided by the `tts_provider` shared-preference (see [ttsProviderForPrefs]).
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'chatterbox_service.dart';
import 'xtts_service.dart';

/// Audio synthesized ahead of the moment it is needed.
///
/// Exists so a caller can overlap synthesis with playback: [TtsProvider.speak]
/// is synthesize-then-play in one blocking call, which forced a strictly
/// serial pipeline — every sentence boundary in a streaming reply cost a full
/// synthesis round trip of silence. [TtsProvider.prepare] does only the
/// network half, and [TtsProvider.speakPrepared] plays the result.
class PreparedSpeech {
  const PreparedSpeech(this.bytes, {this.mimeType = 'audio/wav'});

  final Uint8List bytes;
  final String mimeType;
}

/// Common TTS backend interface.
abstract class TtsProvider {
  /// Synthesize [text] and play it. [onComplete] fires when playback ends, is
  /// stopped, or fails (best-effort, once).
  ///
  /// [keepActions] speaks `*narration*` instead of stripping it — set in
  /// character chats, where actions are half the reply rather than a stray
  /// stage direction. See XttsService.stripForSpeech.
  ///
  /// [voiceOverride] picks a specific speaker/voice (XTTS speaker filename or
  /// Chatterbox voice filename, matching whichever backend this instance is)
  /// instead of the app-wide one configured in Settings — used for a
  /// per-character voice. Null/empty falls back to the global setting.
  Future<void> speak(
    String text, {
    void Function()? onComplete,
    bool keepActions = false,
    String? voiceOverride,
  });

  /// Synthesize [text] without playing it. Returns null when there is nothing
  /// speakable left after cleaning (stage directions only, media-only reply,
  /// blocked phrase). Throws on a synthesis failure, same as [speak].
  ///
  /// Callers that need low latency across several utterances should prepare
  /// the next one while the current one is playing.
  Future<PreparedSpeech?> prepare(
    String text, {
    bool keepActions = false,
    String? voiceOverride,
  });

  /// Play audio already synthesized by [prepare]. Stops anything currently
  /// playing first, exactly like [speak].
  Future<void> speakPrepared(
    PreparedSpeech prepared, {
    void Function()? onComplete,
  });

  /// Stop any in-progress playback.
  Future<void> stop();

  Future<void> pause();
  Future<void> resume();

  /// True while audio is playing. Used by callers to gate mic input — if the
  /// recognizer captures the TTS output as a "turn" the user gets a garbage
  /// reply. May briefly report true during synthesis before playback starts.
  bool get isPlaying;

  /// Release resources.
  void dispose();
}

/// Shared-preference key selecting the active TTS backend.
const String ttsProviderPrefKey = 'tts_provider';

/// Build the TTS backend selected in [prefs]. Defaults to XTTS-v2 so existing
/// setups are unchanged.
Future<TtsProvider> ttsProviderForPrefs(
  SharedPreferences prefs, {
  String? fallbackHost,
}) {
  final provider = prefs.getString(ttsProviderPrefKey) ?? 'xtts';
  return Future.value(
    provider == 'chatterbox'
        ? ChatterboxService(fallbackHost: fallbackHost)
        : XttsService(fallbackHost: fallbackHost),
  );
}
