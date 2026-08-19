// Per-character TTS voice overrides. Without this every character speaks in
// the one app-wide XTTS/Chatterbox voice configured in Settings, which reads
// oddly for an app built around a character/persona picker -- a "wise old
// wizard" and a "teenage hacker" sound identical.
//
// Keyed by the character's imagePath (its stable identity throughout the
// app -- see CharacterSummary.primaryImage) AND separately by TTS backend,
// since XTTS speaker filenames and Chatterbox voice filenames are disjoint
// sets; switching the app-wide backend in Settings must not silently apply
// an XTTS speaker name as a Chatterbox voice filename or vice versa.
import 'package:shared_preferences/shared_preferences.dart';

class CharacterVoicePrefs {
  CharacterVoicePrefs._();

  static String _key(String imagePath, String provider) {
    final safe = imagePath.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return 'character_voice_${provider}_$safe';
  }

  /// The voice assigned to [imagePath] for [provider] ('xtts' or
  /// 'chatterbox'), or null if this character uses the app-wide default.
  static Future<String?> get(String imagePath, String provider) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key(imagePath, provider));
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Sets or clears (when [voice] is null/empty) the voice override.
  static Future<void> set(
    String imagePath,
    String provider,
    String? voice,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(imagePath, provider);
    if (voice == null || voice.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, voice);
    }
  }
}
