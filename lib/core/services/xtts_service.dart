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
import 'tts_provider.dart';
import 'tts_url.dart';

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
class XttsService implements TtsProvider {
  final http.Client _http;
  final String? fallbackHost;
  final AudioPlayer _player = AudioPlayer();

  // Notifies the owner (e.g. chat screen) when playback ends, is stopped, or
  // fails — so per-message "speaking" UI can reset. Set fresh on each speak().
  void Function()? _onComplete;
  int _speakEpoch = 0;
  bool _isPlaying = false;

  @override
  bool get isPlaying => _isPlaying;

  XttsService({http.Client? httpClient, this.fallbackHost})
      : _http = httpClient ?? http.Client() {
    _player.onPlayerComplete.listen((_) => _complete());
    _player.onPlayerStateChanged.listen((state) {
      _isPlaying = state == PlayerState.playing;
    });
  }

  // Fires the current completion callback once, then clears it. Safe to call
  // repeatedly (subsequent calls are no-ops). [epoch] gates stale callbacks:
  // if a new speak() bumped the epoch, this complete() is from a prior session
  // and is ignored — prevents the prior speak's onComplete firing after the
  // new speak has registered its own callback.
  void _complete({int? epoch}) {
    if (epoch != null && epoch != _speakEpoch) return;
    final cb = _onComplete;
    _onComplete = null;
    _isPlaying = false;
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

  static final _mdNoiseRe = RegExp(r'[*_#`>|]');

  // Phrases never spoken by TTS. Matched loosely (punctuation/case-insensitive).
  static final _blocked = <RegExp>[
    RegExp("cold\\s+coffee\\s*,?\\s*warm\\s+LO\\s*,?\\s*I\\s+can\\s*['\"]?t\\s+lose\\s+him\\s*!?", caseSensitive: false),
    RegExp(r'cold\s+coffee\s*,?\s*warm\s+LO', caseSensitive: false),
  ];

  static String _stripBlocked(String s) {
    var out = s;
    for (final re in _blocked) {
      out = out.replaceAll(re, '');
    }
    return out;
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

  /// [keepActions] retains `*asterisk*` spans instead of dropping them.
  /// Ordinary chats strip them — a stray stage direction shouldn't be read
  /// aloud. Character chats are the opposite: narration and action are half
  /// the reply and are rendered as first-class text, so silently deleting
  /// them means most of the message never gets spoken.
  static String stripForSpeech(String text, {bool keepActions = false}) {
    var s = text;
    if (keepActions) {
      // Keep the words, drop only the asterisks themselves so the narration
      // is spoken as prose rather than read out with punctuation.
      s = s.replaceAllMapped(_actionRe, (m) => m[0]!.replaceAll('*', ''));
    } else {
      s = s.replaceAll(_actionRe, ' '); // *stage directions*
    }
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

  // The settings body last successfully pushed, and the base URL it went to.
  // Used to skip a redundant round trip — see _applySettings.
  String? _lastSettingsJson;
  String? _lastSettingsBase;

  /// Pushes generation settings to `/set_tts_settings` before synthesis.
  /// Best-effort: failures don't block audio.
  ///
  /// Only sent when the body (or the server) actually changed since the last
  /// successful push. It used to go out unconditionally before *every*
  /// synthesis, which in call mode meant an extra serialized round trip per
  /// sentence chunk — pure latency in front of the audio the user is waiting
  /// for. The re-send still happens whenever the user edits anything in
  /// Settings, which is the case the always-apply behaviour existed for.
  Future<void> _applySettings(String base, SharedPreferences prefs) async {
    final body = jsonEncode(settingsBody(prefs));
    if (body == _lastSettingsJson && base == _lastSettingsBase) return;
    try {
      await _http
          .post(
            Uri.parse('$base/set_tts_settings'),
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 10));
      _lastSettingsJson = body;
      _lastSettingsBase = base;
    } catch (_) {
      // non-fatal — synthesis proceeds with whatever the server holds. Leave
      // the cache untouched so the next attempt retries the push.
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
    return resolveTtsBaseUrl(
      configured: prefs.getString(XttsPrefs.baseUrl) ?? XttsPrefs.defaultBaseUrl,
      fallbackHost: fallbackHost,
      defaultPort: 8020,
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
  /// The whole reply is narrated via [stripForSpeech] (markdown/action/media
  /// lines stripped), not just quoted dialog. Reads base URL, speaker and
  /// language from SharedPreferences each call. A null/empty speaker means no
  /// voice is configured yet — we skip rather than send an invalid request.
  /// Generation settings are pushed before synthesis if they've changed.
  @override
  Future<void> speak(
    String text, {
    void Function()? onComplete,
    bool keepActions = false,
  }) async {
    final PreparedSpeech? prepared;
    try {
      prepared = await prepare(text, keepActions: keepActions);
    } catch (e) {
      // Reset any "speaking" UI before propagating the failure.
      debugPrint('[XTTS] speak FAILED: $e');
      _complete();
      rethrow;
    }
    if (prepared == null) {
      // Nothing to narrate (stage directions only, media-only reply, blocked
      // phrase, etc.). Still signal completion so callers like the call-mode
      // controller don't stay stuck in "Speaking…" forever.
      onComplete?.call();
      return;
    }
    await speakPrepared(prepared, onComplete: onComplete);
  }

  /// Network half of [speak]: clean the text, push settings if they changed,
  /// and fetch the WAV. Does not touch the player, so a caller can run this
  /// for the next utterance while the current one is still playing.
  @override
  Future<PreparedSpeech?> prepare(
    String text, {
    bool keepActions = false,
  }) async {
    // Speak the whole cleaned reply (markdown/action-stripped), not just
    // quoted dialog — the full chat text is already sanitized upstream.
    final spoken = stripForSpeech(text, keepActions: keepActions);
    if (spoken.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final base = await _baseUrl(prefs);
    final speaker = prefs.getString(XttsPrefs.speaker) ?? '';
    final language =
        prefs.getString(XttsPrefs.language) ?? XttsPrefs.defaultLanguage;

    if (speaker.isEmpty) {
      throw Exception('No XTTS speaker selected. Pick one in Settings → Voice.');
    }

    debugPrint(
      '[XTTS] prepare: base=$base speaker="$speaker" lang=$language '
      'text=${spoken.length} chars',
    );
    await _applySettings(base, prefs);

    final sw = Stopwatch()..start();
    final res = await _http
        .post(
          Uri.parse('$base/tts_to_audio/'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'text': spoken,
            'speaker_wav': speaker,
            'language': language,
          }),
        )
        .timeout(const Duration(seconds: 45));
    sw.stop();
    debugPrint(
      '[XTTS] POST /tts_to_audio/ -> HTTP ${res.statusCode}, '
      '${res.bodyBytes.length} bytes in ${sw.elapsedMilliseconds}ms',
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('XTTS HTTP ${res.statusCode}: ${res.body}');
    }
    return PreparedSpeech(res.bodyBytes);
  }

  @override
  Future<void> speakPrepared(
    PreparedSpeech prepared, {
    void Function()? onComplete,
  }) async {
    await stop();
    final epoch = ++_speakEpoch;
    _onComplete = onComplete;
    _isPlaying = true;
    try {
      await _player.play(
        BytesSource(prepared.bytes, mimeType: prepared.mimeType),
      );
      if (epoch != _speakEpoch) {
        await _player.stop();
        return;
      }
      _isPlaying = true;
      debugPrint('[XTTS] playback started');
    } catch (e) {
      debugPrint('[XTTS] play() failed: $e');
      _complete(epoch: epoch);
      rethrow;
    }
  }

  /// Stops any in-progress playback and resets "speaking" UI.
  @override
  Future<void> stop() {
    debugPrint('[XTTS] stop()');
    final epoch = ++_speakEpoch;
    _complete(epoch: epoch);
    return _player.stop();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  void dispose() {
    _speakEpoch++;
    _onComplete = null;
    _isPlaying = false;
    _player.dispose();
    _http.close();
  }
}
