import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/services/comfyui_socket.dart';

void main() {
  const clientId = 'client id';
  const promptId = 'mine';

  group('ComfyUiSocket connection lifecycle', () {
    test('uses endpoint websocket URI for HTTP and HTTPS', () async {
      for (final (raw, expected) in [
        (
          'http://host:8188/proxy',
          'ws://host:8188/proxy/ws?clientId=client+id',
        ),
        (
          'https://host.example/proxy',
          'wss://host.example/proxy/ws?clientId=client+id',
        ),
      ]) {
        final transport = _FakeSocketTransport();
        final connector = _FakeConnector([transport]);
        final eventsFuture = ComfyUiSocket(connector: connector)
            .watchExecution(
              ComfyEndpoint.parse(raw),
              clientId: clientId,
              promptId: promptId,
            )
            .toList();

        await transport.messagesController.close();
        final events = await eventsFuture;

        expect(connector.connectedUris.single.toString(), expected);
        expect(events, hasLength(1));
        expect(events.single, isA<ComfySocketLost>());
        expect(transport.closeCalls, 1);
      }
    });

    test(
      'default factory creates a fresh socket and transport per watch',
      () async {
        final firstTransport = _FakeSocketTransport();
        final secondTransport = _FakeSocketTransport();
        final connector = _FakeConnector([firstTransport, secondTransport]);
        final factory = DefaultComfyUiSocketFactory(connector: connector);
        final firstSocket = factory.create();
        final secondSocket = factory.create();

        expect(firstSocket, isNot(same(secondSocket)));

        final firstEvents = firstSocket
            .watchExecution(
              ComfyEndpoint.parse('http://host:8188'),
              clientId: 'first',
              promptId: promptId,
            )
            .toList();
        final secondEvents = secondSocket
            .watchExecution(
              ComfyEndpoint.parse('http://host:8188'),
              clientId: 'second',
              promptId: promptId,
            )
            .toList();

        await firstTransport.messagesController.close();
        await secondTransport.messagesController.close();
        await firstEvents;
        await secondEvents;

        expect(connector.connectedUris, hasLength(2));
        expect(firstTransport.closeCalls, 1);
        expect(secondTransport.closeCalls, 1);
      },
    );

    test('close before terminal emits exactly one socket-lost event', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter(const []);

      expect(events.whereType<ComfySocketLost>(), hasLength(1));
      expect(events.whereType<ComfySucceeded>(), isEmpty);
      expect(harness.transport.closeCalls, 1);
    });

    test(
      'stream error before terminal emits exactly one socket-lost event',
      () async {
        final harness = _SocketHarness();
        final eventsFuture = harness.watch();

        harness.transport.messagesController.addError(
          StateError('network down'),
        );
        await harness.transport.messagesController.close();
        final events = await eventsFuture;

        expect(events.whereType<ComfySocketLost>(), hasLength(1));
        expect(
          events.whereType<ComfySocketLost>().single.message,
          contains('network down'),
        );
        expect(harness.transport.closeCalls, 1);
      },
    );

    test('connector error becomes one socket-lost event', () async {
      final connector = _FakeConnector.error(StateError('refused'));

      final events = await ComfyUiSocket(connector: connector)
          .watchExecution(
            ComfyEndpoint.parse('http://host:8188'),
            clientId: clientId,
            promptId: promptId,
          )
          .toList();

      expect(events.whereType<ComfySocketLost>(), hasLength(1));
      expect(
        events.whereType<ComfySocketLost>().single.message,
        contains('refused'),
      );
    });

    test('synchronous connector error becomes one socket-lost event', () async {
      final events =
          await ComfyUiSocket(connector: _SynchronousErrorConnector())
              .watchExecution(
                ComfyEndpoint.parse('http://host:8188'),
                clientId: clientId,
                promptId: promptId,
              )
              .toList();

      expect(events.whereType<ComfySocketLost>(), hasLength(1));
      expect(
        events.whereType<ComfySocketLost>().single.message,
        contains('sync refused'),
      );
    });

    test('listener cancellation closes the transport exactly once', () async {
      final transport = _FakeSocketTransport();
      final connector = _FakeConnector([transport]);
      final subscription = ComfyUiSocket(connector: connector)
          .watchExecution(
            ComfyEndpoint.parse('http://host:8188'),
            clientId: clientId,
            promptId: promptId,
          )
          .listen((_) {});
      await connector.firstConnection;

      await subscription.cancel();

      expect(transport.closeCalls, 1);
    });

    test(
      'cancellation does not wait for a pending connector and closes a late transport once',
      () async {
        final connector = _PendingConnector();
        final subscription = ComfyUiSocket(connector: connector)
            .watchExecution(
              ComfyEndpoint.parse('http://host:8188'),
              clientId: clientId,
              promptId: promptId,
            )
            .listen((_) {});
        await connector.called;

        final cancellation = subscription.cancel();
        final firstCompletion = await Future.any([
          cancellation.then((_) => 'cancelled'),
          Future<void>.delayed(Duration.zero).then((_) => 'connector pending'),
        ]);
        final lateTransport = _FakeSocketTransport();
        connector.complete(lateTransport);
        await cancellation;
        await lateTransport.closed;

        expect(firstCompletion, 'cancelled');
        expect(lateTransport.closeCalls, 1);
      },
    );

    test(
      'listener cancellation swallows upstream cancel errors and closes transport',
      () async {
        final transport = _FakeSocketTransport(
          onCancel: () => Future<void>.error(StateError('cancel failed')),
        );
        final connector = _FakeConnector([transport]);
        final subscription = ComfyUiSocket(connector: connector)
            .watchExecution(
              ComfyEndpoint.parse('http://host:8188'),
              clientId: clientId,
              promptId: promptId,
            )
            .listen((_) {});
        await transport.listened;

        await expectLater(subscription.cancel(), completes);
        await transport.closed;

        expect(transport.closeCalls, 1);
      },
    );

    test(
      'terminal stream closes when upstream cancellation reports an error',
      () async {
        final transport = _FakeSocketTransport(
          onCancel: () => Future<void>.error(StateError('cancel failed')),
        );
        final connector = _FakeConnector([transport]);
        final events = ComfyUiSocket(connector: connector)
            .watchExecution(
              ComfyEndpoint.parse('http://host:8188'),
              clientId: clientId,
              promptId: promptId,
            )
            .toList();
        await transport.listened;

        transport.messagesController.add(
          _frame('execution_success', {'prompt_id': promptId}),
        );
        final completed = await events.timeout(const Duration(seconds: 1));
        await transport.closed;

        expect(completed, hasLength(1));
        expect(completed.single, isA<ComfySucceeded>());
        expect(transport.closeCalls, 1);
      },
    );
  });

  group('ComfyUiSocket decoding', () {
    test('decodes current and older promptless status shapes', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        _frame('status', {
          'exec_info': {'queue_remaining': 4},
        }),
        _frame('status', {
          'status': {
            'exec_info': {'queue_remaining': 3},
          },
        }),
      ]);

      expect(
        events.whereType<ComfyStatus>().map((event) => event.queueRemaining),
        [4, 3],
      );
    });

    test('decodes execution start and cached node IDs', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        _frame('execution_start', {'prompt_id': promptId}),
        _frame('execution_cached', {
          'prompt_id': promptId,
          'nodes': ['3', '7'],
        }),
      ]);

      expect(events.whereType<ComfyExecutionStarted>(), hasLength(1));
      expect(events.whereType<ComfyCachedNodes>().single.nodeIds, ['3', '7']);
    });

    test('filters other prompts and never treats close as success', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        _frame('progress', {
          'prompt_id': 'other',
          'node': '6',
          'value': 1,
          'max': 2,
        }),
        _frame('executing', {'prompt_id': promptId, 'node': '7'}),
      ]);

      expect(events.whereType<ComfyProgress>(), isEmpty);
      expect(events.whereType<ComfyExecuting>().single.nodeId, '7');
      expect(events.last, isA<ComfySocketLost>());
      expect(events.whereType<ComfySucceeded>(), isEmpty);
    });

    test('decodes progress and keeps executing null nonterminal', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        _frame('progress', {
          'prompt_id': promptId,
          'node': '8',
          'value': 2,
          'max': 10,
        }),
        _frame('executing', {'prompt_id': promptId, 'node': null}),
      ]);

      final progress = events.whereType<ComfyProgress>().single;
      expect(progress.nodeId, '8');
      expect(progress.value, 2);
      expect(progress.max, 10);
      expect(events.whereType<ComfyExecuting>().single.nodeId, isNull);
      expect(events.last, isA<ComfySocketLost>());
    });

    test('executed recursively keeps only safe output references', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        _frame('executed', {
          'prompt_id': promptId,
          'node': '9',
          'output': {
            'images': [
              {'filename': 'safe.png', 'subfolder': 'jobs/1', 'type': 'output'},
              {'filename': '../escape.png', 'subfolder': '', 'type': 'output'},
              {'filename': 'wrong.png', 'subfolder': '', 'type': 'custom'},
            ],
            'nested': {
              'files': [
                {
                  'filename': 'preview.webp',
                  'subfolder': 'temp',
                  'type': 'temp',
                },
                {
                  'filename': 'safe.png',
                  'subfolder': 'jobs/1',
                  'type': 'output',
                },
              ],
            },
          },
        }),
      ]);

      final executed = events.whereType<ComfyExecuted>().single;
      expect(executed.nodeId, '9');
      expect(executed.outputs.map((output) => output.filename), [
        'safe.png',
        'preview.webp',
      ]);
      expect(executed.outputs.first.subfolder, 'jobs/1');
      expect(executed.outputs.last.type, 'temp');
    });

    test(
      'official execution success emits empty outputs and stops decoding',
      () async {
        final harness = _SocketHarness();

        final events = await harness.closeAfter([
          _frame('execution_success', {
            'prompt_id': promptId,
            'outputs': [
              {'filename': 'not-official.png', 'type': 'output'},
            ],
          }),
          _frame('progress', {'prompt_id': promptId, 'value': 1, 'max': 2}),
        ]);

        expect(events, hasLength(1));
        expect(events.single, isA<ComfySucceeded>());
        expect((events.single as ComfySucceeded).outputs, isEmpty);
        expect(events.whereType<ComfySocketLost>(), isEmpty);
        expect(harness.transport.closeCalls, 1);
      },
    );

    test(
      'execution error is terminal and exposes the server message',
      () async {
        final harness = _SocketHarness();

        final events = await harness.closeAfter([
          _frame('execution_error', {
            'prompt_id': promptId,
            'node_id': '4',
            'exception_message': 'CUDA out of memory',
          }),
          _frame('status', {
            'exec_info': {'queue_remaining': 0},
          }),
        ]);

        expect(events, hasLength(1));
        expect(events.single, isA<ComfyExecutionError>());
        expect(
          (events.single as ComfyExecutionError).message,
          'CUDA out of memory',
        );
        expect(events.whereType<ComfySocketLost>(), isEmpty);
      },
    );

    test('execution interruption is terminal', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        _frame('execution_interrupted', {'prompt_id': promptId}),
        _frame('executing', {'prompt_id': promptId, 'node': 'later'}),
      ]);

      expect(events, hasLength(1));
      expect(events.single, isA<ComfyInterrupted>());
      expect(events.whereType<ComfySocketLost>(), isEmpty);
    });

    test('mismatched terminal frames cannot suppress socket loss', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        _frame('execution_success', {'prompt_id': 'other'}),
        _frame('execution_error', {
          'prompt_id': 'other',
          'exception_message': 'other failed',
        }),
        _frame('executing', {'prompt_id': promptId, 'node': '7'}),
      ]);

      expect(events.whereType<ComfySucceeded>(), isEmpty);
      expect(events.whereType<ComfyExecutionError>(), isEmpty);
      expect(events.whereType<ComfyExecuting>(), hasLength(1));
      expect(events.whereType<ComfySocketLost>(), hasLength(1));
    });

    test('ignores malformed, unknown, non-object, and binary frames', () async {
      final harness = _SocketHarness();

      final events = await harness.closeAfter([
        '{',
        jsonEncode(['not', 'an', 'object']),
        jsonEncode({'type': 'future_event', 'data': {}}),
        jsonEncode({'type': 'executing', 'data': 'not-an-object'}),
        Uint8List.fromList([0, 1, 2, 3]),
        _frame('execution_start', {'prompt_id': promptId}),
      ]);

      expect(events.whereType<ComfyExecutionStarted>(), hasLength(1));
      expect(events.whereType<ComfySocketLost>(), hasLength(1));
      expect(events, hasLength(2));
    });

    test('rejects UTF-8 text above 2 MiB before JSON decoding', () async {
      final harness = _SocketHarness();
      final padding = List<String>.filled(2 * 1024 * 1024, 'x').join();
      final oversizedTerminal = jsonEncode({
        'type': 'execution_success',
        'data': {'prompt_id': promptId, 'padding': padding},
      });
      expect(
        utf8.encode(oversizedTerminal).length,
        greaterThan(2 * 1024 * 1024),
      );

      final events = await harness.closeAfter([
        oversizedTerminal,
        _frame('execution_start', {'prompt_id': promptId}),
      ]);

      expect(events.whereType<ComfySucceeded>(), isEmpty);
      expect(events.whereType<ComfyExecutionStarted>(), hasLength(1));
      expect(events.whereType<ComfySocketLost>(), hasLength(1));
    });
  });
}

String _frame(String type, Map<String, Object?> data) =>
    jsonEncode({'type': type, 'data': data});

final class _SocketHarness {
  _SocketHarness()
    : transport = _FakeSocketTransport(),
      connector = _FakeConnector.pending() {
    connector.addTransport(transport);
    socket = ComfyUiSocket(connector: connector);
  }

  final _FakeSocketTransport transport;
  final _FakeConnector connector;
  late final ComfyUiSocket socket;

  Future<List<ComfyExecutionEvent>> watch() => socket
      .watchExecution(
        ComfyEndpoint.parse('http://host:8188/proxy'),
        clientId: 'client id',
        promptId: 'mine',
      )
      .toList();

  Future<List<ComfyExecutionEvent>> closeAfter(
    Iterable<Object?> messages,
  ) async {
    final events = watch();
    for (final message in messages) {
      transport.messagesController.add(message);
    }
    await transport.messagesController.close();
    return events;
  }
}

final class _FakeSocketTransport implements ComfySocketTransport {
  _FakeSocketTransport({FutureOr<void> Function()? onCancel}) {
    messagesController = StreamController<Object?>(
      onListen: () {
        if (!_listened.isCompleted) _listened.complete();
      },
      onCancel: onCancel,
    );
  }

  late final StreamController<Object?> messagesController;
  final Completer<void> _listened = Completer<void>();
  final Completer<void> _closed = Completer<void>();
  int closeCalls = 0;

  Future<void> get listened => _listened.future;

  Future<void> get closed => _closed.future;

  @override
  Stream<Object?> get messages => messagesController.stream;

  @override
  Future<void> close() async {
    closeCalls++;
    if (!_closed.isCompleted) _closed.complete();
  }
}

final class _PendingConnector implements ComfySocketConnector {
  final Completer<void> _called = Completer<void>();
  final Completer<ComfySocketTransport> _connection =
      Completer<ComfySocketTransport>();

  Future<void> get called => _called.future;

  void complete(ComfySocketTransport transport) {
    _connection.complete(transport);
  }

  @override
  Future<ComfySocketTransport> connect(Uri uri) {
    if (!_called.isCompleted) _called.complete();
    return _connection.future;
  }
}

final class _SynchronousErrorConnector implements ComfySocketConnector {
  @override
  Future<ComfySocketTransport> connect(Uri uri) {
    throw StateError('sync refused');
  }
}

final class _FakeConnector implements ComfySocketConnector {
  _FakeConnector(List<_FakeSocketTransport> transports)
    : _transports = List.of(transports),
      _error = null;

  _FakeConnector.pending() : _transports = [], _error = null;

  _FakeConnector.error(Object error) : _transports = [], _error = error;

  final List<_FakeSocketTransport> _transports;
  final Object? _error;
  final List<Uri> connectedUris = [];
  final Completer<void> _firstConnection = Completer<void>();

  Future<void> get firstConnection => _firstConnection.future;

  void addTransport(_FakeSocketTransport transport) {
    _transports.add(transport);
  }

  @override
  Future<ComfySocketTransport> connect(Uri uri) async {
    connectedUris.add(uri);
    if (!_firstConnection.isCompleted) _firstConnection.complete();
    if (_error case final error?) throw error;
    if (_transports.isEmpty) throw StateError('No fake transport available');
    return _transports.removeAt(0);
  }
}
