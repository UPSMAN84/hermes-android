// Text-to-speech backed by a self-hosted Chatterbox server (Chatterbox
// Multilingual TTS, FastAPI). Replaces per-speak voice uploads with a filename
// picked from the server's fixed `voices/` folder. Text is POSTed as multipart
// form to POST /tts; the server returns a WAV we play locally with
// audioplayers. Voice + language + generation params persist in
// SharedPreferences (see [ChatterboxPrefs]).
import 'dart:async';
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

  // Single generation counter spanning the whole speak/prepare/play
  // lifecycle -- see XttsService's matching field for the full rationale
  // (stop() must invalidate synthesis that's still in flight, not just
  // playback that's already started).
  int _opEpoch = 0;
  bool _isPlaying = false;

  // Signaled by stop() to abort a pending prepare() network call -- see
  // XttsService's matching field for the full rationale.
  Completer<Never>? _cancelSignal;

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
    if (epoch != null && epoch != _opEpoch) return;
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
  Future<void> speak(
    String text, {
    void Function()? onComplete,
    bool keepActions = false,
    String? voiceOverride,
  }) async {
    // Claim this operation's generation *before* the network round trip --
    // see XttsService.speak for the full rationale.
    final epoch = ++_opEpoch;
    final PreparedSpeech? prepared;
    try {
      prepared = await prepare(
        text,
        keepActions: keepActions,
        voiceOverride: voiceOverride,
      );
    } catch (e) {
      if (epoch != _opEpoch) {
        // stop() closed the in-flight request's client (or a newer speak()
        // superseded this one) -- an intentional interruption, not a real
        // failure. Fire onComplete like any other stop so the caller's
        // "speaking" UI clears, but don't surface an error for it.
        debugPrint('[Chatterbox] speak: synthesis aborted by stop()/supersede: $e');
        onComplete?.call();
        return;
      }
      debugPrint('[Chatterbox] speak FAILED: $e');
      _complete();
      rethrow;
    }
    if (epoch != _opEpoch) {
      // stop() (or a newer speak()) arrived while synthesis was in flight --
      // this reply is obsolete, drop it instead of playing it late. Still
      // fire onComplete (matches "stopped" in the documented contract) so
      // the caller's "speaking" UI doesn't stay stuck forever.
      debugPrint('[Chatterbox] speak: discarding stale synthesis (stopped/superseded)');
      onComplete?.call();
      return;
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

  /// Network half of [speak] — see [TtsProvider.prepare]. Kept separate so the
  /// call-mode speech queue can synthesize the next sentence while the current
  /// one is still playing instead of leaving dead air at every boundary.
  @override
  Future<PreparedSpeech?> prepare(
    String text, {
    bool keepActions = false,
    String? voiceOverride,
  }) async {
    // Reuse the XTTS text cleaning, but speak the whole cleaned reply — not
    // just quoted dialog.
    final spoken = XttsService.stripForSpeech(text, keepActions: keepActions);
    if (spoken.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final base = await _baseUrl(prefs);
    final voice =
        (voiceOverride?.isNotEmpty ?? false)
        ? voiceOverride!
        : prefs.getString(ChatterboxPrefs.voice) ?? '';
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

    // Race the request against stop()'s cancel signal so a Stop press aborts
    // this prepare() promptly instead of waiting out the full timeout.
    final cancel = Completer<Never>();
    _cancelSignal = cancel;
    try {
      final (statusCode, bytes) = await Future.any<(int, Uint8List)>([
        _sendMultipart(request),
        cancel.future,
      ]);
      debugPrint('[Chatterbox] POST /tts -> HTTP $statusCode, ${bytes.length} bytes');
      if (statusCode < 200 || statusCode >= 300) {
        throw Exception('Chatterbox HTTP $statusCode: ${String.fromCharCodes(bytes)}');
      }
      return PreparedSpeech(bytes);
    } finally {
      if (identical(_cancelSignal, cancel)) _cancelSignal = null;
    }
  }

  /// Sends [request] on the shared client and collects the full body.
  Future<(int, Uint8List)> _sendMultipart(http.MultipartRequest request) async {
    final streamed = await _http.send(request).timeout(const Duration(seconds: 45));
    final bytes = await streamed.stream.toBytes().timeout(const Duration(seconds: 45));
    return (streamed.statusCode, Uint8List.fromList(bytes));
  }

  @override
  Future<void> speakPrepared(
    PreparedSpeech prepared, {
    void Function()? onComplete,
  }) async {
    await stop();
    final epoch = ++_opEpoch;
    _onComplete = onComplete;
    _isPlaying = true;
    try {
      await _player.play(
        BytesSource(prepared.bytes, mimeType: prepared.mimeType),
      );
      if (epoch != _opEpoch) {
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
  }

  @override
  Future<void> stop() {
    debugPrint('[Chatterbox] stop()');
    final epoch = ++_opEpoch;
    _cancelSignal?.completeError(const _SynthesisCancelled());
    _cancelSignal = null;
    _complete(epoch: epoch);
    return _player.stop();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  void dispose() {
    _opEpoch++;
    _cancelSignal?.completeError(const _SynthesisCancelled());
    _cancelSignal = null;
    _onComplete = null;
    _isPlaying = false;
    _player.dispose();
    _http.close();
  }
}

/// Thrown into the in-flight [Future.any] race in [ChatterboxService.prepare]
/// when [ChatterboxService.stop] (or [ChatterboxService.dispose]) fires while
/// a synthesis request is still pending, so the caller unwinds immediately
/// instead of waiting out the request's full timeout.
class _SynthesisCancelled implements Exception {
  const _SynthesisCancelled();

  @override
  String toString() => 'Chatterbox synthesis cancelled by stop()';
}
