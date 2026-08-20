// Protocol-level coverage against a real loopback ComfyUI server, not a
// scripted http.Client -- this is the one place that proves ComfyUiClient
// and ComfyUiSocket actually speak HTTP/WebSocket correctly (multipart
// upload framing, JSON envelopes, WebSocket upgrade and message framing),
// which a BaseClient fake cannot catch. It deliberately serves everything
// behind a reverse-proxy path prefix, since that is the one detail a
// hand-rolled URL-concatenation bug would silently drop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/services/comfyui_client.dart';
import 'package:hermes_android/core/services/comfyui_socket.dart';

void main() {
  late _FakeComfyServer server;

  setUp(() async {
    server = await _FakeComfyServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  ComfyUiClient client() => ComfyUiClient(
    endpoint: server.endpoint,
    clientId: 'test-client',
    connectTimeout: const Duration(seconds: 5),
    idleTimeout: const Duration(seconds: 5),
  );

  test('submits a prompt through the reverse-proxy prefix and every request '
      'lands on the prefixed path', () async {
    final c = client();
    addTearDown(c.close);
    server.promptResponse = {'prompt_id': 'p1', 'number': 1};

    final submission = await c.submitPrompt({'1': 'node'});

    expect(submission.promptId, 'p1');
    expect(server.requestPaths, contains('/proxy/prompt'));
    expect(server.requestPaths.every((p) => p.startsWith('/proxy/')), isTrue);
  });

  test(
    'uploads an image and returns the server-issued output reference',
    () async {
      final c = client();
      addTearDown(c.close);
      server.uploadResponse = {
        'name': 'server-issued.png',
        'subfolder': 'uploads',
        'type': 'input',
      };

      final ref = await c.uploadImage(_pngBytes, fileName: 'local.png');

      expect(ref.filename, 'server-issued.png');
      expect(ref.subfolder, 'uploads');
      expect(server.uploadedFileNames, ['local.png']);
    },
  );

  test('a node validation error on submission surfaces node_errors and fails '
      'outright, not as an uncertain submission', () async {
    final c = client();
    addTearDown(c.close);
    server.promptStatusCode = 400;
    server.promptResponse = {
      'error': {'message': 'graph invalid'},
      'node_errors': {'3': 'missing input'},
    };

    await expectLater(
      c.submitPrompt({'1': 'node'}),
      throwsA(
        isA<ComfyApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.nodeErrors, 'nodeErrors', {'3': 'missing input'}),
      ),
    );
  });

  test(
    'queue reflects a running prompt and history reports its outputs',
    () async {
      final c = client();
      addTearDown(c.close);
      server.queueRunning = ['p1'];
      server.historyByPromptId['p1'] = {
        'status': {'completed': true, 'status_str': 'success'},
        'outputs': {
          '9': {
            'images': [
              {'filename': 'render.png', 'subfolder': '', 'type': 'output'},
            ],
          },
        },
      };

      final queue = await c.getQueue();
      expect(queue.isRunning('p1'), isTrue);

      final history = await c.getHistory('p1');
      expect(history, isNotNull);
      expect(history!.completed, isTrue);
      expect(history.outputs.single.filename, 'render.png');
    },
  );

  test('history also surfaces video outputs the same way as images', () async {
    final c = client();
    addTearDown(c.close);
    server.historyByPromptId['p2'] = {
      'status': {'completed': true, 'status_str': 'success'},
      'outputs': {
        '9': {
          'gifs': [
            {'filename': 'clip.mp4', 'subfolder': '', 'type': 'output'},
          ],
        },
      },
    };

    final history = await c.getHistory('p2');
    expect(history!.outputs.single.filename, 'clip.mp4');
  });

  test(
    'deleting a queued prompt sends exactly that prompt id and nothing else',
    () async {
      final c = client();
      addTearDown(c.close);

      await c.deleteQueuedPrompt('p1');

      expect(server.deleteQueueBodies, [
        {
          'delete': ['p1'],
        },
      ]);
    },
  );

  test('interrupt hits the prefixed interrupt endpoint', () async {
    final c = client();
    addTearDown(c.close);

    await c.interrupt();

    expect(server.interruptCalls, 1);
  });

  test('the websocket delivers queued/running progress through to a terminal '
      'success event with typed outputs', () async {
    server.wsFrames = [
      jsonEncode({
        'type': 'status',
        'data': {
          'status': {
            'exec_info': {'queue_remaining': 1},
          },
        },
      }),
      jsonEncode({
        'type': 'executing',
        'data': {'node': '1', 'prompt_id': 'p1'},
      }),
      jsonEncode({
        'type': 'progress',
        'data': {'node': '1', 'value': 5, 'max': 10, 'prompt_id': 'p1'},
      }),
      jsonEncode({
        'type': 'executed',
        'data': {
          'node': '9',
          'prompt_id': 'p1',
          'output': {
            'images': [
              {'filename': 'render.png', 'subfolder': '', 'type': 'output'},
            ],
          },
        },
      }),
      jsonEncode({
        'type': 'execution_success',
        'data': {'prompt_id': 'p1'},
      }),
    ];

    final socket = ComfyUiSocket();
    final events = await socket
        .watchExecution(
          server.endpoint,
          clientId: 'test-client',
          promptId: 'p1',
        )
        .toList();

    expect(events.whereType<ComfyStatus>().single.queueRemaining, 1);
    expect(events.whereType<ComfyExecuting>().single.nodeId, '1');
    expect(events.whereType<ComfyProgress>().single.value, 5);
    expect(
      events.whereType<ComfyExecuted>().single.outputs.single.filename,
      'render.png',
    );
    expect(events.last, isA<ComfySucceeded>());
  });

  test('the server closing the socket before a terminal event surfaces as a '
      'lost connection, not a silent stall', () async {
    server.wsFrames = [
      jsonEncode({
        'type': 'executing',
        'data': {'node': '1', 'prompt_id': 'p1'},
      }),
    ];
    server.closeSocketAfterFrames = true;

    final socket = ComfyUiSocket();
    final events = await socket
        .watchExecution(
          server.endpoint,
          clientId: 'test-client',
          promptId: 'p1',
        )
        .toList();

    expect(events.first, isA<ComfyExecuting>());
    expect(events.last, isA<ComfySocketLost>());
  });

  test('an execution_error frame surfaces as a typed error event with the '
      'server message', () async {
    server.wsFrames = [
      jsonEncode({
        'type': 'execution_error',
        'data': {'prompt_id': 'p1', 'exception_message': 'CUDA out of memory'},
      }),
    ];

    final socket = ComfyUiSocket();
    final events = await socket
        .watchExecution(
          server.endpoint,
          clientId: 'test-client',
          promptId: 'p1',
        )
        .toList();

    expect(
      events.single,
      isA<ComfyExecutionError>().having(
        (e) => e.message,
        'message',
        'CUDA out of memory',
      ),
    );
  });
}

final _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0, 0, 0, 0, 0, 0, 0, 0,
]);

/// A minimal, scriptable stand-in for a ComfyUI server, bound to the IPv4
/// loopback and served entirely under a `/proxy` path prefix -- the same
/// shape a real reverse proxy would present.
class _FakeComfyServer {
  _FakeComfyServer._(this._server);

  static const _prefix = '/proxy';

  final HttpServer _server;
  final List<String> requestPaths = [];
  final List<String> uploadedFileNames = [];
  final List<Map<String, dynamic>> deleteQueueBodies = [];
  int interruptCalls = 0;

  Map<String, dynamic> promptResponse = {'prompt_id': 'p1', 'number': 1};
  int promptStatusCode = 200;
  Map<String, dynamic> uploadResponse = {
    'name': 'uploaded.png',
    'subfolder': '',
    'type': 'input',
  };
  List<String> queueRunning = [];
  List<String> queuePending = [];
  final Map<String, Map<String, dynamic>> historyByPromptId = {};
  List<String> wsFrames = [];
  bool closeSocketAfterFrames = false;

  ComfyEndpoint get endpoint =>
      ComfyEndpoint.parse('http://127.0.0.1:${_server.port}$_prefix');

  static Future<_FakeComfyServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeComfyServer._(server);
    unawaited(fake._serve());
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requestPaths.add(path);
    if (!path.startsWith(_prefix)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final leaf = path.substring(_prefix.length);

    if (leaf == '/ws') {
      final socket = await WebSocketTransformer.upgrade(request);
      for (final frame in wsFrames) {
        socket.add(frame);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (closeSocketAfterFrames) await socket.close();
      return;
    }

    if (leaf == '/system_stats' && request.method == 'GET') {
      return _respondJson(request, {});
    }
    if (leaf == '/object_info' && request.method == 'GET') {
      return _respondJson(request, {});
    }
    if (leaf == '/upload/image' && request.method == 'POST') {
      final name = await _readMultipartFileName(request);
      if (name != null) uploadedFileNames.add(name);
      return _respondJson(request, uploadResponse);
    }
    if (leaf == '/prompt' && request.method == 'POST') {
      await utf8.decoder.bind(request).join();
      return _respondJson(
        request,
        promptResponse,
        statusCode: promptStatusCode,
      );
    }
    if (leaf == '/queue' && request.method == 'GET') {
      return _respondJson(request, {
        'queue_running': queueRunning.map((id) => [0, id]).toList(),
        'queue_pending': queuePending.map((id) => [0, id]).toList(),
      });
    }
    if (leaf == '/queue' && request.method == 'POST') {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) deleteQueueBodies.add(decoded);
      return _respondJson(request, {});
    }
    if (leaf == '/interrupt' && request.method == 'POST') {
      interruptCalls++;
      return _respondJson(request, {});
    }
    if (leaf.startsWith('/history/') && request.method == 'GET') {
      final promptId = leaf.substring('/history/'.length);
      final record = historyByPromptId[promptId];
      return _respondJson(request, record == null ? {} : {promptId: record});
    }

    request.response.statusCode = 404;
    await request.response.close();
  }

  Future<void> _respondJson(
    HttpRequest request,
    Object? body, {
    int statusCode = 200,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  /// Reads just enough of a multipart/form-data body to recover the
  /// uploaded file's declared filename, without pulling in a multipart
  /// parsing package for one test file.
  Future<String?> _readMultipartFileName(HttpRequest request) async {
    final bytes = await request.fold<BytesBuilder>(
      BytesBuilder(),
      (builder, chunk) => builder..add(chunk),
    );
    final text = latin1.decode(bytes.takeBytes(), allowInvalid: true);
    final match = RegExp('filename="([^"]*)"').firstMatch(text);
    return match?.group(1);
  }
}
