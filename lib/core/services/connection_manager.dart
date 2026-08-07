// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/connection.dart';
import '../models/session.dart';

// Re-export for convenience
export '../models/connection.dart';
export '../models/session.dart';

/// Manages saved remote connections using SharedPreferences.
class ConnectionManager {
  static const String _key = 'saved_connections';
  static const Uuid _uuid = Uuid();
  final SharedPreferences prefs;

  ConnectionManager(this.prefs);

  List<SavedConnection> getConnections() {
    final jsonList = prefs.getStringList(_key) ?? [];
    final connections = <SavedConnection>[];
    for (final j in jsonList) {
      try {
        final map = jsonDecode(j) as Map<String, dynamic>;
        connections.add(SavedConnection.fromMap(map));
      } catch (e) {
        // One corrupted/legacy stored entry must not take down the whole
        // list -- callers (e.g. the home screen's connection picker) have no
        // try/catch around this call, so skip it rather than throw.
        debugPrint('[ConnectionManager] skipping malformed saved connection: $e');
      }
    }
    return connections;
  }

  void saveConnection(
    String label,
    String host,
    int port,
    String apiKey, {
    String? gatewayPrefix,
    String? dashboardPrefix,
    bool dashboardProxied = false,
    int? dashboardPort,
    String? dashboardUsername,
    String? dashboardPassword,
  }) {
    final normalized = SavedConnection.normalizeHostAndPort(host, port);
    final conn = SavedConnection(
      id: _uuid.v4(),
      label: label,
      host: normalized.host,
      port: normalized.port,
      apiKey: apiKey,
      useHttps: normalized.useHttps,
      gatewayPrefix: gatewayPrefix,
      dashboardPrefix: dashboardPrefix,
      dashboardProxied: dashboardProxied,
      dashboardPortOverride: dashboardPort,
      dashboardUsername: dashboardUsername,
      dashboardPassword: dashboardPassword,
    );
    final current = getConnections();
    current.insert(0, conn);
    _saveAll(current);
  }

  /// Updates the dashboard port + basic-auth credentials on an existing
  /// connection. Empty strings clear the corresponding field.
  void updateDashboardAuth(
    String connId, {
    int? dashboardPort,
    required String username,
    required String password,
    String? gatewayPrefix,
    String? dashboardPrefix,
    bool? dashboardProxied,
  }) {
    final current = getConnections();
    final idx = current.indexWhere((c) => c.id == connId);
    if (idx < 0) return;
    final u = username.trim();
    final p = password.trim();
    final gateway = gatewayPrefix?.trim();
    final dashboard = dashboardPrefix?.trim();
    current[idx] = current[idx].copyWith(
      gatewayPrefix: gateway == null || gateway.isEmpty ? null : gateway,
      clearGatewayPrefix: gateway != null && gateway.isEmpty,
      dashboardPrefix: dashboard == null || dashboard.isEmpty
          ? null
          : dashboard,
      clearDashboardPrefix: dashboard != null && dashboard.isEmpty,
      dashboardProxied: dashboardProxied,
      dashboardPortOverride: dashboardPort,
      clearDashboardPort: dashboardPort == null,
      dashboardUsername: u.isEmpty ? null : u,
      clearDashboardUsername: u.isEmpty,
      dashboardPassword: p.isEmpty ? null : p,
      clearDashboardPassword: p.isEmpty,
    );
    _saveAll(current);
  }

  void updateApiKey(String connId, String apiKey) {
    final current = getConnections();
    final idx = current.indexWhere((c) => c.id == connId);
    if (idx < 0) return;
    current[idx] = current[idx].copyWith(apiKey: apiKey);
    _saveAll(current);
  }

  void deleteConnection(String id) {
    final current = getConnections();
    current.removeWhere((c) => c.id == id);
    _saveAll(current);
  }

  void _saveAll(List<SavedConnection> list) {
    prefs.setStringList(_key, list.map((c) => jsonEncode(c.toMap())).toList());
  }
}

/// HTTP client for the Hermes Gateway API Server (port 8642).
///
/// Uses Bearer token auth. Same pattern as hermes-desktop.
class ApiClient {
  final http.Client _http;
  final String baseUrl;
  final String _apiKey;

  // Keep the public parameter name `apiKey` while storing it privately.
  ApiClient({
    required String baseUrl,
    required String apiKey,
    String pathPrefix = '',
    http.Client? httpClient,
  }) : _apiKey = apiKey,
       baseUrl = SavedConnection.joinBaseUrl(baseUrl, pathPrefix),
       _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_apiKey',
    'Content-Type': 'application/json',
  };

  // ── Session listing ──────────────────────────────────────────────────

  Future<List<Session>> getSessions() async {
    final res = await _http.get(
      Uri.parse('$baseUrl/api/sessions'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = data['data'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((s) => Session.fromJson(s))
        .toList();
  }

  // ── Messages ─────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getMessages(String sessionId) async {
    final res = await _http.get(
      Uri.parse('$baseUrl/api/sessions/$sessionId/messages'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = data['data'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  Future<void> deleteSession(String sessionId) async {
    final encodedId = Uri.encodeComponent(sessionId);
    final res = await _http.delete(
      Uri.parse('$baseUrl/api/sessions/$encodedId'),
      headers: _headers,
    );
    // Treat a stale local row as already synced: the remote no longer has it,
    // so the UI can safely remove it from history.
    if (res.statusCode == 404) return;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
  }

  // ── Health check ─────────────────────────────────────────────────────

  Future<bool> healthCheck() async {
    try {
      final health = await _http
          .get(Uri.parse('$baseUrl/health'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (health.statusCode == 401 || health.statusCode == 403) return false;
      if (health.statusCode != 200) return false;

      // /health may be intentionally public on some deployments. Confirm that
      // the saved API key can also reach an authenticated endpoint before the
      // add/update connection dialogs accept it as valid.
      final sessions = await _http
          .get(Uri.parse('$baseUrl/api/sessions'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      return sessions.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void close() => _http.close();
}

typedef ToolProgressCallback = void Function(Map<String, dynamic> progress);

/// SSE streaming chat client for the Gateway API Server.
/// A chat message's `content` split into plain text and any image URLs.
/// `content` is either a plain String, or an OpenAI-style multimodal list
/// of `{type: "text", text: ...}` / `{type: "image_url", image_url: {url}}`
/// parts (what a message with an attached image round-trips as once the
/// gateway persists and returns it).
class MessageContent {
  final String text;
  final List<String> imageUrls;
  const MessageContent(this.text, this.imageUrls);
}

MessageContent parseMessageContent(dynamic content) {
  if (content is String) return MessageContent(content, const []);
  if (content is List) {
    final textParts = <String>[];
    final images = <String>[];
    for (final part in content) {
      if (part is! Map) continue;
      final type = part['type'];
      if (type == 'text') {
        final t = part['text']?.toString() ?? '';
        if (t.isNotEmpty) textParts.add(t);
      } else if (type == 'image_url' || type == 'input_image') {
        final imageUrl = part['image_url'];
        final url = imageUrl is Map
            ? imageUrl['url']?.toString()
            : imageUrl?.toString();
        if (url != null && url.isNotEmpty) images.add(url);
      }
    }
    return MessageContent(textParts.join('\n'), images);
  }
  return MessageContent(content?.toString() ?? '', const []);
}

class GatewayChatClient {
  final ApiClient _api;
  final String _baseUrl;

  GatewayChatClient(this._api) : _baseUrl = _api.baseUrl;

  /// Generate a client-side session ID: `mob-<timestamp>-<uuid>`.
  static String generateSessionId() {
    return 'mob-${DateTime.now().millisecondsSinceEpoch}-${const Uuid().v4()}';
  }

  /// Build OpenAI chat-completions messages, preserving prior history and
  /// ensuring the newly typed user message is present exactly once at the end.
  ///
  /// Unknown roles (e.g. 'tool') are skipped — silently rewriting them to
  /// 'user' would feed the model the raw tool output as if the user had
  /// typed it, corrupting subsequent replies.
  static List<Map<String, dynamic>> buildChatCompletionMessages({
    required String message,
    List<Map<String, dynamic>>? history,
    // data: URLs (base64-encoded) for images attached to the message being
    // sent right now. When non-empty, the latest user message becomes
    // OpenAI-style multimodal content (a list of text/image_url parts)
    // instead of a plain string. Only the *current* turn carries images —
    // when continuing a session (X-Hermes-Session-Id set) the gateway
    // reloads history from its own DB and ignores this `history` list
    // entirely, so there's no need to re-serialize past images here.
    List<String>? imageDataUrls,
  }) {
    final messages = <Map<String, dynamic>>[];
    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        final rawRole = msg['role'];
        if (rawRole != 'user' &&
            rawRole != 'assistant' &&
            rawRole != 'agent') {
          continue;
        }
        // Prior multimodal messages are represented as a List in local
        // state; only plain text is meaningful in the (server-ignored)
        // history payload, so anything else is skipped here.
        final rawContent = msg['content'];
        if (rawContent is! String) continue;
        final content = rawContent.trim();
        if (content.isEmpty) continue;
        messages.add({
          'role': rawRole == 'agent' ? 'assistant' : rawRole,
          'content': content,
        });
      }
    }

    final latest = message.trim();
    final alreadyLast =
        messages.isNotEmpty &&
        messages.last['role'] == 'user' &&
        messages.last['content'] == latest;
    if (imageDataUrls != null && imageDataUrls.isNotEmpty) {
      final parts = <Map<String, dynamic>>[];
      if (latest.isNotEmpty) parts.add({'type': 'text', 'text': latest});
      for (final url in imageDataUrls) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': url},
        });
      }
      messages.add({'role': 'user', 'content': parts});
    } else if (latest.isNotEmpty && !alreadyLast) {
      messages.add({'role': 'user', 'content': latest});
    }
    return messages;
  }

  /// Parse one SSE frame. Returns streamed text token, or null for non-token
  /// frames. Hermes tool progress frames are delivered via [onToolProgress].
  static String? parseSseFrame(
    String frame, {
    ToolProgressCallback? onToolProgress,
  }) {
    String eventType = '';
    final dataLines = <String>[];

    for (final rawLine in frame.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty || line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }

    if (dataLines.isEmpty) return null;
    final data = dataLines.join('\n').trim();
    if (data.isEmpty || data == '[DONE]') return null;

    try {
      final parsed = jsonDecode(data);
      if (eventType == 'hermes.tool.progress') {
        if (parsed is Map<String, dynamic>) onToolProgress?.call(parsed);
        return null;
      }

      if (parsed is Map<String, dynamic>) {
        final choices = parsed['choices'] as List?;
        if (choices != null && choices.isNotEmpty && choices.first is Map) {
          final first = choices.first as Map;
          final delta = first['delta'];
          if (delta is Map) {
            final content = delta['content'];
            if (content != null && content.toString().isNotEmpty) {
              return content.toString();
            }
          }
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Send a message and stream the assistant response token-by-token.
  Future<void> sendMessageStreaming({
    required String message,
    required String sessionId,
    String? model,
    List<Map<String, dynamic>>? history,
    List<String>? imageDataUrls,
    required void Function(String token) onToken,
    ToolProgressCallback? onToolProgress,
    required void Function() onDone,
    required void Function(String error) onError,
    StreamCancelToken? cancelToken,
  }) async {
    final messages = buildChatCompletionMessages(
      message: message,
      history: history,
      imageDataUrls: imageDataUrls,
    );

    final body = {
      'model': model ?? 'hermes-agent',
      'messages': messages,
      'stream': true,
    };

    final headers = {..._api._headers, 'X-Hermes-Session-Id': sessionId};

    try {
      // Retry with backoff only covers establishing the connection — once a
      // single byte of the response has streamed, the server has already
      // accepted (and is likely persisting) this session's message, so a
      // resend here would risk duplicating it. Ladder mirrors the gateway's
      // own Telegram reconnect backoff (gateway/platforms/telegram/adapter.py):
      // base delay doubling up to a cap, few attempts since this is a
      // foreground user-initiated send, not a background poll.
      const maxConnectAttempts = 4;
      const baseDelay = Duration(seconds: 1);
      const maxDelay = Duration(seconds: 8);
      // Bounds a silently stalled handshake (weak wifi, VPN hiccup, a
      // middlebox eating packets without RST) -- that failure mode produces
      // neither an exception nor a response, so without this the await below
      // never resolves and neither the retry ladder nor a cancelToken check
      // ever gets a chance to run.
      const connectTimeout = Duration(seconds: 15);

      http.StreamedResponse? response;
      for (var attempt = 1; attempt <= maxConnectAttempts; attempt++) {
        if (cancelToken?._cancelled == true) {
          onDone();
          return;
        }
        final request = http.Request(
          'POST',
          Uri.parse('$_baseUrl/v1/chat/completions'),
        );
        request.headers.addAll(headers);
        request.body = jsonEncode(body);

        try {
          response = await _api._http.send(request).timeout(connectTimeout);
          break;
        } catch (e) {
          if (cancelToken?._cancelled == true) {
            onDone();
            return;
          }
          if (attempt >= maxConnectAttempts) rethrow;
          final delayMs = (baseDelay.inMilliseconds * (1 << (attempt - 1)))
              .clamp(0, maxDelay.inMilliseconds);
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }

      final resp = response!;
      if (resp.statusCode != 200) {
        final errorBody = await resp.stream.bytesToString();
        String errorMsg;
        try {
          final err = jsonDecode(errorBody);
          errorMsg =
              err['error']?['message'] ??
              err['message'] ??
              'HTTP ${resp.statusCode}';
        } catch (_) {
          errorMsg = 'HTTP ${resp.statusCode}';
        }
        onError(errorMsg);
        return;
      }

      String buffer = '';
      // SSE frames are separated by a blank line. RFC 8895 mandates CRLF but
      // servers (and proxies) frequently emit LF or a mix — accept any.
      final frameDelimiter = RegExp(r'\r?\n\r?\n');
      bool flushFrame() {
        final m = frameDelimiter.firstMatch(buffer);
        if (m == null) return false;
        final frame = buffer.substring(0, m.start);
        buffer = buffer.substring(m.end);
        final token = parseSseFrame(frame, onToolProgress: onToolProgress);
        if (token != null && token.isNotEmpty) onToken(token);
        return true;
      }

      final completer = Completer<void>();
      late StreamSubscription<String> sub;
      sub = resp.stream.transform(utf8.decoder).listen(
        (chunk) {
          buffer += chunk;
          while (flushFrame()) {}
        },
        onDone: () {
          // Stream ended: flush any final frame whose terminator was lost
          // (some servers close without the trailing blank line).
          if (buffer.trim().isNotEmpty) {
            final token = parseSseFrame(buffer, onToolProgress: onToolProgress);
            if (token != null && token.isNotEmpty) onToken(token);
          }
          onDone();
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e) {
          onError(e.toString());
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );

      // Wiring a cancel into the subscription lets the caller abort an
      // in-flight generation (e.g. a "Stop" button). Cancelling the
      // subscription drops the connection, which the gateway's SSE writer
      // treats the same as any other client disconnect: it calls
      // agent.interrupt() and persists whatever was generated so far (see
      // gateway/platforms/api_server.py) — the same server-side behavior
      // Telegram's cancel button relies on.
      cancelToken?._bind(() {
        sub.cancel();
        onDone();
        if (!completer.isCompleted) completer.complete();
      });

      await completer.future;
    } catch (e) {
      onError(e.toString());
    }
  }

  void abort() {
    _api.close();
  }
}

/// Lets a caller cancel an in-flight [GatewayChatClient.sendMessageStreaming]
/// call — e.g. a "Stop" button while the assistant is replying.
class StreamCancelToken {
  void Function()? _onCancel;
  bool _cancelled = false;

  void _bind(void Function() onCancel) {
    if (_cancelled) {
      onCancel();
      return;
    }
    _onCancel = onCancel;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

/// Client for the Hermes Dashboard REST API.
///
/// Three auth modes, picked by proxy configuration and supplied credentials:
///
///  * **Proxied dashboard** — when [proxied] is true, upstream infrastructure
///    injects auth and the app sends clean JSON requests with no dashboard
///    session token or cookie.
///  * **Password (gated) dashboard** — when [username] and [password] are set,
///    performs the `/auth/password-login` flow (provider `basic`) and
///    authenticates subsequent `/api/` calls with the returned
///    `hermes_session_at` session cookie. This is what hermes-desktop does and
///    is required when the dashboard runs with basic-auth.
///  * **Insecure (open) dashboard** — when no credentials are given, falls back
///    to scraping the ephemeral SPA session token from the homepage. Only works
///    on a dashboard started with `--insecure`.
///
/// Used for Dashboard-only features: cron, memory, skills, settings.
class DashboardClient {
  final http.Client _http;
  final String _baseUrl;
  final bool _proxied;
  final String? _username;
  final String? _password;
  String? _token;
  String? _cookie;
  // In-flight auth requests, shared so concurrent /api calls trigger a single
  // login / token fetch instead of a thundering herd (the dashboard
  // rate-limits password logins).
  Future<String>? _cookieInFlight;
  Future<String>? _tokenInFlight;

  String get baseUrl => _baseUrl;

  bool get _usesPasswordAuth =>
      (_username?.isNotEmpty ?? false) && (_password?.isNotEmpty ?? false);

  DashboardClient({
    required String host,
    int port = 9119,
    bool useHttps = false,
    String pathPrefix = '',
    bool proxied = false,
    String? username,
    String? password,
    http.Client? httpClient,
  }) : _proxied = proxied,
       _username = username,
       _password = password,
       _baseUrl = SavedConnection.joinBaseUrl(
         '${useHttps ? 'https' : 'http'}://$host:$port',
         pathPrefix,
       ),
       _http = httpClient ?? http.Client();

  /// Clears any cached auth state so the next request re-authenticates.
  void _resetAuth() {
    _token = null;
    _cookie = null;
    _cookieInFlight = null;
    _tokenInFlight = null;
  }

  /// Returns the session cookie, reusing a cached value or an in-flight login.
  Future<String> _getCookie() {
    final cached = _cookie;
    if (cached != null) return Future.value(cached);
    return _cookieInFlight ??= _login();
  }

  /// Logs in against the `basic` password provider and caches the session
  /// cookie. Throws on failure (bad credentials → 401, etc.).
  Future<String> _login() async {
    try {
      final res = await _http.post(
        Uri.parse('$_baseUrl/auth/password-login'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'provider': 'basic',
          'username': _username,
          'password': _password,
        }),
      );
      if (res.statusCode == 401) {
        throw Exception('Dashboard login failed: invalid username or password');
      }
      if (res.statusCode != 200) {
        throw Exception('Dashboard login failed: HTTP ${res.statusCode}');
      }
      final setCookie = res.headers['set-cookie'] ?? '';
      // The `http` package folds multiple Set-Cookie headers into one
      // comma-joined string; cookie expiry dates also contain commas, so match
      // the access-token cookie by name and take its value up to the first
      // delimiter. Handles the bare name plus the __Host-/__Secure- prefixes
      // Hermes uses on HTTPS binds.
      final match = RegExp(
        r'((?:__Host-|__Secure-)?hermes_session_at)=([^;,\s]+)',
      ).firstMatch(setCookie);
      if (match == null) {
        throw Exception(
          'Dashboard login succeeded but no session cookie found',
        );
      }
      _cookie = '${match.group(1)}=${match.group(2)}';
      return _cookie!;
    } finally {
      _cookieInFlight = null;
    }
  }

  /// Returns the SPA session token, reusing a cached value or an in-flight fetch.
  Future<String> _getToken() {
    final cached = _token;
    if (cached != null) return Future.value(cached);
    return _tokenInFlight ??= _fetchToken();
  }

  Future<String> _fetchToken() async {
    try {
      final res = await _http.get(Uri.parse('$_baseUrl/'));
      if (res.statusCode != 200) throw Exception('Dashboard not reachable');
      final match = RegExp(
        r'window\.__HERMES_SESSION_TOKEN__="([^"]+)";',
      ).firstMatch(res.body);
      if (match == null) throw Exception('Session token not found');
      _token = match.group(1)!;
      return _token!;
    } finally {
      _tokenInFlight = null;
    }
  }

  Future<Map<String, String>> _authHeaders() async {
    if (_proxied) return {'Content-Type': 'application/json'};
    if (_usesPasswordAuth) {
      return {'Cookie': await _getCookie(), 'Content-Type': 'application/json'};
    }
    return {
      'X-Hermes-Session-Token': await _getToken(),
      'Content-Type': 'application/json',
    };
  }

  Map<String, dynamic> _decodeMapResponse(http.Response res) {
    final trimmed = res.body.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }

  Future<Map<String, dynamic>> apiGet(
    String endpoint, {
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http.get(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth();
      return apiGet(endpoint, retried: true);
    }
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return _decodeMapResponse(res);
  }

  Future<List<dynamic>> apiGetList(
    String endpoint, {
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http.get(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth();
      return apiGetList(endpoint, retried: true);
    }
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final decoded = jsonDecode(res.body);
    if (decoded is List<dynamic>) return decoded;
    if (decoded is Map<String, dynamic> && decoded['data'] is List<dynamic>) {
      return decoded['data'] as List<dynamic>;
    }
    throw Exception('Expected list response');
  }

  Future<Map<String, dynamic>> apiPost(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http.post(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth();
      return apiPost(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return _decodeMapResponse(res);
  }

  Future<void> apiDelete(String endpoint, {bool retried = false}) async {
    final headers = await _authHeaders();
    final res = await _http.delete(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth();
      return apiDelete(endpoint, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
  }

  Future<Map<String, dynamic>> apiPut(
    String endpoint, {
    Map<String, dynamic>? body,
    bool retried = false,
  }) async {
    final headers = await _authHeaders();
    final res = await _http.put(
      Uri.parse('$_baseUrl/api/$endpoint'),
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
    );
    if (res.statusCode == 401 && !retried) {
      _resetAuth();
      return apiPut(endpoint, body: body, retried: true);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return _decodeMapResponse(res);
  }

  Future<Map<String, dynamic>> getModelInfo() => apiGet('model/info');
  Future<Map<String, dynamic>> getModelOptions() => apiGet('model/options');
  Future<List<Map<String, dynamic>>> getSkills() async {
    final data = await apiGetList('skills');
    return data.whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>> setModel(
    String scope,
    String provider,
    String model,
  ) => apiPost(
    'model/set',
    body: {'scope': scope, 'provider': provider, 'model': model},
  );

  // ── Cron job management ──────────────────────────────────────────────

  Future<Map<String, dynamic>> createJob({
    required String prompt,
    required String schedule,
    String name = '',
    String deliver = 'local',
  }) => apiPost(
    'cron/jobs',
    body: {
      'prompt': prompt,
      'schedule': schedule,
      'name': name,
      'deliver': deliver,
    },
  );

  static Map<String, dynamic> buildCronUpdateBody(
    Map<String, dynamic> updates,
  ) => {'updates': updates};

  Future<Map<String, dynamic>> updateJob(
    String jobId,
    Map<String, dynamic> updates,
  ) => apiPut('cron/jobs/$jobId', body: buildCronUpdateBody(updates));

  void close() => _http.close();
}
