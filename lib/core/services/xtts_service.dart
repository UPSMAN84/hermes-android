// Text-to-speech backed by an XTTS-v2 API server (daswer123/xtts-api-server).
//
// Replaces the on-device flutter_tts engine: assistant text is POSTed to the
// server's /tts_to_audio/ endpoint, which returns a WAV we play locally with
// audioplayers. Speaker + language selection persist in SharedPreferences.
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// Persisted-preference keys shared with the settings voice picker.
class XttsPrefs {
  static const baseUrl = 'xtts_base_url';
  static const speaker = 'xtts_speaker';
  static const language = 'xtts_language';

  // Generation params (POST /set_tts_settings). Null = "let the server keep its
  // current value" — we only send keys the user has set.
  static const temperature = 'xtts_temperature';
  static const lengthPenalty = 'xtts_length_penalty';
  static const repetitionPenalty = 'xtts_repetition_penalty';
  static const topP = 'xtts_top_p';
  static const topK = 'xtts_top_k';

  /// Sensible default: the local server bind address. Users can override it in
  /// Settings (e.g. a Tailscale hostname or LAN IP reachable from the phone).
  static const defaultBaseUrl = 'http://0.0.0.0:8020';
  static const defaultLanguage = 'en';
}

/// Speaks assistant replies through the XTTS-v2 server.
///
/// One instance per screen that needs playback. Call [dispose] to release the
/// audio player. All config is read fresh from SharedPreferences on each
/// [speak] so changes in Settings take effect without recreating the service.
class XttsService {
  final http.Client _http;
  final AudioPlayer _player = AudioPlayer();

  // Notifies the owner (e.g. chat screen) when playback ends, is stopped, or
  // fails — so per-message "speaking" UI can reset. Set fresh on each speak().
  void Function()? _onComplete;

  XttsService({http.Client? httpClient}) : _http = httpClient ?? http.Client() {
    _player.onPlayerComplete.listen((_) => _complete());
  }

  // Fires the current completion callback once, then clears it. Safe to call
  // repeatedly (subsequent calls are no-ops).
  void _complete() {
    final cb = _onComplete;
    _onComplete = null;
    if (cb != null) cb();
  }

  /// Server-side defaults for params the user hasn't overridden. The XTTS
  /// `/set_tts_settings` model requires every field, so we always send a
  /// complete body, substituting these for unset values.
  static const _defaultSettings = <String, Object>{
    'stream_chunk_size': 100,
    'temperature': 0.75,
    'speed': 1.0,
    'length_penalty': 1.0,
    'repetition_penalty': 5.0,
    'top_p': 0.85,
    'top_k': 50,
    'enable_text_splitting': true,
  };

  /// Extracts only the spoken dialog from an assistant reply: text inside
  /// double quotes (straight " or curly “ ”). Actions, narration, stage
  /// directions and media/file paths live outside quotes and are skipped.
  /// Leftover markdown emphasis inside the quotes is stripped, and the ENI
  /// rebuttal mantra is always removed (it gets quoted often but is never
  /// meant to be spoken aloud).
  static final _quoteRe = RegExp(
    r'"([^"]+)"|“([^”]+)”',
  );
  static final _mdNoiseRe = RegExp(r'[*_#`>|]');

  // Phrases never spoken by TTS. Matched loosely (punctuation/case-insensitive).
  static final _blocked = <RegExp>[
    RegExp(r'cold\s+coffee\s*,?\s*warm\s+LO\s*,?\s*I\s+can\s*[''"]?t\s+lose\s+him\s*!?', caseSensitive: false),
    RegExp(r'cold\s+coffee\s*,?\s*warm\s+LO', caseSensitive: false),
  ];

  static String _stripBlocked(String s) {
    var out = s;
    for (final re in _blocked) {
      out = out.replaceAll(re, '');
    }
    return out;
  }

  static String extractDialog(String text) {
    final parts = <String>[];
    for (final m in _quoteRe.allMatches(text)) {
      var raw = (m.group(1) ?? m.group(2) ?? '').trim();
      if (raw.isEmpty) continue;
      raw = _stripBlocked(raw);
      final cleaned = raw
          .replaceAll(_mdNoiseRe, '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleaned.isNotEmpty) parts.add(cleaned);
    }
    return parts.join(' ');
  }

  // Strips markdown emphasis / stage directions / code (file paths, URLs) and
  // whole lines that look like media output, used as a fallback when the reply
  // contains no quoted dialog so TTS isn't fully silenced.
  static final _actionRe = RegExp(r'\*[^*\n]+\*');
  static final _inlineCodeRe = RegExp(r'`[^`\n]*`');
  static final _mediaLineRe = RegExp(
    r'([\\/]:|output[\\/]|\.png|\.jpe?g|\.webp|\.mp4|\.webm|\.mov|https?://|prompt_id=)',
    caseSensitive: false,
  );

  static String stripForSpeech(String text) {
    var s = text;
    s = s.replaceAll(_actionRe, ' '); // *stage directions*
    s = s.replaceAll(_inlineCodeRe, ' '); // `C:\...\file.png`, URLs
    s = s.replaceAll(_mdNoiseRe, ' '); // leftover markdown chars
    // Drop lines that are clearly file paths / media output / links.
    final kept = <String>[];
    for (final line in s.split('\n')) {
      if (line.trim().isEmpty) continue;
      if (_mediaLineRe.hasMatch(line)) continue;
      kept.add(line);
    }
    s = kept.join(' ');
    s = _stripBlocked(s);
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// Builds the full `/set_tts_settings` body: user-overridden values win,
  /// everything else falls back to [_defaultSettings].
  static Map<String, Object> settingsBody(SharedPreferences prefs) {
    final body = Map<String, Object>.from(_defaultSettings);
    final temp = prefs.getDouble(XttsPrefs.temperature);
    if (temp != null) body['temperature'] = temp;
    final lp = prefs.getDouble(XttsPrefs.lengthPenalty);
    if (lp != null) body['length_penalty'] = lp;
    final rp = prefs.getDouble(XttsPrefs.repetitionPenalty);
    if (rp != null) body['repetition_penalty'] = rp;
    final tp = prefs.getDouble(XttsPrefs.topP);
    if (tp != null) body['top_p'] = tp;
    final tk = prefs.getInt(XttsPrefs.topK);
    if (tk != null) body['top_k'] = tk;
    return body;
  }

  /// Pushes generation settings to `/set_tts_settings` before each synthesis.
  /// Best-effort: failures don't block audio. Always-applied so user overrides
  /// win even if another client (desktop) changes them mid-session.
  Future<void> _applySettings(String base, SharedPreferences prefs) async {
    try {
      await _http
          .post(
            Uri.parse('$base/set_tts_settings'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(settingsBody(prefs)),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // non-fatal — synthesis proceeds with whatever the server holds
    }
  }

  /// Normalises a user-entered base URL: trims, adds http:// if no scheme,
  /// and strips a trailing slash so endpoint joins are clean.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return XttsPrefs.defaultBaseUrl;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    return url;
  }

  Future<String> _baseUrl(SharedPreferences prefs) async {
    return normalizeBaseUrl(
      prefs.getString(XttsPrefs.baseUrl) ?? XttsPrefs.defaultBaseUrl,
    );
  }

  /// Fetches the list of speaker names from `GET /speakers`.
  ///
  /// The server returns `[{name, voice_id, preview_url}, ...]`; we surface the
  /// `name`, which is what `/tts_to_audio/` expects as `speaker_wav`.
  Future<List<String>> getSpeakers({String? baseUrlOverride}) async {
    final prefs = await SharedPreferences.getInstance();
    final base = baseUrlOverride != null
        ? normalizeBaseUrl(baseUrlOverride)
        : await _baseUrl(prefs);
    final res = await _http
        .get(Uri.parse('$base/speakers'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((m) => (m['name'] ?? m['voice_id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Fetches supported language codes from `GET /languages`.
  Future<List<String>> getLanguages({String? baseUrlOverride}) async {
    final prefs = await SharedPreferences.getInstance();
    final base = baseUrlOverride != null
        ? normalizeBaseUrl(baseUrlOverride)
        : await _baseUrl(prefs);
    final res = await _http
        .get(Uri.parse('$base/languages'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body);
    final langs = decoded is Map ? decoded['languages'] : decoded;
    if (langs is! List) return [];
    return langs.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  /// Synthesizes [text] on the server and plays the returned WAV.
  ///
  /// Only the quoted spoken dialog is narrated (see [extractDialog]); actions,
  /// narration and media/file paths are skipped. Reads base URL, speaker and
  /// language from SharedPreferences each call. A null/empty speaker means no
  /// voice is configured yet — we skip rather than send an invalid request.
  /// Generation settings are pushed before synthesis if they've changed.
  Future<void> speak(String text, {void Function()? onComplete}) async {
    // Prefer quoted dialog; fall back to the action-stripped reply so a reply
    // with no quotes still speaks (instead of going silent).
    final dialog = extractDialog(text);
    final spoken = dialog.isNotEmpty ? dialog : stripForSpeech(text);
    if (spoken.isEmpty) return;

    _onComplete = onComplete;

    final prefs = await SharedPreferences.getInstance();
    final base = await _baseUrl(prefs);
    final speaker = prefs.getString(XttsPrefs.speaker) ?? '';
    final language =
        prefs.getString(XttsPrefs.language) ?? XttsPrefs.defaultLanguage;

    if (speaker.isEmpty) {
      throw Exception('No XTTS speaker selected. Pick one in Settings → Voice.');
    }

    debugPrint(
      '[XTTS] speak: base=$base speaker="$speaker" lang=$language '
      'text=${spoken.length} chars',
    );
    await _applySettings(base, prefs);

    final sw = Stopwatch()..start();
    try {
      final res = await _http.post(
        Uri.parse('$base/tts_to_audio/'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': spoken,
          'speaker_wav': speaker,
          'language': language,
        }),
      );
      sw.stop();
      debugPrint(
        '[XTTS] POST /tts_to_audio/ -> HTTP ${res.statusCode}, '
        '${res.bodyBytes.length} bytes in ${sw.elapsedMilliseconds}ms',
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('XTTS HTTP ${res.statusCode}: ${res.body}');
      }

      await _player.stop();
      await _player.play(BytesSource(res.bodyBytes, mimeType: 'audio/wav'));
      debugPrint('[XTTS] playback started');
    } catch (e) {
      // Reset any "speaking" UI before propagating the failure.
      debugPrint('[XTTS] speak FAILED: $e');
      _complete();
      rethrow;
    }
  }

  /// Stops any in-progress playback and resets "speaking" UI.
  Future<void> stop() {
    debugPrint('[XTTS] stop()');
    _complete();
    return _player.stop();
  }

  void dispose() {
    _player.dispose();
    _http.close();
  }
}
