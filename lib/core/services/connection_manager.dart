import 'dart:async';
import 'dart:convert';
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
    return jsonList.map((j) {
      final map = jsonDecode(j) as Map<String, dynamic>;
      return SavedConnection.fromMap(map);
    }).toList();
  }

  void saveConnection(String label, String host, int port, String apiKey) {
    final conn = SavedConnection(
      id: _uuid.v4(),
      label: label,
      host: host,
      port: port,
      apiKey: apiKey,
    );
    final current = getConnections();
    current.insert(0, conn);
    _saveAll(current);
  }

  void updateApiKey(String connId, String apiKey) {
    final current = getConnections();
    final idx = current.indexWhere((c) => c.id == connId);
    if (idx < 0) return;
    current[idx] = SavedConnection(
      id: current[idx].id,
      label: current[idx].label,
      host: current[idx].host,
      port: current[idx].port,
      apiKey: apiKey,
    );
    _saveAll(current);
  }

  void deleteConnection(String id) {
    final current = getConnections();
    current.removeWhere((c) => c.id == id);
    _saveAll(current);
  }

  void _saveAll(List<SavedConnection> list) {
    prefs.setStringList(
      _key,
      list.map((c) => jsonEncode(c.toMap())).toList(),
    );
  }
}

/// HTTP client for the Hermes Gateway API Server (port 8642).
///
/// Uses Bearer token auth. Same pattern as hermes-desktop.
class ApiClient {
  final http.Client _http;
  final String baseUrl;
  final String _apiKey;

  ApiClient({required String baseUrl, required String apiKey})
    : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
      _apiKey = apiKey,
      _http = http.Client();

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

  // ── Models ───────────────────────────────────────────────────────────

  Future<List<String>> getModels() async {
    final res = await _http.get(
      Uri.parse('$baseUrl/v1/models'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      return ['hermes-agent'];
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = data['data'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((m) => (m['id'] as String?) ?? 'hermes-agent')
        .toList();
  }

  // ── Health check ─────────────────────────────────────────────────────

  Future<bool> healthCheck() async {
    try {
      final res = await _http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void close() => _http.close();
}

/// SSE streaming chat client for the Gateway API Server.
class GatewayChatClient {
  final ApiClient _api;
  final String _baseUrl;

  GatewayChatClient(this._api) : _baseUrl = _api.baseUrl;

  /// Generate a client-side session ID: mob-<timestamp>-<uuid>
  static String generateSessionId() {
    return 'mob-${DateTime.now().millisecondsSinceEpoch}-${const Uuid().v4()}';
  }

  /// Send a message and stream the assistant response token-by-token.
  Future<void> sendMessageStreaming({
    required String message,
    required String sessionId,
    String? model,
    List<Map<String, dynamic>>? history,
    required void Function(String token) onToken,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    final messages = <Map<String, dynamic>>[];
    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        final role = (msg['role'] == 'agent' || msg['role'] == 'assistant')
            ? 'assistant'
            : 'user';
        messages.add({
          'role': role,
          'content': msg['content'] ?? '',
        });
      }
    }
    messages.add({'role': 'user', 'content': message});

    final body = {
      'model': model ?? 'hermes-agent',
      'messages': messages,
      'stream': true,
    };

    final headers = {
      ..._api._headers,
      'X-Hermes-Session-Id': sessionId,
    };

    try {
      final request = http.Request('POST', Uri.parse('$_baseUrl/v1/chat/completions'));
      request.headers.addAll(headers);
      request.body = jsonEncode(body);

      final response = await _api._http.send(request);

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        String errorMsg;
        try {
          final err = jsonDecode(errorBody);
          errorMsg = err['error']?['message'] ?? err['message'] ?? 'HTTP ${response.statusCode}';
        } catch (_) {
          errorMsg = 'HTTP ${response.statusCode}';
        }
        onError(errorMsg);
        return;
      }

      String buffer = '';
      await response.stream
          .transform(utf8.decoder)
          .forEach((chunk) {
        buffer += chunk;
        while (buffer.contains('\n\n')) {
          final eventEnd = buffer.indexOf('\n\n');
          final event = buffer.substring(0, eventEnd);
          buffer = buffer.substring(eventEnd + 2);

          for (final line in event.split('\n')) {
            if (line.startsWith('data: ')) {
              final data = line.substring(6).trim();
              if (data == '[DONE]') continue;

              try {
                final parsed = jsonDecode(data);
                final choices = parsed['choices'] as List?;
                if (choices != null && choices.isNotEmpty) {
                  final delta = choices[0]['delta'];
                  if (delta != null) {
                    final content = delta['content'];
                    if (content != null && content.toString().isNotEmpty) {
                      onToken(content.toString());
                    }
                  }
                }
              } catch (_) {}
            }
          }
        }
      });

      onDone();
    } catch (e) {
      onError(e.toString());
    }
  }

  void abort() {
    _api.close();
  }
}
