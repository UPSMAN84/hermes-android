import 'dart:typed_data';

typedef JsonObject = Map<String, dynamic>;

final class ComfyEndpoint {
  ComfyEndpoint._(this.baseUri);

  final Uri baseUri;

  factory ComfyEndpoint.parse(String raw) {
    final trimmed = raw.trim();
    final text = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.parse(text);
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'ComfyUI endpoint must be HTTP(S) authority plus optional path',
      );
    }
    return ComfyEndpoint._(uri.replace(path: _cleanBasePath(uri.path)));
  }

  static String _cleanBasePath(String path) {
    final withoutTrailingSlash = path.replaceFirst(RegExp(r'/+$'), '');
    if (withoutTrailingSlash.isEmpty) return '';
    return withoutTrailingSlash.startsWith('/')
        ? withoutTrailingSlash
        : '/$withoutTrailingSlash';
  }

  Uri route(String leaf, {Map<String, String>? query}) => baseUri.replace(
    path:
        '${baseUri.path == '/' ? '' : baseUri.path}/${leaf.replaceFirst(RegExp(r'^/+'), '')}',
    queryParameters: query,
  );

  Uri websocketUri(String clientId) => route(
    'ws',
    query: {'clientId': clientId},
  ).replace(scheme: baseUri.scheme == 'https' ? 'wss' : 'ws');

  Uri viewUri(ComfyOutputRef output) => route('view', query: output.query);
}

final class ComfyOutputRef {
  ComfyOutputRef._({
    required this.filename,
    required this.subfolder,
    required this.type,
  });

  factory ComfyOutputRef({
    required String filename,
    String subfolder = '',
    String type = 'output',
  }) {
    if (filename.isEmpty ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename == '..' ||
        subfolder.startsWith('/') ||
        subfolder.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(subfolder) ||
        subfolder.split(RegExp(r'[/\\]+')).any((part) => part == '..') ||
        !const {'input', 'output', 'temp'}.contains(type)) {
      throw const FormatException('Unsafe ComfyUI output reference');
    }
    return ComfyOutputRef._(
      filename: filename,
      subfolder: subfolder,
      type: type,
    );
  }

  final String filename;
  final String subfolder;
  final String type;

  Map<String, String> get query => {
    'filename': filename,
    if (subfolder.isNotEmpty) 'subfolder': subfolder,
    'type': type,
  };
}

enum ComfyMediaKind { image, video }

enum BindingRole {
  prompt,
  negativePrompt,
  seed,
  width,
  height,
  steps,
  cfg,
  frames,
  fps,
  inputImage,
  custom,
}

enum WorkflowControlType {
  text,
  multiline,
  integer,
  decimal,
  toggle,
  enumeration,
  file,
}

final class WorkflowInputBinding {
  const WorkflowInputBinding({
    required this.id,
    required this.nodeId,
    required this.inputName,
    required this.label,
    required this.role,
    required this.controlType,
    required this.required,
    this.helpText,
    this.defaultValue,
    this.minimum,
    this.maximum,
    this.step,
    this.choices = const [],
  });

  final String id;
  final String nodeId;
  final String inputName;
  final String label;
  final BindingRole role;
  final WorkflowControlType controlType;
  final bool required;
  final String? helpText;
  final Object? defaultValue;
  final num? minimum;
  final num? maximum;
  final num? step;
  final List<String> choices;

  Map<String, Object?> toJson() => {
    'id': id,
    'nodeId': nodeId,
    'inputName': inputName,
    'label': label,
    'role': role.name,
    'controlType': controlType.name,
    'required': required,
    if (helpText != null) 'helpText': helpText,
    if (defaultValue != null) 'defaultValue': defaultValue,
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
    if (step != null) 'step': step,
    'choices': choices,
  };

  factory WorkflowInputBinding.fromJson(Map<String, Object?> json) =>
      WorkflowInputBinding(
        id: _requiredString(json, 'id'),
        nodeId: _requiredString(json, 'nodeId'),
        inputName: _requiredString(json, 'inputName'),
        label: _requiredString(json, 'label'),
        role: _enumByName(BindingRole.values, json['role'], 'role'),
        controlType: _enumByName(
          WorkflowControlType.values,
          json['controlType'],
          'controlType',
        ),
        required: _requiredBool(json, 'required'),
        helpText: json['helpText'] as String?,
        defaultValue: json['defaultValue'],
        minimum: json['minimum'] as num?,
        maximum: json['maximum'] as num?,
        step: json['step'] as num?,
        choices: _stringList(json['choices'], 'choices'),
      );
}

final class WorkflowValidationIssue {
  const WorkflowValidationIssue({
    required this.code,
    required this.message,
    this.blocking = true,
    this.nodeId,
    this.inputName,
  });

  final String code;
  final String message;
  final bool blocking;
  final String? nodeId;
  final String? inputName;

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    'blocking': blocking,
    if (nodeId != null) 'nodeId': nodeId,
    if (inputName != null) 'inputName': inputName,
  };

  factory WorkflowValidationIssue.fromJson(Map<String, Object?> json) =>
      WorkflowValidationIssue(
        code: _requiredString(json, 'code'),
        message: _requiredString(json, 'message'),
        blocking: _requiredBool(json, 'blocking'),
        nodeId: json['nodeId'] as String?,
        inputName: json['inputName'] as String?,
      );
}

final class WorkflowValidationResult {
  const WorkflowValidationResult({
    required this.issues,
    this.fingerprint,
    this.endpoint,
  });

  final List<WorkflowValidationIssue> issues;
  final String? fingerprint;
  final String? endpoint;

  bool get isValid => !issues.any((issue) => issue.blocking);

  Map<String, Object?> toJson() => {
    'issues': issues.map((issue) => issue.toJson()).toList(),
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (endpoint != null) 'endpoint': endpoint,
  };

  factory WorkflowValidationResult.fromJson(Map<String, Object?> json) =>
      WorkflowValidationResult(
        issues: _objectList(
          json['issues'],
          'issues',
        ).map(WorkflowValidationIssue.fromJson).toList(growable: false),
        fingerprint: json['fingerprint'] as String?,
        endpoint: json['endpoint'] as String?,
      );
}

final class ImportedWorkflow {
  ImportedWorkflow({
    required List<int> sourceBytes,
    required this.graph,
    required this.sourceHash,
    required this.sourceFileName,
  }) : _sourceBytes = Uint8List.fromList(sourceBytes);

  final Uint8List _sourceBytes;
  final JsonObject graph;
  final String sourceHash;
  final String sourceFileName;

  Uint8List get sourceBytes => Uint8List.fromList(_sourceBytes);
}

final class ComfyWorkflowDefinition {
  const ComfyWorkflowDefinition({
    required this.id,
    required this.name,
    required this.kind,
    required this.workingGraph,
    required this.sourceHash,
    required this.sourceFileName,
    required this.bindings,
    required this.createdAt,
    required this.updatedAt,
    this.validation,
    this.lastSuccessfulJobId,
  });

  final String id;
  final String name;
  final ComfyMediaKind kind;
  final JsonObject workingGraph;
  final String sourceHash;
  final String sourceFileName;
  final List<WorkflowInputBinding> bindings;
  final DateTime createdAt;
  final DateTime updatedAt;
  final WorkflowValidationResult? validation;
  final String? lastSuccessfulJobId;

  ComfyWorkflowDefinition copyWith({
    String? name,
    ComfyMediaKind? kind,
    JsonObject? workingGraph,
    List<WorkflowInputBinding>? bindings,
    DateTime? updatedAt,
    WorkflowValidationResult? validation,
    String? lastSuccessfulJobId,
  }) => ComfyWorkflowDefinition(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    workingGraph: workingGraph ?? this.workingGraph,
    sourceHash: sourceHash,
    sourceFileName: sourceFileName,
    bindings: bindings ?? this.bindings,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    validation: validation ?? this.validation,
    lastSuccessfulJobId: lastSuccessfulJobId ?? this.lastSuccessfulJobId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'workingGraph': workingGraph,
    'sourceHash': sourceHash,
    'sourceFileName': sourceFileName,
    'bindings': bindings.map((binding) => binding.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (validation != null) 'validation': validation!.toJson(),
    if (lastSuccessfulJobId != null) 'lastSuccessfulJobId': lastSuccessfulJobId,
  };

  factory ComfyWorkflowDefinition.fromJson(Map<String, Object?> json) =>
      ComfyWorkflowDefinition(
        id: _requiredString(json, 'id'),
        name: _requiredString(json, 'name'),
        kind: _enumByName(ComfyMediaKind.values, json['kind'], 'kind'),
        workingGraph: _object(json['workingGraph'], 'workingGraph'),
        sourceHash: _requiredString(json, 'sourceHash'),
        sourceFileName: _requiredString(json, 'sourceFileName'),
        bindings: _objectList(
          json['bindings'],
          'bindings',
        ).map(WorkflowInputBinding.fromJson).toList(growable: false),
        createdAt: DateTime.parse(_requiredString(json, 'createdAt')),
        updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')),
        validation: json['validation'] == null
            ? null
            : WorkflowValidationResult.fromJson(
                _object(json['validation'], 'validation'),
              ),
        lastSuccessfulJobId: json['lastSuccessfulJobId'] as String?,
      );
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

T _enumByName<T extends Enum>(List<T> values, Object? raw, String key) {
  if (raw is String) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
  }
  throw FormatException('$key has an unsupported value');
}

JsonObject _object(Object? raw, String key) {
  if (raw is! Map) throw FormatException('$key must be an object');
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

List<JsonObject> _objectList(Object? raw, String key) {
  if (raw is! List) throw FormatException('$key must be a list');
  return raw.map((value) => _object(value, key)).toList(growable: false);
}

List<String> _stringList(Object? raw, String key) {
  if (raw == null) return const [];
  if (raw is! List || raw.any((value) => value is! String)) {
    throw FormatException('$key must contain only strings');
  }
  return raw.cast<String>().toList(growable: false);
}
