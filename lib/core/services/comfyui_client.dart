import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/comfy_workflow.dart';

final class ComfyConnectionInfo {
  const ComfyConnectionInfo({
    required this.systemStats,
    required this.objectInfo,
  });

  final JsonObject systemStats;
  final JsonObject objectInfo;
}

final class ComfyPromptSubmission {
  const ComfyPromptSubmission({
    required this.promptId,
    required this.number,
    required this.nodeErrors,
  });

  final String promptId;
  final int? number;
  final JsonObject nodeErrors;
}

final class ComfyQueueSnapshot {
  const ComfyQueueSnapshot({
    required this.runningPromptIds,
    required this.pendingPromptIds,
    required this.raw,
  });

  final List<String> runningPromptIds;
  final List<String> pendingPromptIds;
  final JsonObject raw;

  bool contains(String promptId) =>
      runningPromptIds.contains(promptId) ||
      pendingPromptIds.contains(promptId);

  bool isRunning(String promptId) => runningPromptIds.contains(promptId);

  bool isPending(String promptId) => pendingPromptIds.contains(promptId);
}

final class ComfyHistoryResult {
  const ComfyHistoryResult({
    required this.promptId,
    required this.completed,
    required this.outputs,
    required this.raw,
    this.status,
    this.error,
  });

  final String promptId;
  final bool completed;
  final String? status;
  final List<ComfyOutputRef> outputs;
  final JsonObject? error;
  final JsonObject raw;
}

class ComfyApiException implements Exception {
  ComfyApiException({
    required this.message,
    this.uri,
    this.statusCode,
    this.responseBody,
    this.errorType,
    this.details,
    JsonObject nodeErrors = const <String, dynamic>{},
    this.cause,
  }) : nodeErrors = Map<String, dynamic>.unmodifiable(nodeErrors);

  final String message;
  final Uri? uri;
  final int? statusCode;
  final String? responseBody;
  final String? errorType;
  final String? details;
  final JsonObject nodeErrors;
  final Object? cause;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'ComfyApiException$status: $message';
  }
}

final class ComfySubmissionUncertainException implements Exception {
  const ComfySubmissionUncertainException({
    required this.message,
    required this.uri,
    this.cause,
  });

  final String message;
  final Uri uri;
  final Object? cause;

  @override
  String toString() => 'ComfySubmissionUncertainException: $message';
}

final class ComfyUiClient {
  ComfyUiClient({
    required ComfyEndpoint endpoint,
    required String clientId,
    http.Client? httpClient,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration idleTimeout = const Duration(seconds: 30),
    int maxJsonBytes = 32 * 1024 * 1024,
    int maxUploadBytes = 25 * 1024 * 1024,
  }) : // Keep the public named parameter `endpoint` while storage stays private.
       // ignore: prefer_initializing_formals
       _endpoint = endpoint,
       _clientId = _requireClientId(clientId),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _connectTimeout = _requirePositiveDuration(
         connectTimeout,
         'connectTimeout',
       ),
       _idleTimeout = _requirePositiveDuration(idleTimeout, 'idleTimeout'),
       _maxJsonBytes = _requirePositiveInt(maxJsonBytes, 'maxJsonBytes'),
       _maxUploadBytes = _requirePositiveInt(maxUploadBytes, 'maxUploadBytes');

  final ComfyEndpoint _endpoint;
  final String _clientId;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration _connectTimeout;
  final Duration _idleTimeout;
  final int _maxJsonBytes;
  final int _maxUploadBytes;
  final Set<Completer<void>> _activeAborts = <Completer<void>>{};
  bool _closed = false;

  Future<ComfyConnectionInfo> checkConnection() async {
    final systemStats = await _getObject('system_stats');
    final objectInfo = await getObjectInfo();
    return ComfyConnectionInfo(
      systemStats: systemStats,
      objectInfo: objectInfo,
    );
  }

  Future<JsonObject> getObjectInfo() => _getObject('object_info');

  Future<ComfyOutputRef> uploadImage(
    Uint8List bytes, {
    required String fileName,
  }) async {
    final imageSubtype = _validateImageUpload(
      bytes,
      fileName: fileName,
      maxBytes: _maxUploadBytes,
    );
    final uri = _endpoint.route('upload/image');
    final pending = _multipartRequest('POST', uri)
      ..request.files.add(
        http.MultipartFile.fromBytes(
          'image',
          bytes,
          filename: fileName,
          contentType: http.MediaType('image', imageSubtype),
        ),
      )
      ..request.fields['type'] = 'input';
    final json = await _requestObject(pending);
    final name = json['name'];
    final subfolder = json['subfolder'];
    final type = json['type'];
    if (name is! String ||
        subfolder != null && subfolder is! String ||
        type is! String) {
      throw _protocolError(
        uri,
        'Upload response has an invalid output reference',
      );
    }
    try {
      return ComfyOutputRef(
        filename: name,
        subfolder: subfolder as String? ?? '',
        type: type,
      );
    } on FormatException catch (error) {
      throw ComfyApiException(
        message: 'Upload response contains an unsafe output reference',
        uri: uri,
        cause: error,
      );
    }
  }

  Future<ComfyPromptSubmission> submitPrompt(JsonObject prompt) async {
    final uri = _endpoint.route('prompt');
    final pending = _jsonRequest('POST', uri, <String, dynamic>{
      'prompt': prompt,
      'client_id': _clientId,
    });
    late final JsonObject json;
    try {
      json = await _requestObject(pending, exposeTransportFailure: true);
    } on _ComfyTransportFailure catch (error) {
      final statusCode = error.statusCode;
      if (statusCode != null && (statusCode < 200 || statusCode >= 300)) {
        throw ComfyApiException(
          message: error.message,
          uri: uri,
          statusCode: statusCode,
          cause: error.cause,
        );
      }
      throw ComfySubmissionUncertainException(
        message:
            'Prompt response became uncertain after submission started: ${error.message}',
        uri: uri,
        cause: error.cause,
      );
    } on ComfyApiException catch (error) {
      final statusCode = error.statusCode;
      if (statusCode != null && statusCode >= 200 && statusCode < 300) {
        throw ComfySubmissionUncertainException(
          message:
              'Prompt response was unusable after submission started: ${error.message}',
          uri: uri,
          cause: error,
        );
      }
      rethrow;
    }

    final nodeErrors = _optionalObject(json['node_errors']);
    final promptId = json['prompt_id'];
    final rawNumber = json['number'];
    if (promptId is! String || promptId.trim().isEmpty) {
      throw ComfySubmissionUncertainException(
        message:
            'Prompt response was unusable after submission started: missing a valid prompt_id',
        uri: uri,
      );
    }
    final number = rawNumber is num ? rawNumber.toInt() : null;
    return ComfyPromptSubmission(
      promptId: promptId,
      number: number,
      nodeErrors: Map<String, dynamic>.unmodifiable(
        nodeErrors ?? const <String, dynamic>{},
      ),
    );
  }

  Future<ComfyQueueSnapshot> getQueue() async {
    final uri = _endpoint.route('queue');
    final json = await _requestObject(_request('GET', uri));
    final running = _queueIds(json['queue_running'], uri, 'queue_running');
    final pending = _queueIds(json['queue_pending'], uri, 'queue_pending');
    return ComfyQueueSnapshot(
      runningPromptIds: List<String>.unmodifiable(running),
      pendingPromptIds: List<String>.unmodifiable(pending),
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  Future<void> deleteQueuedPrompt(String promptId) async {
    if (promptId.isEmpty) {
      throw ArgumentError.value(promptId, 'promptId', 'Must not be empty');
    }
    final uri = _endpoint.route('queue');
    await _requestObject(
      _jsonRequest('POST', uri, <String, dynamic>{
        'delete': <String>[promptId],
      }),
      allowEmpty: true,
    );
  }

  Future<void> interrupt() async {
    final uri = _endpoint.route('interrupt');
    await _requestObject(_request('POST', uri), allowEmpty: true);
  }

  Future<ComfyHistoryResult?> getHistory(String promptId) async {
    if (promptId.isEmpty) {
      throw ArgumentError.value(promptId, 'promptId', 'Must not be empty');
    }
    final historyRoot = _endpoint.route('history');
    final uri = historyRoot.replace(
      pathSegments: <String>[...historyRoot.pathSegments, promptId],
    );
    final json = await _requestObject(_request('GET', uri));
    final rawRecord = json[promptId];
    if (rawRecord == null) return null;
    final record = _optionalObject(rawRecord);
    if (record == null) {
      throw _protocolError(uri, 'History entry for $promptId is not an object');
    }

    final statusObject = _optionalObject(record['status']);
    final status = statusObject?['status_str'];
    if (status != null && status is! String) {
      throw _protocolError(uri, 'History status_str is not a string');
    }
    final outputs = _collectOutputs(record['outputs']);
    final error = _historyError(record, statusObject);
    final completed =
        statusObject?['completed'] == true ||
        (outputs.isNotEmpty && error == null && status != 'error');
    return ComfyHistoryResult(
      promptId: promptId,
      completed: completed,
      status: status as String?,
      outputs: List<ComfyOutputRef>.unmodifiable(outputs),
      error: error == null ? null : Map<String, dynamic>.unmodifiable(error),
      raw: Map<String, dynamic>.unmodifiable(record),
    );
  }

  Uri buildViewUri(ComfyOutputRef output) => _endpoint.viewUri(output);

  Uri openFrontend() => _endpoint.baseUri;

  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _activeAborts.toList(growable: false)) {
      if (!abort.isCompleted) abort.complete();
    }
    _activeAborts.clear();
    if (_ownsHttpClient) _httpClient.close();
  }

  Future<JsonObject> _getObject(String route) {
    final uri = _endpoint.route(route);
    return _requestObject(_request('GET', uri));
  }

  _PendingRequest<http.AbortableRequest> _request(String method, Uri uri) {
    final abort = Completer<void>();
    return _PendingRequest<http.AbortableRequest>(
      http.AbortableRequest(method, uri, abortTrigger: abort.future),
      abort,
    );
  }

  _PendingRequest<http.AbortableRequest> _jsonRequest(
    String method,
    Uri uri,
    JsonObject body,
  ) {
    final pending = _request(method, uri);
    pending.request.headers['content-type'] = 'application/json';
    pending.request.body = jsonEncode(body);
    return pending;
  }

  _PendingRequest<http.AbortableMultipartRequest> _multipartRequest(
    String method,
    Uri uri,
  ) {
    final abort = Completer<void>();
    return _PendingRequest<http.AbortableMultipartRequest>(
      http.AbortableMultipartRequest(method, uri, abortTrigger: abort.future),
      abort,
    );
  }

  Future<JsonObject> _requestObject<T extends http.BaseRequest>(
    _PendingRequest<T> pending, {
    bool allowEmpty = false,
    bool exposeTransportFailure = false,
  }) async {
    late final _BufferedResponse response;
    try {
      response = await _sendAndRead(pending);
    } on _ComfyTransportFailure catch (error) {
      if (exposeTransportFailure) rethrow;
      throw ComfyApiException(
        message: error.message,
        uri: pending.request.url,
        statusCode: error.statusCode,
        cause: error.cause,
      );
    }
    final text = utf8.decode(response.bytes, allowMalformed: true);
    final decoded = _tryDecode(text);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final json = _optionalObject(decoded);
      throw _apiErrorFromJson(
        uri: pending.request.url,
        statusCode: response.statusCode,
        responseBody: text,
        json: json,
        fallbackMessage: text.trim().isEmpty
            ? 'ComfyUI returned HTTP ${response.statusCode}'
            : text.trim(),
      );
    }
    if (response.bytes.isEmpty && allowEmpty) {
      return <String, dynamic>{};
    }
    final json = _optionalObject(decoded);
    if (json == null) {
      throw _protocolError(
        pending.request.url,
        response.bytes.isEmpty
            ? 'ComfyUI returned an empty JSON response'
            : 'ComfyUI returned a non-object JSON response',
        statusCode: response.statusCode,
        responseBody: text,
      );
    }
    return json;
  }

  Future<_BufferedResponse> _sendAndRead<T extends http.BaseRequest>(
    _PendingRequest<T> pending,
  ) async {
    if (_closed) throw StateError('ComfyUiClient is closed');
    _activeAborts.add(pending.abort);
    try {
      late final http.StreamedResponse response;
      try {
        response = await _httpClient
            .send(pending.request)
            .timeout(
              _connectTimeout,
              onTimeout: () {
                _abort(pending.abort);
                throw TimeoutException(
                  'Timed out waiting for response headers',
                  _connectTimeout,
                );
              },
            );
      } catch (error) {
        throw _ComfyTransportFailure(
          'Timed out or failed while waiting for response headers',
          error,
        );
      }

      final declaredBytes = response.contentLength;
      if (declaredBytes != null && declaredBytes > _maxJsonBytes) {
        _abort(pending.abort);
        throw ComfyApiException(
          message:
              'ComfyUI JSON response exceeds the $_maxJsonBytes bytes limit',
          uri: pending.request.url,
          statusCode: response.statusCode,
        );
      }

      final bytes = BytesBuilder(copy: false);
      final iterator = StreamIterator<List<int>>(response.stream);
      try {
        while (await iterator.moveNext().timeout(_idleTimeout)) {
          final chunk = iterator.current;
          if (chunk.length > _maxJsonBytes - bytes.length) {
            _abort(pending.abort);
            throw ComfyApiException(
              message:
                  'ComfyUI JSON response exceeds the $_maxJsonBytes bytes limit',
              uri: pending.request.url,
              statusCode: response.statusCode,
            );
          }
          bytes.add(chunk);
        }
      } on ComfyApiException {
        rethrow;
      } catch (error) {
        _abort(pending.abort);
        throw _ComfyTransportFailure(
          'Response body was interrupted or idle for ${_idleTimeout.inMilliseconds} ms',
          error,
          statusCode: response.statusCode,
        );
      } finally {
        try {
          await iterator.cancel();
        } catch (_) {}
      }
      return _BufferedResponse(response.statusCode, bytes.takeBytes());
    } finally {
      _activeAborts.remove(pending.abort);
    }
  }

  static void _abort(Completer<void> abort) {
    if (!abort.isCompleted) abort.complete();
  }
}

final class _PendingRequest<T extends http.BaseRequest> {
  const _PendingRequest(this.request, this.abort);

  final T request;
  final Completer<void> abort;
}

final class _BufferedResponse {
  const _BufferedResponse(this.statusCode, this.bytes);

  final int statusCode;
  final Uint8List bytes;
}

final class _ComfyTransportFailure implements Exception {
  const _ComfyTransportFailure(this.message, this.cause, {this.statusCode});

  final String message;
  final Object cause;
  final int? statusCode;
}

ComfyApiException _protocolError(
  Uri uri,
  String message, {
  int? statusCode,
  String? responseBody,
}) => ComfyApiException(
  message: message,
  uri: uri,
  statusCode: statusCode,
  responseBody: responseBody,
);

ComfyApiException _apiErrorFromJson({
  required Uri uri,
  required int statusCode,
  required String responseBody,
  required JsonObject? json,
  required String fallbackMessage,
}) {
  final topError = _optionalObject(json?['error']);
  final topMessage = topError?['message'] ?? json?['message'];
  final message = topMessage is String && topMessage.isNotEmpty
      ? topMessage
      : fallbackMessage;
  final errorType = topError?['type'];
  final details = topError?['details'];
  return ComfyApiException(
    message: message,
    uri: uri,
    statusCode: statusCode,
    responseBody: responseBody,
    errorType: errorType is String ? errorType : null,
    details: details is String ? details : null,
    nodeErrors:
        _optionalObject(json?['node_errors']) ?? const <String, dynamic>{},
  );
}

Object? _tryDecode(String text) {
  if (text.trim().isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

JsonObject? _optionalObject(Object? raw) {
  if (raw is! Map) return null;
  final object = <String, dynamic>{};
  for (final entry in raw.entries) {
    if (entry.key is! String) return null;
    object[entry.key as String] = entry.value;
  }
  return object;
}

List<String> _queueIds(Object? raw, Uri uri, String field) {
  if (raw is! List) {
    throw _protocolError(uri, '$field is not a list');
  }
  final ids = <String>[];
  for (final entry in raw) {
    if (entry is! List || entry.length < 2 || entry[1] is! String) {
      throw _protocolError(uri, '$field contains an invalid queue entry');
    }
    final promptId = entry[1] as String;
    if (promptId.isEmpty) {
      throw _protocolError(uri, '$field contains an empty prompt ID');
    }
    ids.add(promptId);
  }
  return ids;
}

List<ComfyOutputRef> _collectOutputs(Object? raw) {
  final outputs = <ComfyOutputRef>[];
  final seen = <String>{};

  void visit(Object? value) {
    if (value is List) {
      for (final child in value) {
        visit(child);
      }
      return;
    }
    final object = _optionalObject(value);
    if (object == null) return;

    final filename = object['filename'];
    final type = object['type'];
    final subfolder = object['subfolder'];
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
        // History can contain arbitrary custom-node metadata. Unsafe file
        // references are ignored instead of becoming URLs.
      }
    }
    for (final child in object.values) {
      visit(child);
    }
  }

  visit(raw);
  return outputs;
}

JsonObject? _historyError(JsonObject record, JsonObject? status) {
  final direct = _optionalObject(record['error']);
  if (direct != null) return direct;
  final messages = status?['messages'];
  if (messages is! List) return null;
  for (final message in messages.reversed) {
    if (message is! List || message.length < 2) continue;
    final eventType = message[0];
    if (eventType != 'execution_error' &&
        eventType != 'execution_interrupted') {
      continue;
    }
    final details = _optionalObject(message[1]);
    if (details == null) continue;
    return <String, dynamic>{'event_type': eventType, ...details};
  }
  return null;
}

String _validateImageUpload(
  Uint8List bytes, {
  required String fileName,
  required int maxBytes,
}) {
  if (bytes.length > maxBytes) {
    throw ArgumentError.value(
      bytes.length,
      'bytes',
      'Image exceeds the $maxBytes bytes upload limit',
    );
  }
  if (fileName.isEmpty ||
      fileName.length > 255 ||
      fileName != fileName.trim() ||
      fileName == '.' ||
      fileName == '..' ||
      RegExp(r'[\x00-\x1f\x7f/\\":]').hasMatch(fileName)) {
    throw ArgumentError.value(fileName, 'fileName', 'Unsafe image filename');
  }
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) {
    throw ArgumentError.value(
      fileName,
      'fileName',
      'Image filename needs a supported extension',
    );
  }
  final extension = fileName.substring(dot + 1).toLowerCase();
  final matches = switch (extension) {
    'png' => _startsWith(bytes, const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]),
    'jpg' || 'jpeg' => _startsWith(bytes, const [0xff, 0xd8, 0xff]),
    'gif' =>
      _startsWith(bytes, ascii.encode('GIF87a')) ||
          _startsWith(bytes, ascii.encode('GIF89a')),
    'webp' =>
      _startsWith(bytes, ascii.encode('RIFF')) &&
          _matchesAt(bytes, 8, ascii.encode('WEBP')),
    'bmp' => _startsWith(bytes, ascii.encode('BM')),
    'tif' || 'tiff' =>
      _startsWith(bytes, const [0x49, 0x49, 0x2a, 0x00]) ||
          _startsWith(bytes, const [0x4d, 0x4d, 0x00, 0x2a]),
    _ => false,
  };
  if (!matches) {
    throw ArgumentError.value(
      fileName,
      'fileName',
      'Extension is unsupported or does not match the image bytes',
    );
  }
  return extension == 'jpg' ? 'jpeg' : extension;
}

bool _startsWith(Uint8List bytes, List<int> signature) =>
    _matchesAt(bytes, 0, signature);

bool _matchesAt(Uint8List bytes, int offset, List<int> signature) {
  if (offset < 0 || bytes.length < offset + signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}

String _requireClientId(String clientId) {
  if (clientId.isEmpty) {
    throw ArgumentError.value(clientId, 'clientId', 'Must not be empty');
  }
  return clientId;
}

Duration _requirePositiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'Must be positive');
  }
  return value;
}

int _requirePositiveInt(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'Must be positive');
  return value;
}
