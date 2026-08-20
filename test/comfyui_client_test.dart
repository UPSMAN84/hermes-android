import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/services/comfyui_client.dart';
import 'package:http/http.dart' as http;

void main() {
  group('ComfyUiClient', () {
    test(
      'preserves a reverse-proxy path for connection and view routes',
      () async {
        final client = _RecordingClient((request, _) {
          if (request.url.path.endsWith('/system_stats')) {
            return _jsonResponse({
              'system': {'comfyui_version': '0.3.50'},
              'devices': <Object?>[],
            });
          }
          return _jsonResponse({
            'KSampler': {'display_name': 'KSampler'},
          });
        });
        final comfy = _comfy(client);

        final info = await comfy.checkConnection();

        expect(info.systemStats['system'], isA<Map<String, dynamic>>());
        expect(info.objectInfo, contains('KSampler'));
        expect(client.requests.map((record) => record.request.url.toString()), [
          'http://host:8188/proxy/system_stats',
          'http://host:8188/proxy/object_info',
        ]);
        expect(
          comfy
              .buildViewUri(
                ComfyOutputRef(
                  filename: 'final image.png',
                  subfolder: 'job 1',
                  type: 'output',
                ),
              )
              .toString(),
          'http://host:8188/proxy/view?filename=final+image.png&subfolder=job+1&type=output',
        );
        expect(comfy.openFrontend().toString(), 'http://host:8188/proxy');
      },
    );

    test('getObjectInfo returns the decoded JSON object', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'LoadImage': {'input': <String, Object?>{}},
        }),
      );

      final result = await _comfy(client).getObjectInfo();

      expect(result, contains('LoadImage'));
      expect(client.requests.single.request.method, 'GET');
      expect(client.requests.single.request.url.path, '/proxy/object_info');
    });

    test(
      'upload sends multipart image and uses the server output reference',
      () async {
        final client = _RecordingClient(
          (_, _) => _jsonResponse({
            'name': 'server.png',
            'subfolder': 'uploads',
            'type': 'input',
          }),
        );

        final output = await _comfy(
          client,
        ).uploadImage(_pngBytes, fileName: 'local.png');

        expect(output.filename, 'server.png');
        expect(output.subfolder, 'uploads');
        expect(output.type, 'input');
        final request = client.requests.single.request;
        expect(request, isA<http.MultipartRequest>());
        expect(request.method, 'POST');
        expect(request.url.path, '/proxy/upload/image');
        final multipart = request as http.MultipartRequest;
        expect(multipart.files.single.field, 'image');
        expect(multipart.files.single.filename, 'local.png');
        expect(multipart.files.single.length, _pngBytes.length);
        expect(multipart.files.single.contentType.toString(), 'image/png');
        expect(client.requests.single.body, containsAllInOrder(_pngBytes));
      },
    );

    test('upload maps jpg files to the image/jpeg multipart subtype', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'name': 'server.jpg',
          'subfolder': 'uploads',
          'type': 'input',
        }),
      );

      await _comfy(client).uploadImage(_jpegBytes, fileName: 'local.jpg');

      final request = client.requests.single.request as http.MultipartRequest;
      expect(request.files.single.contentType.toString(), 'image/jpeg');
    });

    test('upload maps tif and tiff files to image/tiff', () async {
      for (final extension in ['tif', 'tiff']) {
        final client = _RecordingClient(
          (_, _) => _jsonResponse({
            'name': 'server.$extension',
            'subfolder': 'uploads',
            'type': 'input',
          }),
        );

        await _comfy(
          client,
        ).uploadImage(_tiffBytes, fileName: 'local.$extension');

        final request = client.requests.single.request as http.MultipartRequest;
        expect(
          request.files.single.contentType.toString(),
          'image/tiff',
          reason: '.$extension must use the registered TIFF media subtype',
        );
      }
    });

    test('upload rejects unsafe filenames before network IO', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse(<String, Object?>{}),
      );

      await expectLater(
        _comfy(client).uploadImage(_pngBytes, fileName: '../local.png'),
        throwsA(isA<ArgumentError>()),
      );

      expect(client.requests, isEmpty);
    });

    test('upload rejects non-image extensions before network IO', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse(<String, Object?>{}),
      );

      await expectLater(
        _comfy(client).uploadImage(_pngBytes, fileName: 'local.exe'),
        throwsA(isA<ArgumentError>()),
      );

      expect(client.requests, isEmpty);
    });

    test(
      'upload rejects bytes whose magic does not match the extension',
      () async {
        final client = _RecordingClient(
          (_, _) => _jsonResponse(<String, Object?>{}),
        );

        await expectLater(
          _comfy(client).uploadImage(_jpegBytes, fileName: 'local.png'),
          throwsA(isA<ArgumentError>()),
        );

        expect(client.requests, isEmpty);
      },
    );

    test(
      'upload rejects processed bytes over its limit before network IO',
      () async {
        final client = _RecordingClient(
          (_, _) => _jsonResponse(<String, Object?>{}),
        );

        await expectLater(
          _comfy(
            client,
            maxUploadBytes: 7,
          ).uploadImage(_pngBytes, fileName: 'local.png'),
          throwsA(isA<ArgumentError>()),
        );

        expect(client.requests, isEmpty);
      },
    );

    test(
      'submitPrompt sends the graph and stable client ID exactly once',
      () async {
        final client = _RecordingClient(
          (_, _) => _jsonResponse({
            'prompt_id': 'prompt-1',
            'number': 7,
            'node_errors': <String, Object?>{},
          }),
        );
        final graph = <String, dynamic>{
          '1': {'class_type': 'KSampler', 'inputs': <String, Object?>{}},
        };

        final submission = await _comfy(client).submitPrompt(graph);

        expect(submission.promptId, 'prompt-1');
        expect(submission.number, 7);
        expect(submission.nodeErrors, isEmpty);
        expect(client.requests, hasLength(1));
        expect(client.requests.single.request.method, 'POST');
        expect(client.requests.single.request.url.path, '/proxy/prompt');
        expect(jsonDecode(utf8.decode(client.requests.single.body)), {
          'prompt': graph,
          'client_id': 'client-1',
        });
      },
    );

    test('accepted prompt preserves nonempty partial node errors', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'prompt_id': 'accepted-partial',
          'number': 8,
          'node_errors': {
            '7': {
              'class_type': 'CheckpointLoaderSimple',
              'errors': [
                {
                  'type': 'value_not_in_list',
                  'message': 'Value not in list',
                  'details': 'ckpt_name',
                },
              ],
            },
          },
        }),
      );

      final submission = await _comfy(client).submitPrompt(<String, dynamic>{});

      expect(submission.promptId, 'accepted-partial');
      expect(submission.nodeErrors, {
        '7': {
          'class_type': 'CheckpointLoaderSimple',
          'errors': [
            {
              'type': 'value_not_in_list',
              'message': 'Value not in list',
              'details': 'ckpt_name',
            },
          ],
        },
      });
      expect(client.requests, hasLength(1));
    });

    test('malformed prompt 2xx is uncertain after exactly one send', () async {
      final client = _RecordingClient(
        (_, _) => http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{not-json')),
          200,
        ),
      );

      await expectLater(
        _comfy(client).submitPrompt(<String, dynamic>{}),
        throwsA(isA<ComfySubmissionUncertainException>()),
      );

      expect(client.requests, hasLength(1));
    });

    test('missing prompt_id in a 2xx is uncertain after one send', () async {
      final client = _RecordingClient(
        (_, _) =>
            _jsonResponse({'number': 9, 'node_errors': <String, Object?>{}}),
      );

      await expectLater(
        _comfy(client).submitPrompt(<String, dynamic>{}),
        throwsA(isA<ComfySubmissionUncertainException>()),
      );

      expect(client.requests, hasLength(1));
    });

    test('blank prompt_id in a 2xx is uncertain after one send', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'prompt_id': '   ',
          'number': 10,
          'node_errors': <String, Object?>{},
        }),
      );

      await expectLater(
        _comfy(client).submitPrompt(<String, dynamic>{}),
        throwsA(isA<ComfySubmissionUncertainException>()),
      );

      expect(client.requests, hasLength(1));
    });

    test('oversized prompt 2xx is uncertain after exactly one send', () async {
      final client = _RecordingClient(
        (_, _) => http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('{"prompt_id":"accepted-but-too-large"}'),
          ),
          200,
        ),
      );

      await expectLater(
        _comfy(client, maxJsonBytes: 8).submitPrompt(<String, dynamic>{}),
        throwsA(isA<ComfySubmissionUncertainException>()),
      );

      expect(client.requests, hasLength(1));
    });

    test('prompt idle timeout sends once and becomes uncertain', () async {
      final client = _HangingPromptBodyClient();
      final comfy = _comfy(
        client,
        idleTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        comfy.submitPrompt({
          '1': {'class_type': 'KSampler', 'inputs': <String, Object?>{}},
        }),
        throwsA(isA<ComfySubmissionUncertainException>()),
      );

      expect(client.promptRequests, 1);
      await client.dispose();
    });

    test('prompt non-2xx headers stay definite when the body idles', () async {
      final client = _HangingPromptBodyClient(statusCode: 400);

      try {
        await _comfy(
          client,
          idleTimeout: const Duration(milliseconds: 10),
        ).submitPrompt(<String, dynamic>{});
        fail('Expected ComfyApiException');
      } on ComfySubmissionUncertainException {
        fail('A definite non-2xx status must not be uncertain');
      } on ComfyApiException catch (error) {
        expect(error.statusCode, 400);
      }

      expect(client.promptRequests, 1);
      await client.dispose();
    });

    test(
      'prompt validation response exposes top-level and node errors',
      () async {
        final client = _RecordingClient(
          (_, _) => _jsonResponse({
            'error': {
              'type': 'prompt_outputs_failed_validation',
              'message': 'Prompt outputs failed validation',
              'details': 'One output failed',
            },
            'node_errors': {
              '7': {
                'class_type': 'CheckpointLoaderSimple',
                'errors': [
                  {
                    'type': 'value_not_in_list',
                    'message': 'Value not in list',
                    'details': 'ckpt_name',
                  },
                ],
              },
            },
          }, statusCode: 400),
        );

        try {
          await _comfy(client).submitPrompt(<String, dynamic>{});
          fail('Expected ComfyApiException');
        } on ComfySubmissionUncertainException {
          fail('A definite HTTP response must not be uncertain');
        } on ComfyApiException catch (error) {
          expect(error.statusCode, 400);
          expect(error.errorType, 'prompt_outputs_failed_validation');
          expect(error.message, 'Prompt outputs failed validation');
          expect(error.details, 'One output failed');
          expect(error.nodeErrors, contains('7'));
        }
        expect(client.requests, hasLength(1));
      },
    );

    test('non-2xx response preserves its bounded response body', () async {
      final client = _RecordingClient(
        (_, _) => _textResponse('proxy unavailable', statusCode: 502),
      );

      try {
        await _comfy(client).getObjectInfo();
        fail('Expected ComfyApiException');
      } on ComfyApiException catch (error) {
        expect(error.statusCode, 502);
        expect(error.responseBody, 'proxy unavailable');
        expect(error.uri?.path, '/proxy/object_info');
      }
    });

    test('getQueue decodes running and pending prompt IDs', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'queue_running': [
            [
              3,
              'running-1',
              <String, Object?>{},
              {'client_id': 'client-1'},
              ['9'],
            ],
          ],
          'queue_pending': [
            [
              4,
              'pending-1',
              <String, Object?>{},
              {'client_id': 'client-1'},
              ['9'],
            ],
          ],
        }),
      );

      final queue = await _comfy(client).getQueue();

      expect(queue.runningPromptIds, ['running-1']);
      expect(queue.pendingPromptIds, ['pending-1']);
      expect(queue.contains('running-1'), isTrue);
      expect(queue.contains('missing'), isFalse);
      expect(client.requests.single.request.url.path, '/proxy/queue');
    });

    test('deleteQueuedPrompt posts only the target prompt ID', () async {
      final client = _RecordingClient((_, _) => _textResponse(''));

      await _comfy(client).deleteQueuedPrompt('prompt-2');

      expect(client.requests.single.request.method, 'POST');
      expect(client.requests.single.request.url.path, '/proxy/queue');
      expect(jsonDecode(utf8.decode(client.requests.single.body)), {
        'delete': ['prompt-2'],
      });
    });

    test('interrupt posts to the reverse-proxy interrupt route', () async {
      final client = _RecordingClient((_, _) => _textResponse(''));

      await _comfy(client).interrupt();

      expect(client.requests.single.request.method, 'POST');
      expect(client.requests.single.request.url.path, '/proxy/interrupt');
    });

    test('getHistory returns null when the prompt is absent', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse(<String, Object?>{}),
      );

      final result = await _comfy(client).getHistory('missing');

      expect(result, isNull);
      expect(client.requests.single.request.url.path, '/proxy/history/missing');
    });

    test('history outputs confirm completion when status is absent', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'done-1': {
            'outputs': {
              '7': {
                'images': [
                  {'filename': 'done.png', 'subfolder': '', 'type': 'output'},
                ],
              },
            },
          },
        }),
      );

      final result = await _comfy(client).getHistory('done-1');

      expect(result!.completed, isTrue);
      expect(result.outputs.single.filename, 'done.png');
    });

    test('history recursively keeps only safe output references', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'prompt 1': {
            'prompt': [
              1,
              'prompt 1',
              {
                '1': {
                  'inputs': {
                    'filename': 'input.png',
                    'subfolder': 'uploads',
                    'type': 'input',
                  },
                },
              },
            ],
            'outputs': {
              '7': {
                'images': [
                  {
                    'filename': 'safe.png',
                    'subfolder': 'jobs/1',
                    'type': 'output',
                  },
                  {
                    'filename': '../escape.png',
                    'subfolder': '',
                    'type': 'output',
                  },
                  {'filename': 'wrong.png', 'subfolder': '', 'type': 'custom'},
                ],
                'nested': {
                  'files': [
                    {
                      'filename': 'preview.webp',
                      'subfolder': 'temp',
                      'type': 'temp',
                    },
                  ],
                },
              },
            },
            'status': {
              'status_str': 'success',
              'completed': true,
              'messages': <Object?>[],
            },
          },
        }),
      );

      final result = await _comfy(client).getHistory('prompt 1');

      expect(result, isNotNull);
      expect(result!.promptId, 'prompt 1');
      expect(result.completed, isTrue);
      expect(result.status, 'success');
      expect(result.error, isNull);
      expect(result.outputs.map((output) => output.filename), [
        'safe.png',
        'preview.webp',
      ]);
      expect(
        client.requests.single.request.url.toString(),
        'http://host:8188/proxy/history/prompt%201',
      );
    });

    test('history exposes a structured execution error', () async {
      final client = _RecordingClient(
        (_, _) => _jsonResponse({
          'failed-1': {
            'outputs': <String, Object?>{},
            'status': {
              'status_str': 'error',
              'completed': false,
              'messages': [
                [
                  'execution_error',
                  {
                    'prompt_id': 'failed-1',
                    'node_id': '4',
                    'node_type': 'KSampler',
                    'exception_message': 'CUDA out of memory',
                  },
                ],
              ],
            },
          },
        }),
      );

      final result = await _comfy(client).getHistory('failed-1');

      expect(result!.completed, isFalse);
      expect(result.error?['node_id'], '4');
      expect(result.error?['exception_message'], 'CUDA out of memory');
    });

    test(
      'rejects a streamed JSON response above the configured ceiling',
      () async {
        final client = _RecordingClient(
          (_, _) => http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('{"too":"large"}')),
            200,
          ),
        );

        await expectLater(
          _comfy(client, maxJsonBytes: 8).getObjectInfo(),
          throwsA(
            isA<ComfyApiException>().having(
              (error) => error.message,
              'message',
              contains('8 bytes'),
            ),
          ),
        );
      },
    );

    test('resets the response idle timeout after every chunk', () async {
      final chunks = [utf8.encode('{"Load'), utf8.encode('Image":{}}')];
      final client = _RecordingClient(
        (_, _) => http.StreamedResponse(_spaced(chunks), 200),
      );

      final result = await _comfy(
        client,
        idleTimeout: const Duration(milliseconds: 40),
      ).getObjectInfo();

      expect(result, contains('LoadImage'));
    });

    test('non-prompt header timeout is an API error, not uncertain', () async {
      final client = _NeverHeadersClient();

      try {
        await _comfy(
          client,
          connectTimeout: const Duration(milliseconds: 10),
        ).getObjectInfo();
        fail('Expected ComfyApiException');
      } on ComfySubmissionUncertainException {
        fail('Only prompt submission ambiguity is uncertain');
      } on ComfyApiException catch (error) {
        expect(error.message, contains('headers'));
      }
      expect(client.requests, 1);
    });

    test('close does not close an injected HTTP client', () {
      final client = _RecordingClient(
        (_, _) => _jsonResponse(<String, Object?>{}),
      );
      final comfy = _comfy(client);

      comfy.close();
      comfy.close();

      expect(client.closed, isFalse);
    });
  });
}

ComfyUiClient _comfy(
  http.Client client, {
  Duration connectTimeout = const Duration(seconds: 10),
  Duration idleTimeout = const Duration(seconds: 30),
  int maxJsonBytes = 32 * 1024 * 1024,
  int maxUploadBytes = 25 * 1024 * 1024,
}) => ComfyUiClient(
  endpoint: ComfyEndpoint.parse('http://host:8188/proxy'),
  clientId: 'client-1',
  httpClient: client,
  connectTimeout: connectTimeout,
  idleTimeout: idleTimeout,
  maxJsonBytes: maxJsonBytes,
  maxUploadBytes: maxUploadBytes,
);

final Uint8List _pngBytes = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
]);

final Uint8List _jpegBytes = Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xd9]);

final Uint8List _tiffBytes = Uint8List.fromList(const [0x49, 0x49, 0x2a, 0x00]);

http.StreamedResponse _jsonResponse(Object? value, {int statusCode = 200}) {
  final body = utf8.encode(jsonEncode(value));
  return http.StreamedResponse(
    Stream<List<int>>.value(body),
    statusCode,
    contentLength: body.length,
    headers: const {'content-type': 'application/json'},
  );
}

http.StreamedResponse _textResponse(String value, {int statusCode = 200}) {
  final body = utf8.encode(value);
  return http.StreamedResponse(
    Stream<List<int>>.value(body),
    statusCode,
    contentLength: body.length,
    headers: const {'content-type': 'text/plain'},
  );
}

Stream<List<int>> _spaced(List<List<int>> chunks) async* {
  for (final chunk in chunks) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    yield chunk;
  }
}

final class _RecordedRequest {
  const _RecordedRequest(this.request, this.body);

  final http.BaseRequest request;
  final Uint8List body;
}

final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    Uint8List body,
  )
  handler;
  final List<_RecordedRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    requests.add(_RecordedRequest(request, body));
    return handler(request, body);
  }

  @override
  void close() {
    closed = true;
  }
}

final class _HangingPromptBodyClient extends http.BaseClient {
  _HangingPromptBodyClient({this.statusCode = 200});

  final int statusCode;
  final StreamController<List<int>> _body = StreamController<List<int>>();
  int promptRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    if (request.url.path.endsWith('/prompt')) promptRequests++;
    return http.StreamedResponse(_body.stream, statusCode);
  }

  Future<void> dispose() => _body.close();
}

final class _NeverHeadersClient extends http.BaseClient {
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    requests++;
    return Completer<http.StreamedResponse>().future;
  }
}
