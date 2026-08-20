import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/comfy_workflow.dart';

abstract interface class ComfySocketTransport {
  Stream<Object?> get messages;

  Future<void> close();
}

abstract interface class ComfySocketConnector {
  Future<ComfySocketTransport> connect(Uri uri);
}

final class IoComfySocketConnector implements ComfySocketConnector {
  const IoComfySocketConnector();

  @override
  Future<ComfySocketTransport> connect(Uri uri) async {
    final socket = await WebSocket.connect(uri.toString());
    return _IoComfySocketTransport(socket);
  }
}

final class _IoComfySocketTransport implements ComfySocketTransport {
  const _IoComfySocketTransport(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object?> get messages => _socket;

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

abstract interface class ComfyUiSocketFactory {
  ComfyUiSocket create();
}

final class DefaultComfyUiSocketFactory implements ComfyUiSocketFactory {
  const DefaultComfyUiSocketFactory({
    this.connector = const IoComfySocketConnector(),
    this.maxTextBytes = ComfyUiSocket.defaultMaxTextBytes,
  }) : assert(maxTextBytes > 0);

  final ComfySocketConnector connector;
  final int maxTextBytes;

  @override
  ComfyUiSocket create() =>
      ComfyUiSocket(connector: connector, maxTextBytes: maxTextBytes);
}

sealed class ComfyExecutionEvent {
  const ComfyExecutionEvent();
}

final class ComfyStatus extends ComfyExecutionEvent {
  const ComfyStatus(this.queueRemaining);

  final int? queueRemaining;
}

final class ComfyExecutionStarted extends ComfyExecutionEvent {
  const ComfyExecutionStarted();
}

final class ComfyCachedNodes extends ComfyExecutionEvent {
  const ComfyCachedNodes(this.nodeIds);

  final List<String> nodeIds;
}

final class ComfyProgress extends ComfyExecutionEvent {
  const ComfyProgress(this.nodeId, this.value, this.max);

  final String? nodeId;
  final int value;
  final int max;
}

final class ComfyExecuting extends ComfyExecutionEvent {
  const ComfyExecuting(this.nodeId);

  final String? nodeId;
}

final class ComfyExecuted extends ComfyExecutionEvent {
  const ComfyExecuted(this.nodeId, this.outputs);

  final String nodeId;
  final List<ComfyOutputRef> outputs;
}

final class ComfySucceeded extends ComfyExecutionEvent {
  const ComfySucceeded(this.outputs);

  final List<ComfyOutputRef> outputs;
}

final class ComfyExecutionError extends ComfyExecutionEvent {
  const ComfyExecutionError(this.message);

  final String message;
}

final class ComfyInterrupted extends ComfyExecutionEvent {
  const ComfyInterrupted();
}

final class ComfySocketLost extends ComfyExecutionEvent {
  const ComfySocketLost(this.message);

  final String message;
}

final class ComfyUiSocket {
  ComfyUiSocket({
    this.connector = const IoComfySocketConnector(),
    this.maxTextBytes = defaultMaxTextBytes,
  }) {
    if (maxTextBytes <= 0) {
      throw ArgumentError.value(
        maxTextBytes,
        'maxTextBytes',
        'Must be positive',
      );
    }
  }

  static const int defaultMaxTextBytes = 2 * 1024 * 1024;

  final ComfySocketConnector connector;
  final int maxTextBytes;

  Stream<ComfyExecutionEvent> watchExecution(
    ComfyEndpoint endpoint, {
    required String clientId,
    required String promptId,
  }) => _ComfyExecutionWatch(
    connector: connector,
    uri: endpoint.websocketUri(clientId),
    promptId: promptId,
    maxTextBytes: maxTextBytes,
  ).stream;
}

final class _ComfyExecutionWatch {
  _ComfyExecutionWatch({
    required this.connector,
    required this.uri,
    required this.promptId,
    required this.maxTextBytes,
  }) {
    _controller = StreamController<ComfyExecutionEvent>(
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  final ComfySocketConnector connector;
  final Uri uri;
  final String promptId;
  final int maxTextBytes;

  late final StreamController<ComfyExecutionEvent> _controller;
  ComfySocketTransport? _transport;
  StreamSubscription<Object?>? _messages;
  Future<void>? _transportClose;
  bool _finished = false;
  bool _cancelled = false;
  bool _paused = false;

  Stream<ComfyExecutionEvent> get stream => _controller.stream;

  void _onListen() {
    try {
      final connection = connector.connect(uri);
      unawaited(_attach(connection));
    } catch (error) {
      unawaited(
        _finish(lost: ComfySocketLost('ComfyUI WebSocket lost: $error')),
      );
    }
  }

  Future<void> _attach(Future<ComfySocketTransport> connection) async {
    try {
      final transport = await connection;
      _transport = transport;
      if (_finished || _cancelled) {
        await _closeTransport();
        return;
      }
      final messages = transport.messages.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
      _messages = messages;
      if (_paused) messages.pause();
      if (_finished || _cancelled) {
        try {
          await _cancelMessages();
        } finally {
          await _closeTransport();
        }
      }
    } catch (error) {
      if (!_finished && !_cancelled) {
        await _finish(lost: ComfySocketLost('ComfyUI WebSocket lost: $error'));
      }
    }
  }

  void _onMessage(Object? message) {
    if (_finished) return;
    final event = _decodeMessage(
      message,
      promptId: promptId,
      maxTextBytes: maxTextBytes,
    );
    if (event == null) return;
    _controller.add(event);
    if (_isTerminal(event)) {
      unawaited(_finish());
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    unawaited(_finish(lost: ComfySocketLost('ComfyUI WebSocket lost: $error')));
  }

  void _onDone() {
    unawaited(
      _finish(
        lost: const ComfySocketLost(
          'ComfyUI WebSocket closed before execution completed',
        ),
      ),
    );
  }

  void _onPause() {
    _paused = true;
    _messages?.pause();
  }

  void _onResume() {
    _paused = false;
    _messages?.resume();
  }

  Future<void> _onCancel() async {
    _cancelled = true;
    _finished = true;
    try {
      await _cancelMessages();
    } finally {
      await _closeTransport();
    }
  }

  Future<void> _finish({ComfySocketLost? lost}) async {
    if (_finished) return;
    _finished = true;
    if (lost != null && !_cancelled) _controller.add(lost);
    try {
      await _cancelMessages();
    } finally {
      await _closeTransport();
      if (!_cancelled && !_controller.isClosed) {
        await _controller.close();
      }
    }
  }

  Future<void> _cancelMessages() async {
    try {
      await _messages?.cancel();
    } catch (_) {
      // Upstream cancellation is cleanup-only, like transport close.
    }
  }

  Future<void> _closeTransport() {
    final transport = _transport;
    if (transport == null) return Future<void>.value();
    return _transportClose ??= () async {
      try {
        await transport.close();
      } catch (_) {
        // Cleanup failure cannot change an execution event already emitted.
      }
    }();
  }
}

bool _isTerminal(ComfyExecutionEvent event) =>
    event is ComfySucceeded ||
    event is ComfyExecutionError ||
    event is ComfyInterrupted;

ComfyExecutionEvent? _decodeMessage(
  Object? message, {
  required String promptId,
  required int maxTextBytes,
}) {
  if (message is! String ||
      message.length > maxTextBytes ||
      utf8.encode(message).length > maxTextBytes) {
    return null;
  }

  try {
    final envelope = _jsonObject(jsonDecode(message));
    if (envelope == null || envelope['type'] is! String) return null;
    final data = _jsonObject(envelope['data']);
    if (data == null) return null;
    if (data.containsKey('prompt_id') && data['prompt_id'] != promptId) {
      return null;
    }

    return switch (envelope['type'] as String) {
      'status' => ComfyStatus(_queueRemaining(data)),
      'execution_start' => const ComfyExecutionStarted(),
      'execution_cached' => _cachedNodes(data),
      'progress' => _progress(data),
      'executing' => _executing(data),
      'executed' => _executed(data),
      'execution_success' => const ComfySucceeded(<ComfyOutputRef>[]),
      'execution_error' => ComfyExecutionError(_errorMessage(data)),
      'execution_interrupted' => const ComfyInterrupted(),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

ComfyCachedNodes? _cachedNodes(JsonObject data) {
  final rawNodes = data['nodes'];
  if (rawNodes is! List) return null;
  final nodeIds = <String>[];
  for (final node in rawNodes) {
    if (node is String) nodeIds.add(node);
  }
  return ComfyCachedNodes(List<String>.unmodifiable(nodeIds));
}

ComfyProgress? _progress(JsonObject data) {
  final node = data['node'];
  final value = _integer(data['value']);
  final max = _integer(data['max']);
  if (node != null && node is! String || value == null || max == null) {
    return null;
  }
  return ComfyProgress(node as String?, value, max);
}

ComfyExecuting? _executing(JsonObject data) {
  final node = data['node'];
  if (node != null && node is! String) return null;
  return ComfyExecuting(node as String?);
}

ComfyExecuted? _executed(JsonObject data) {
  final node = data['node'];
  if (node is! String) return null;
  return ComfyExecuted(
    node,
    List<ComfyOutputRef>.unmodifiable(_collectOutputs(data['output'])),
  );
}

int? _queueRemaining(JsonObject data) {
  final direct = _jsonObject(data['exec_info']);
  final olderStatus = _jsonObject(data['status']);
  final older = _jsonObject(olderStatus?['exec_info']);
  return _integer(direct?['queue_remaining'] ?? older?['queue_remaining']);
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

String _errorMessage(JsonObject data) {
  for (final key in const ['exception_message', 'message', 'exception_type']) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return 'ComfyUI execution failed';
}

List<ComfyOutputRef> _collectOutputs(Object? root) {
  final outputs = <ComfyOutputRef>[];
  final seen = <String>{};
  final pending = <Object?>[root];

  while (pending.isNotEmpty) {
    final value = pending.removeLast();
    if (value is List) {
      for (var index = value.length - 1; index >= 0; index--) {
        pending.add(value[index]);
      }
      continue;
    }

    final object = _jsonObject(value);
    if (object == null) continue;
    final filename = object['filename'];
    final subfolder = object['subfolder'];
    final type = object['type'];
    if (filename is String &&
        type is String &&
        (subfolder == null || subfolder is String)) {
      try {
        final output = ComfyOutputRef(
          filename: filename,
          subfolder: subfolder as String? ?? '',
          type: type,
        );
        final key =
            '${output.type}\u0000${output.subfolder}\u0000${output.filename}';
        if (seen.add(key)) outputs.add(output);
      } on FormatException {
        // Custom-node output metadata may contain non-file or unsafe paths.
      }
    }
    final values = object.values.toList(growable: false);
    for (var index = values.length - 1; index >= 0; index--) {
      pending.add(values[index]);
    }
  }

  return outputs;
}

JsonObject? _jsonObject(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}
