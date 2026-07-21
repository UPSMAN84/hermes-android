// Common surface for the TTS backends the app can talk to. The chat screen and
// call controller hold a [TtsProvider] and call speak/stop/dispose without
// caring whether it is XTTS-v2 or Chatterbox behind it. Which one is built is
// decided by the `tts_provider` shared-preference (see [ttsProviderForPrefs]).
import 'package:shared_preferences/shared_preferences.dart';

import 'chatterbox_service.dart';
import 'xtts_service.dart';

/// Common TTS backend interface.
abstract class TtsProvider {
  /// Synthesize [text] and play it. [onComplete] fires when playback ends, is
  /// stopped, or fails (best-effort, once).
  Future<void> speak(String text, {void Function()? onComplete});

  /// Stop any in-progress playback.
  Future<void> stop();

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
Future<TtsProvider> ttsProviderForPrefs(SharedPreferences prefs) {
  final provider = prefs.getString(ttsProviderPrefKey) ?? 'xtts';
  return Future.value(
    provider == 'chatterbox' ? ChatterboxService() : XttsService(),
  );
}
