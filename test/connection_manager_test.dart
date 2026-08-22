import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

/// Case-insensitive request header lookup — package:http normalises header
/// names when sending, so tests should not assume a particular casing.
String? _header(http.BaseRequest request, String name) {
  final lower = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

/// Fake client for exercising [GatewayChatClient.sendMessageStreaming]'s
/// connect retry ladder: throws on the first [failCount] calls to `send`,
/// then returns a streamed response ending in the gateway's own `[DONE]`
/// terminator -- a bare empty stream isn't a realistic "successful" SSE
/// response (a real one always closes with `data: [DONE]`), and would
/// actually be treated as an interrupted connection by the completion
/// detection in sendMessageStreaming.
class _CountingFailThenSucceedClient extends http.BaseClient {
  _CountingFailThenSucceedClient(this.failCount);
  final int failCount;
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount++;
    if (sendCount <= failCount) {
      throw Exception('connection reset');
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('data: [DONE]\n\n')),
      200,
    );
  }

  @override
  void close() {}
}

/// Never completes send() -- models a stalled handshake (weak wifi, VPN
/// hiccup, a middlebox eating packets without RST) that produces neither a
/// response nor an exception, only a timeout.
class _NeverRespondingClient extends http.BaseClient {
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendCount++;
    return Completer<http.StreamedResponse>().future;
  }

  @override
  void close() {}
}

void main() {
  group('SavedConnection', () {
    test('normalizes bare HTTP gateway hosts with fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        '192.168.1.50',
        8642,
      );

      expect(normalized.host, '192.168.1.50');
      expect(normalized.port, 8642);
      expect(normalized.useHttps, isFalse);
    });

    test('normalizes HTTPS URLs without an explicit port to 443', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8642,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 443);
      expect(normalized.useHttps, isTrue);
    });

    test('normalizes HTTPS URLs with a custom fallback port', () {
      final normalized = SavedConnection.normalizeHostAndPort(
        'https://hermes.example.com',
        8443,
      );

      expect(normalized.host, 'hermes.example.com');
      expect(normalized.port, 8443);
      expect(normalized.useHttps, isTrue);
    });

    test('serializes HTTPS flag and remains backward compatible', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(SavedConnection.fromMap(conn.toMap()).useHttps, isTrue);
      expect(
        SavedConnection.fromMap({
          'id': '2',
          'label': 'Old',
          'host': '192.168.1.50',
          'port': 8642,
          'api_key': 'key',
        }).useHttps,
        isFalse,
      );
    });

    test('uses dashboard port 9119 for local gateway connections', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
      );

      expect(conn.dashboardPort, 9119);
      expect(
        DashboardClient(host: conn.host, port: conn.dashboardPort).baseUrl,
        'http://192.168.1.50:9119',
      );
    });

    test('uses the HTTPS proxy port for dashboard calls over HTTPS', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
      );

      expect(conn.dashboardPort, 443);
      expect(
        DashboardClient(
          host: conn.host,
          port: conn.dashboardPort,
          useHttps: conn.useHttps,
        ).baseUrl,
        'https://hermes.example.com:443',
      );
    });

    test('explicit dashboard port override wins over topology default', () {
      final local = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        dashboardPortOverride: 30433,
      );
      expect(local.dashboardPort, 30433);

      final https = SavedConnection(
        id: '2',
        label: 'Remote',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        dashboardPortOverride: 8443,
      );
      expect(https.dashboardPort, 8443);
    });

    test(
      'round-trips dashboard port and credentials through toMap/fromMap',
      () {
        final conn = SavedConnection(
          id: '1',
          label: 'Home',
          host: '192.168.1.50',
          port: 8642,
          apiKey: 'key',
          dashboardPortOverride: 30433,
          dashboardUsername: 'misha',
          dashboardPassword: 'secret',
        );

        final restored = SavedConnection.fromMap(conn.toMap());
        expect(restored.dashboardPortOverride, 30433);
        expect(restored.dashboardUsername, 'misha');
        expect(restored.dashboardPassword, 'secret');
        expect(restored.dashboardPort, 30433);
      },
    );

    test('fromMap is backward compatible with maps lacking dashboard keys', () {
      final restored = SavedConnection.fromMap({
        'id': '2',
        'label': 'Old',
        'host': '192.168.1.50',
        'port': 8642,
        'api_key': 'key',
      });
      expect(restored.dashboardPortOverride, isNull);
      expect(restored.dashboardUsername, isNull);
      expect(restored.dashboardPassword, isNull);
      expect(restored.dashboardPort, 9119);
    });

    test('fromMap normalises blank credentials to null', () {
      final restored = SavedConnection.fromMap({
        'id': '3',
        'label': 'Blank',
        'host': '192.168.1.50',
        'port': 8642,
        'api_key': 'key',
        'dashboard_username': '   ',
        'dashboard_password': '',
      });
      expect(restored.dashboardUsername, isNull);
      expect(restored.dashboardPassword, isNull);
    });

    test('copyWith preserves unset fields and clears via flags', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Home',
        host: '192.168.1.50',
        port: 8642,
        apiKey: 'key',
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
        dashboardPortOverride: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final keyOnly = conn.copyWith(apiKey: 'new-key');
      expect(keyOnly.apiKey, 'new-key');
      expect(keyOnly.gatewayPrefix, '/profile/peter');
      expect(keyOnly.dashboardPrefix, '/dashboard');
      expect(keyOnly.dashboardProxied, isTrue);
      expect(keyOnly.dashboardPortOverride, 30433);
      expect(keyOnly.dashboardUsername, 'misha');
      expect(keyOnly.dashboardPassword, 'secret');

      final cleared = conn.copyWith(
        clearGatewayPrefix: true,
        clearDashboardPrefix: true,
        clearDashboardPort: true,
        clearDashboardUsername: true,
        clearDashboardPassword: true,
      );
      expect(cleared.gatewayPrefix, isNull);
      expect(cleared.dashboardPrefix, isNull);
      expect(cleared.dashboardProxied, isTrue);
      expect(cleared.dashboardPortOverride, isNull);
      expect(cleared.dashboardUsername, isNull);
      expect(cleared.dashboardPassword, isNull);
      // Identity and unrelated fields are retained.
      expect(cleared.id, '1');
      expect(cleared.apiKey, 'key');
    });
  });

  group('ApiClient', () {
    test('healthCheck verifies an authenticated endpoint', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer valid-key');
          if (request.url.path == '/health') {
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response('{"object":"list","data":[]}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(await client.healthCheck(), isTrue);
      client.close();
    });

    test('healthCheck rejects invalid API keys', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'bad-key',
        httpClient: MockClient((request) async {
          if (request.url.path == '/health') {
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/sessions') {
            return http.Response('unauthorized', 401);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(await client.healthCheck(), isFalse);
      client.close();
    });

    test('deleteSession deletes a remote Hermes session', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/sessions/mob-123');
          expect(request.headers['authorization'], 'Bearer valid-key');
          return http.Response('{"object":"hermes.session.deleted"}', 200);
        }),
      );

      await client.deleteSession('mob-123');
      client.close();
    });

    test('deleteSession treats already-missing sessions as synced', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.method, 'DELETE');
          expect(request.url.path, '/api/sessions/mob-absent');
          return http.Response('not found', 404);
        }),
      );

      await client.deleteSession('mob-absent');
      client.close();
    });

    test('renameSession PATCHes the new title', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/sessions/mob-123');
          expect(request.headers['authorization'], 'Bearer valid-key');
          expect(jsonDecode(request.body), {'title': 'A better title'});
          return http.Response(
            '{"object":"hermes.session","session":{"id":"mob-123"}}',
            200,
          );
        }),
      );

      await client.renameSession('mob-123', 'A better title');
      client.close();
    });

    test('renameSession throws on a server error', () async {
      final client = ApiClient(
        baseUrl: 'http://hermes.local:8642',
        apiKey: 'valid-key',
        httpClient: MockClient((request) async {
          return http.Response('server error', 500);
        }),
      );

      expect(
        () => client.renameSession('mob-123', 'New title'),
        throwsA(anything),
      );
      client.close();
    });
  });

  group('GatewayChatClient', () {
    test('appends latest user message to existing history exactly once', () {
      final messages = GatewayChatClient.buildChatCompletionMessages(
        message: 'new question',
        history: [
          {'role': 'user', 'content': 'old question'},
          {'role': 'assistant', 'content': 'old answer'},
        ],
      );

      expect(messages, [
        {'role': 'user', 'content': 'old question'},
        {'role': 'assistant', 'content': 'old answer'},
        {'role': 'user', 'content': 'new question'},
      ]);
    });

    test(
      'does not duplicate latest user message already present in history',
      () {
        final messages = GatewayChatClient.buildChatCompletionMessages(
          message: 'new question',
          history: [
            {'role': 'user', 'content': 'old question'},
            {'role': 'assistant', 'content': 'old answer'},
            {'role': 'user', 'content': 'new question'},
          ],
        );

        expect(
          messages.where((m) => m['content'] == 'new question'),
          hasLength(1),
        );
        expect(messages.last, {'role': 'user', 'content': 'new question'});
      },
    );

    test(
      'an attached image becomes an image_url part alongside the typed text',
      () {
        final messages = GatewayChatClient.buildChatCompletionMessages(
          message: 'screenshot',
          imageDataUrls: ['data:image/png;base64,AAAA'],
        );

        expect(messages, [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'screenshot'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png;base64,AAAA'},
              },
            ],
          },
        ]);
      },
    );

    test('parses normal chat completion SSE token frames', () {
      final token = GatewayChatClient.parseSseFrame(
        'data: {"choices":[{"delta":{"content":"hello"}}]}',
      );

      expect(token, 'hello');
    });

    test('parses Hermes tool progress SSE frames via callback', () {
      Map<String, dynamic>? progress;
      final token = GatewayChatClient.parseSseFrame(
        'event: hermes.tool.progress\n'
        'data: {"tool":"read_file","toolCallId":"call_1","status":"running"}',
        onToolProgress: (p) => progress = p,
      );

      expect(token, isNull);
      expect(progress, isNotNull);
      expect(progress!['tool'], 'read_file');
      expect(progress!['toolCallId'], 'call_1');
      expect(progress!['status'], 'running');
    });

    test(
      'sendMessageStreaming retries a failed connect with backoff and '
      'eventually succeeds',
      () async {
        final client = _CountingFailThenSucceedClient(2);
        final api = ApiClient(
          baseUrl: 'http://example.test',
          apiKey: 'k',
          httpClient: client,
        );
        var doneCalled = false;
        String? errorMsg;
        await GatewayChatClient(api).sendMessageStreaming(
          message: 'hi',
          sessionId: 'sess1',
          onToken: (_) {},
          onDone: () => doneCalled = true,
          onError: (e) => errorMsg = e,
        );

        expect(client.sendCount, 3);
        expect(doneCalled, isTrue);
        expect(errorMsg, isNull);
      },
    );

    test(
      'sendMessageStreaming does NOT retry after a connect timeout -- the '
      'request may already have reached the server, so a second POST risks '
      'a duplicate turn',
      () async {
        // Never completes: exercises the case Future.timeout() times out
        // rather than the request throwing outright.
        final hangingClient = _NeverRespondingClient();
        final api = ApiClient(
          baseUrl: 'http://example.test',
          apiKey: 'k',
          httpClient: hangingClient,
        );
        String? errorMsg;
        var doneCalled = false;

        await GatewayChatClient(
          api,
          connectTimeout: const Duration(milliseconds: 20),
        ).sendMessageStreaming(
          message: 'hi',
          sessionId: 'sess1',
          onToken: (_) {},
          onDone: () => doneCalled = true,
          onError: (e) => errorMsg = e,
        );

        // Exactly one attempt -- not maxConnectAttempts (4) -- proves the
        // timeout path doesn't fall into the connect-failure retry ladder.
        expect(hangingClient.sendCount, 1);
        expect(errorMsg, contains('timed out'));
        expect(doneCalled, isFalse);
      },
    );

    test(
      'sendMessageStreaming bails out immediately if already cancelled, '
      'without sending a request',
      () async {
        final client = _CountingFailThenSucceedClient(0);
        final api = ApiClient(
          baseUrl: 'http://example.test',
          apiKey: 'k',
          httpClient: client,
        );
        final cancelToken = StreamCancelToken()..cancel();
        var doneCalled = false;

        await GatewayChatClient(api).sendMessageStreaming(
          message: 'hi',
          sessionId: 'sess1',
          cancelToken: cancelToken,
          onToken: (_) {},
          onDone: () => doneCalled = true,
          onError: (_) => fail('onError should not fire on a pre-cancelled send'),
        );

        expect(client.sendCount, 0);
        expect(doneCalled, isTrue);
      },
    );

    test(
      'sendMessageStreaming reports an error if the stream stalls after '
      'the first chunk, instead of hanging forever',
      () async {
        // Emits one token frame, then never sends another chunk and never
        // closes -- the exact shape of a middlebox/dead-worker stall where
        // the socket stays open but produces nothing.
        final controller = StreamController<List<int>>();
        controller.add(
          utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'),
        );
        final client = MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(controller.stream, 200);
        });
        final api = ApiClient(
          baseUrl: 'http://example.test',
          apiKey: 'k',
          httpClient: client,
        );

        final tokens = <String>[];
        var doneCalled = false;
        String? errorMsg;

        await GatewayChatClient(
          api,
          idleTimeout: const Duration(milliseconds: 50),
        ).sendMessageStreaming(
          message: 'hi',
          sessionId: 'sess1',
          onToken: tokens.add,
          onDone: () => doneCalled = true,
          onError: (e) => errorMsg = e,
        );

        expect(tokens, ['hi']);
        expect(errorMsg, contains('stalled'));
        expect(doneCalled, isFalse);
        await controller.close();
      },
    );

    test(
      'a stream that closes cleanly without [DONE] is reported as an '
      'error, not silently treated as a successful finish',
      () async {
        // Some tokens stream, then the socket just closes -- no exception,
        // no `data: [DONE]` frame. Indistinguishable from a real finish at
        // the transport level (both are a clean StreamSubscription onDone);
        // only the missing [DONE] marks this as a truncated reply.
        final client = MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('data: {"choices":[{"delta":{"content":"par"}}]}\n\n'),
              utf8.encode('data: {"choices":[{"delta":{"content":"tial"}}]}\n\n'),
            ]),
            200,
          );
        });
        final api = ApiClient(
          baseUrl: 'http://example.test',
          apiKey: 'k',
          httpClient: client,
        );

        final tokens = <String>[];
        var doneCalled = false;
        String? errorMsg;

        await GatewayChatClient(api).sendMessageStreaming(
          message: 'hi',
          sessionId: 'sess1',
          onToken: tokens.add,
          onDone: () => doneCalled = true,
          onError: (e) => errorMsg = e,
        );

        expect(tokens, ['par', 'tial']);
        expect(errorMsg, contains('closed before the reply finished'));
        expect(doneCalled, isFalse);
      },
    );

    test(
      'a stream that closes with [DONE] is reported as a normal success',
      () async {
        final client = MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
              utf8.encode('data: [DONE]\n\n'),
            ]),
            200,
          );
        });
        final api = ApiClient(
          baseUrl: 'http://example.test',
          apiKey: 'k',
          httpClient: client,
        );

        final tokens = <String>[];
        var doneCalled = false;
        String? errorMsg;

        await GatewayChatClient(api).sendMessageStreaming(
          message: 'hi',
          sessionId: 'sess1',
          onToken: tokens.add,
          onDone: () => doneCalled = true,
          onError: (e) => errorMsg = e,
        );

        expect(tokens, ['ok']);
        expect(doneCalled, isTrue);
        expect(errorMsg, isNull);
      },
    );
  });

  group('DashboardClient', () {
    test(
      'createJob sends no_agent and script in the same create request '
      '(atomic, not a follow-up PATCH)',
      () async {
        Map<String, dynamic>? sentBody;
        final client = DashboardClient(
          host: 'hermes.local',
          port: 8642,
          proxied: true,
          httpClient: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/api/cron/jobs');
            sentBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('{"id": "job1"}', 200);
          }),
        );

        await client.createJob(
          name: 'Backup',
          prompt: '',
          schedule: '0 9 * * *',
          script: 'backup.py',
          noAgent: true,
        );

        expect(sentBody, isNotNull);
        expect(sentBody!['no_agent'], isTrue);
        expect(sentBody!['script'], 'backup.py');
        client.close();
      },
    );

    test('createJob omits script when not given', () async {
      Map<String, dynamic>? sentBody;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 8642,
        proxied: true,
        httpClient: MockClient((request) async {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('{"id": "job2"}', 200);
        }),
      );

      await client.createJob(
        name: 'Reminder',
        prompt: 'Remind me to stretch',
        schedule: 'every 2h',
      );

      expect(sentBody, isNotNull);
      expect(sentBody!.containsKey('script'), isFalse);
      expect(sentBody!['no_agent'], isFalse);
      client.close();
    });

    test('wraps cron job updates for dashboard endpoint', () {
      final updates = {'name': 'Daily', 'no_agent': true};

      expect(DashboardClient.buildCronUpdateBody(updates), {
        'updates': updates,
      });
    });

    test(
      'logs in and authenticates /api calls with the session cookie',
      () async {
        var loginCalls = 0;
        final client = DashboardClient(
          host: 'hermes.local',
          port: 30433,
          username: 'misha',
          password: 'secret',
          httpClient: MockClient((request) async {
            if (request.url.path == '/auth/password-login') {
              loginCalls++;
              expect(request.method, 'POST');
              expect(jsonDecode(request.body), {
                'provider': 'basic',
                'username': 'misha',
                'password': 'secret',
              });
              return http.Response(
                '{"ok":true}',
                200,
                headers: {
                  'set-cookie':
                      'hermes_session_at=TOK123; Path=/; HttpOnly; SameSite=Lax',
                },
              );
            }
            if (request.url.path == '/api/model/info') {
              // Cookie auth, not the insecure token header.
              expect(_header(request, 'cookie'), 'hermes_session_at=TOK123');
              expect(_header(request, 'x-hermes-session-token'), isNull);
              return http.Response('{"model":"hermes-agent"}', 200);
            }
            return http.Response('not found', 404);
          }),
        );

        final info = await client.getModelInfo();
        expect(info['model'], 'hermes-agent');

        // A second call reuses the cached cookie (no re-login).
        await client.getModelInfo();
        expect(loginCalls, 1);
        client.close();
      },
    );

    test('falls back to homepage token scrape when no credentials', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 9119,
        httpClient: MockClient((request) async {
          if (request.url.path == '/') {
            return http.Response(
              '<script>window.__HERMES_SESSION_TOKEN__="SPA_TOK";</script>',
              200,
            );
          }
          if (request.url.path == '/api/model/info') {
            expect(_header(request, 'x-hermes-session-token'), 'SPA_TOK');
            expect(_header(request, 'cookie'), isNull);
            return http.Response('{"model":"hermes-agent"}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.getModelInfo();
      expect(info['model'], 'hermes-agent');
      client.close();
    });

    test('re-authenticates once on a 401 from an /api call', () async {
      var apiCalls = 0;
      var loginCalls = 0;
      final client = DashboardClient(
        host: 'hermes.local',
        port: 30433,
        username: 'misha',
        password: 'secret',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            loginCalls++;
            final cookie = 'hermes_session_at=TOK$loginCalls';
            return http.Response(
              '{"ok":true}',
              200,
              headers: {'set-cookie': '$cookie; Path=/'},
            );
          }
          if (request.url.path == '/api/model/info') {
            apiCalls++;
            // First attempt: stale cookie → 401. Retry: succeeds.
            if (apiCalls == 1) return http.Response('unauthorized', 401);
            expect(_header(request, 'cookie'), 'hermes_session_at=TOK2');
            return http.Response('{"model":"hermes-agent"}', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final info = await client.getModelInfo();
      expect(info['model'], 'hermes-agent');
      expect(apiCalls, 2);
      expect(loginCalls, 2);
      client.close();
    });

    test('surfaces invalid dashboard credentials', () async {
      final client = DashboardClient(
        host: 'hermes.local',
        port: 30433,
        username: 'misha',
        password: 'wrong',
        httpClient: MockClient((request) async {
          if (request.url.path == '/auth/password-login') {
            return http.Response('{"detail":"Invalid credentials"}', 401);
          }
          return http.Response('not found', 404);
        }),
      );

      expect(client.getModelInfo(), throwsA(isA<Exception>()));
      client.close();
    });
  });

  group('ConnectionManager', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('saveConnection persists dashboard port and credentials', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = ConnectionManager(prefs);
      mgr.saveConnection(
        'Home',
        '192.168.1.50',
        8642,
        'key',
        dashboardPort: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );

      final conn = mgr.getConnections().single;
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');
    });

    test(
      'getConnections skips a malformed stored entry instead of throwing',
      () async {
        final good = SavedConnection(
          id: 'good-id',
          label: 'Home',
          host: '192.168.1.50',
          port: 8642,
          apiKey: 'key',
        );
        SharedPreferences.setMockInitialValues({
          'saved_connections': [
            jsonEncode(good.toMap()),
            '{"id": "corrupt-id", "label": "Corrupt"}', // missing host
            'not even json',
          ],
        });
        final prefs = await SharedPreferences.getInstance();
        final mgr = ConnectionManager(prefs);

        final conns = mgr.getConnections();

        expect(conns, hasLength(1));
        expect(conns.single.id, 'good-id');
      },
    );

    test('updateDashboardAuth sets then clears fields', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = ConnectionManager(prefs);
      mgr.saveConnection('Home', '192.168.1.50', 8642, 'key');
      final id = mgr.getConnections().single.id;

      mgr.updateDashboardAuth(
        id,
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
        dashboardPort: 30433,
        username: 'misha',
        password: 'secret',
      );
      var conn = mgr.getConnections().single;
      expect(conn.gatewayPrefix, '/profile/peter');
      expect(conn.dashboardPrefix, '/dashboard');
      expect(conn.dashboardProxied, isTrue);
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');

      // Blank values clear the corresponding fields.
      mgr.updateDashboardAuth(
        id,
        gatewayPrefix: '',
        dashboardPrefix: '',
        dashboardProxied: false,
        username: '',
        password: '',
      );
      conn = mgr.getConnections().single;
      expect(conn.gatewayPrefix, isNull);
      expect(conn.dashboardPrefix, isNull);
      expect(conn.dashboardProxied, isFalse);
      expect(conn.dashboardPortOverride, isNull);
      expect(conn.dashboardUsername, isNull);
      expect(conn.dashboardPassword, isNull);
    });

    test('updateApiKey preserves dashboard credentials', () async {
      final prefs = await SharedPreferences.getInstance();
      final mgr = ConnectionManager(prefs);
      mgr.saveConnection(
        'Home',
        '192.168.1.50',
        8642,
        'key',
        dashboardPort: 30433,
        dashboardUsername: 'misha',
        dashboardPassword: 'secret',
      );
      final id = mgr.getConnections().single.id;

      mgr.updateApiKey(id, 'new-key');
      final conn = mgr.getConnections().single;
      expect(conn.apiKey, 'new-key');
      expect(conn.dashboardPortOverride, 30433);
      expect(conn.dashboardUsername, 'misha');
      expect(conn.dashboardPassword, 'secret');
    });
  });

  group('Path prefix support', () {
    test('joinBaseUrl without prefix returns baseUrl unchanged', () {
      expect(
        SavedConnection.joinBaseUrl('https://hermes.example.com:443', ''),
        'https://hermes.example.com:443',
      );
    });

    test('joinBaseUrl appends prefix between base and API path', () {
      expect(
        SavedConnection.joinBaseUrl(
          'https://hermes.example.com:443',
          '/profile/peter',
        ),
        'https://hermes.example.com:443/profile/peter',
      );
    });

    test('ApiClient pathPrefix is prepended to baseUrl', () {
      final client = ApiClient(
        baseUrl: 'https://hermes.example.com:443',
        apiKey: 'key',
        pathPrefix: '/profile/peter',
      );
      expect(client.baseUrl, 'https://hermes.example.com:443/profile/peter');
      client.close();
    });

    test('DashboardClient uses pathPrefix', () {
      final client = DashboardClient(
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        pathPrefix: '/dashboard',
      );
      expect(client.baseUrl, 'https://hermes.example.com:443/dashboard');
      client.close();
    });

    test('DashboardClient proxied sends no auth headers', () async {
      final client = DashboardClient(
        host: 'hermes.example.com',
        port: 443,
        useHttps: true,
        pathPrefix: '/dashboard',
        proxied: true,
        httpClient: MockClient((request) async {
          expect(
            request.headers.containsKey('x-hermes-session-token'),
            isFalse,
          );
          expect(request.headers.containsKey('cookie'), isFalse);
          return http.Response('{"data": {}}', 200);
        }),
      );
      await client.apiGet('model/info');
      client.close();
    });

    test(
      'DashboardClient proxied ignores credentials, sends clean headers',
      () async {
        final client = DashboardClient(
          host: 'hermes.example.com',
          port: 443,
          useHttps: true,
          pathPrefix: '/dashboard',
          proxied: true,
          username: 'user',
          password: 'pass',
          httpClient: MockClient((request) async {
            expect(
              request.headers.containsKey('x-hermes-session-token'),
              isFalse,
            );
            expect(request.headers.containsKey('cookie'), isFalse);
            return http.Response('{"data": {}}', 200);
          }),
        );
        await client.apiGet('model/info');
        client.close();
      },
    );

    test('SavedConnection serializes gateway and dashboard prefixes', () {
      final conn = SavedConnection(
        id: '1',
        label: 'Proxy',
        host: 'hermes.example.com',
        port: 443,
        apiKey: 'key',
        useHttps: true,
        gatewayPrefix: '/profile/peter',
        dashboardPrefix: '/dashboard',
        dashboardProxied: true,
      );
      final map = conn.toMap();
      expect(map['gateway_prefix'], '/profile/peter');
      expect(map['dashboard_prefix'], '/dashboard');
      expect(map['dashboard_proxied'], true);
    });
  });

  group('Request timeouts', () {
    // A half-open socket -- wifi/cellular handoff, a VPN reconnect, a
    // middlebox dropping the connection without a RST -- yields neither bytes
    // nor an error. Before these timeouts existed the await simply never
    // resolved, so the screen sat on its spinner forever with no retry path.
    test('ApiClient.getMessages gives up instead of hanging forever', () {
      final client = ApiClient(
        baseUrl: 'http://host:8642',
        apiKey: 'k',
        requestTimeout: const Duration(milliseconds: 50),
        httpClient: _HangingClient(),
      );
      expect(
        client.getMessages('session-1'),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('ApiClient.getSessions gives up instead of hanging forever', () {
      final client = ApiClient(
        baseUrl: 'http://host:8642',
        apiKey: 'k',
        requestTimeout: const Duration(milliseconds: 50),
        httpClient: _HangingClient(),
      );
      expect(client.getSessions(), throwsA(isA<TimeoutException>()));
    });

    test('DashboardClient.apiGet gives up instead of hanging forever', () {
      final client = DashboardClient(
        host: 'host',
        proxied: true,
        requestTimeout: const Duration(milliseconds: 50),
        httpClient: _HangingClient(),
      );
      expect(client.getModelInfo(), throwsA(isA<TimeoutException>()));
    });

    test('a response inside the budget still succeeds', () async {
      final client = ApiClient(
        baseUrl: 'http://host:8642',
        apiKey: 'k',
        requestTimeout: const Duration(seconds: 5),
        httpClient: MockClient((request) async {
          return http.Response(jsonEncode({'data': []}), 200);
        }),
      );
      expect(await client.getMessages('session-1'), isEmpty);
    });
  });
}

/// Accepts the request and then never responds — the half-open socket case.
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;

  @override
  void close() {}
}
