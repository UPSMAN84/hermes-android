// Text-to-speech backed by a self-hosted Chatterbox server (Chatterbox
// Multilingual TTS, FastAPI). Replaces per-speak voice uploads with a filename
// picked from the server's fixed `voices/` folder. Text is POSTed as multipart
// form to POST /tts; the server returns a WAV we play locally with
// audioplayers. Voice + language + generation params persist in
// SharedPreferences (see [ChatterboxPrefs]).
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'tts_provider.dart';
import 'xtts_service.dart';
import 'tts_url.dart';

/// Persisted-preference keys for the Chatterbox backend.
class ChatterboxPrefs {
  static const baseUrl = 'chatterbox_base_url';
  static const voice = 'chatterbox_voice';
  static const languageId = 'chatterbox_language_id';
  static const cfgWeight = 'chatterbox_cfg_weight';
  static const exaggeration = 'chatterbox_exaggeration';

  /// Server model: 'v3' (multilingual, default) or 'turbo' (English-only,
  /// ignores cfg_weight/exaggeration/language_id server-side).
  static const model = 'chatterbox_model';

  // Turbo-only sampling params (Turbo ignores cfg_weight/exaggeration/
  // language_id but reads these instead).
  static const repetitionPenalty = 'chatterbox_repetition_penalty';
  static const minP = 'chatterbox_min_p';
  static const topP = 'chatterbox_top_p';
  static const temperature = 'chatterbox_temperature';
  static const topK = 'chatterbox_top_k';

  /// Local server bind; override in Settings with a LAN/Tailscale address
  /// reachable from the phone.
  static const defaultBaseUrl = 'http://0.0.0.0:8420';
  static const defaultLanguage = 'en';
  static const defaultCfgWeight = 0.5;
  static const defaultExaggeration = 0.5;
  static const defaultModel = 'v3';
  static const defaultRepetitionPenalty = 1.2;
  static const defaultMinP = 0.0;
  static const defaultTopP = 0.95;
  static const defaultTemperature = 0.8;
  static const defaultTopK = 1000;
}

/// Speaks assistant replies through the Chatterbox server.
///
/// One instance per screen that needs playback. Call [dispose] to release the
/// audio player. All config is read fresh from SharedPreferences on each
/// [speak] so Settings changes take effect without recreating the service.
class ChatterboxService implements TtsProvider {
  final http.Client _http;
  final String? fallbackHost;
  final AudioPlayer _player = AudioPlayer();

  // Completion callback (same contract as XttsService): fires once on natural
  // end, stop, or failure so "speaking" UI can reset.
  void Function()? _onComplete;
  int _speakEpoch = 0;
  bool _isPlaying = false;

  @override
  bool get isPlaying => _isPlaying;

  ChatterboxService({http.Client? httpClient, this.fallbackHost})
      : _http = httpClient ?? http.Client() {
    _player.onPlayerComplete.listen((_) => _complete());
    _player.onPlayerStateChanged.listen((state) {
      _isPlaying = state == PlayerState.playing;
    });
  }

  // [epoch] gates stale callbacks: if a new speak() bumped the epoch, this
  // complete() is from a prior session and is ignored — prevents the prior
  // speak's onComplete firing after the new speak has registered its own.
  void _complete({int? epoch}) {
    if (epoch != null && epoch != _speakEpoch) return;
    final cb = _onComplete;
    _onComplete = null;
    _isPlaying = false;
    if (cb != null) cb();
  }

  /// Normalises a user-entered base URL: trims, adds http:// if no scheme,
  /// strips a trailing slash.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return ChatterboxPrefs.defaultBaseUrl;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    return url;
  }

  Future<String> _baseUrl(SharedPreferences prefs) {
    return Future.value(
      resolveTtsBaseUrl(
        configured: prefs.getString(ChatterboxPrefs.baseUrl) ?? ChatterboxPrefs.defaultBaseUrl,
        fallbackHost: fallbackHost,
        defaultPort: 8420,
      ),
    );
  }

  /// Fetch the voice filenames the server offers (`GET /voices`).
  Future<List<String>> getVoices({String? baseUrlOverride}) async {
    final prefs = await SharedPreferences.getInstance();
    final base = baseUrlOverride != null
        ? normalizeBaseUrl(baseUrlOverride)
        : await _baseUrl(prefs);
    final res = await _http
        .get(Uri.parse('$base/voices'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body);
    final voices = decoded is Map ? decoded['voices'] : decoded;
    if (voices is! List) return [];
    return voices.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  @override
  Future<void> speak(String text, {void Function()? onComplete}) async {
    // Reuse the XTTS text cleaning, but speak the whole cleaned reply — not
    // just quoted dialog.
    final spoken = XttsService.stripForSpeech(text);
    if (spoken.isEmpty) {
      // Nothing to narrate (stage directions only, media-only reply, blocked
      // phrase, etc.). Still signal completion so callers like the call-mode
      // controller don't stay stuck in "Speaking…" forever.
      onComplete?.call();
      return;
    }

    await stop();
    final epoch = ++_speakEpoch;
    _onComplete = onComplete;
    _isPlaying = true;

    final prefs = await SharedPreferences.getInstance();
    if (epoch != _speakEpoch) return;
    final base = await _baseUrl(prefs);
    final voice = prefs.getString(ChatterboxPrefs.voice) ?? '';
    final language =
        prefs.getString(ChatterboxPrefs.languageId) ??
            ChatterboxPrefs.defaultLanguage;
    final cfgWeight =
        prefs.getDouble(ChatterboxPrefs.cfgWeight) ??
            ChatterboxPrefs.defaultCfgWeight;
    final exaggeration =
        prefs.getDouble(ChatterboxPrefs.exaggeration) ??
            ChatterboxPrefs.defaultExaggeration;
    final model =
        prefs.getString(ChatterboxPrefs.model) ?? ChatterboxPrefs.defaultModel;
    final isTurbo = model == 'turbo';
    final repetitionPenalty =
        prefs.getDouble(ChatterboxPrefs.repetitionPenalty) ??
            ChatterboxPrefs.defaultRepetitionPenalty;
    final minP =
        prefs.getDouble(ChatterboxPrefs.minP) ?? ChatterboxPrefs.defaultMinP;
    final topP =
        prefs.getDouble(ChatterboxPrefs.topP) ?? ChatterboxPrefs.defaultTopP;
    final temperature =
        prefs.getDouble(ChatterboxPrefs.temperature) ??
            ChatterboxPrefs.defaultTemperature;
    final topK =
        prefs.getInt(ChatterboxPrefs.topK) ?? ChatterboxPrefs.defaultTopK;

    debugPrint(
      '[Chatterbox] speak: base=$base model=$model voice="$voice" lang=$language '
      'cfg=$cfgWeight exag=$exaggeration text=${spoken.length} chars',
    );

    final request = http.MultipartRequest('POST', Uri.parse('$base/tts'))
      ..fields['text'] = spoken
      ..fields['model'] = model;
    // Turbo is English-only and ignores cfg_weight/exaggeration/language_id
    // server-side; it reads its own sampling params instead.
    if (isTurbo) {
      request.fields['repetition_penalty'] = repetitionPenalty.toString();
      request.fields['min_p'] = minP.toString();
      request.fields['top_p'] = topP.toString();
      request.fields['temperature'] = temperature.toString();
      request.fields['top_k'] = topK.toString();
    } else {
      request.fields['language_id'] = language;
      request.fields['cfg_weight'] = cfgWeight.toString();
      request.fields['exaggeration'] = exaggeration.toString();
    }
    if (voice.isNotEmpty) request.fields['voice'] = voice;

    try {
      final streamed = await request.send().timeout(
        const Duration(seconds: 45),
      );
      if (epoch != _speakEpoch) return;
      final bytes = await streamed.stream.toBytes().timeout(
        const Duration(seconds: 45),
      );
      if (epoch != _speakEpoch) return;
      debugPrint(
        '[Chatterbox] POST /tts -> HTTP ${streamed.statusCode}, '
        '${bytes.length} bytes',
      );
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw Exception(
          'Chatterbox HTTP ${streamed.statusCode}: ${String.fromCharCodes(bytes)}',
        );
      }

      await _player.stop();
      if (epoch != _speakEpoch) return;
      try {
        await _player.play(
          BytesSource(Uint8List.fromList(bytes), mimeType: 'audio/wav'),
        );
        if (epoch != _speakEpoch) {
          await _player.stop();
          return;
        }
        _isPlaying = true;
        debugPrint('[Chatterbox] playback started');
      } catch (e) {
        debugPrint('[Chatterbox] play() failed: $e');
        _complete(epoch: epoch);
        rethrow;
      }
    } catch (e) {
      if (epoch != _speakEpoch) return;
      debugPrint('[Chatterbox] speak FAILED: $e');
      _complete(epoch: epoch);
      rethrow;
    }
  }

  @override
  Future<void> stop() {
    debugPrint('[Chatterbox] stop()');
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
