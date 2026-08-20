import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'comfy_workflow.dart';

enum MediaCacheState { remoteOnly, cached, missing }

final class MediaAsset {
  MediaAsset({
    required this.id,
    required this.kind,
    required this.endpointSnapshot,
    required this.filename,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.jobId,
    this.workflowId,
    this.subfolder = '',
    this.type = 'output',
    this.contentType,
    this.width,
    this.height,
    this.durationSeconds,
    this.cachePath,
    this.cacheState = MediaCacheState.remoteOnly,
    this.sourceSessionId,
    this.sourceMessageId,
  }) : createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc();

  final String id;
  final String? jobId;
  final String? workflowId;
  final ComfyMediaKind kind;
  final String endpointSnapshot;
  final String filename;
  final String subfolder;
  final String type;
  final String? contentType;
  final int? width;
  final int? height;
  final double? durationSeconds;
  final String? cachePath;
  final MediaCacheState cacheState;
  final String? sourceSessionId;
  final String? sourceMessageId;
  final DateTime createdAt;
  final DateTime updatedAt;

  ComfyOutputRef get outputRef =>
      ComfyOutputRef(filename: filename, subfolder: subfolder, type: type);

  String get identityKey {
    final identity = jsonEncode([
      _normalizedEndpoint(endpointSnapshot),
      filename,
      subfolder,
      type,
    ]);
    return sha256.convert(utf8.encode(identity)).toString();
  }

  MediaAsset copyWith({
    Object? jobId = _absent,
    Object? workflowId = _absent,
    ComfyMediaKind? kind,
    String? endpointSnapshot,
    String? filename,
    String? subfolder,
    String? type,
    Object? contentType = _absent,
    Object? width = _absent,
    Object? height = _absent,
    Object? durationSeconds = _absent,
    Object? cachePath = _absent,
    MediaCacheState? cacheState,
    Object? sourceSessionId = _absent,
    Object? sourceMessageId = _absent,
    DateTime? updatedAt,
  }) => MediaAsset(
    id: id,
    jobId: identical(jobId, _absent) ? this.jobId : jobId as String?,
    workflowId: identical(workflowId, _absent)
        ? this.workflowId
        : workflowId as String?,
    kind: kind ?? this.kind,
    endpointSnapshot: endpointSnapshot ?? this.endpointSnapshot,
    filename: filename ?? this.filename,
    subfolder: subfolder ?? this.subfolder,
    type: type ?? this.type,
    contentType: identical(contentType, _absent)
        ? this.contentType
        : contentType as String?,
    width: identical(width, _absent) ? this.width : width as int?,
    height: identical(height, _absent) ? this.height : height as int?,
    durationSeconds: identical(durationSeconds, _absent)
        ? this.durationSeconds
        : durationSeconds as double?,
    cachePath: identical(cachePath, _absent)
        ? this.cachePath
        : cachePath as String?,
    cacheState: cacheState ?? this.cacheState,
    sourceSessionId: identical(sourceSessionId, _absent)
        ? this.sourceSessionId
        : sourceSessionId as String?,
    sourceMessageId: identical(sourceMessageId, _absent)
        ? this.sourceMessageId
        : sourceMessageId as String?,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'jobId': jobId,
    'workflowId': workflowId,
    'kind': kind.name,
    'endpointSnapshot': endpointSnapshot,
    'filename': filename,
    'subfolder': subfolder,
    'type': type,
    'contentType': contentType,
    'width': width,
    'height': height,
    'durationSeconds': durationSeconds,
    'cachePath': cachePath,
    'cacheState': cacheState.name,
    'sourceSessionId': sourceSessionId,
    'sourceMessageId': sourceMessageId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory MediaAsset.fromJson(Map<String, Object?> json) {
    final createdAt = _date(json['createdAt']);
    return MediaAsset(
      id: _string(json['id']),
      jobId: _nullableString(json['jobId']),
      workflowId: _nullableString(json['workflowId']),
      kind: _mediaKind(json['kind']),
      endpointSnapshot: _string(json['endpointSnapshot']),
      filename: _string(json['filename']),
      subfolder: _string(json['subfolder']),
      type: _safeType(json['type']),
      contentType: _nullableString(json['contentType']),
      width: _nullableInt(json['width']),
      height: _nullableInt(json['height']),
      durationSeconds: _nullableDouble(json['durationSeconds']),
      cachePath: _nullableString(json['cachePath']),
      cacheState: _cacheState(json['cacheState']),
      sourceSessionId: _nullableString(json['sourceSessionId']),
      sourceMessageId: _nullableString(json['sourceMessageId']),
      createdAt: createdAt,
      updatedAt: _date(json['updatedAt'], fallback: createdAt),
    );
  }
}

const Object _absent = Object();
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

String _normalizedEndpoint(String raw) {
  try {
    final uri = ComfyEndpoint.parse(raw).baseUri;
    return uri
        .replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase())
        .toString();
  } on FormatException {
    return raw.trim().replaceFirst(RegExp(r'/+$'), '').toLowerCase();
  }
}

String _string(Object? value) => value is String ? value : '';

String? _nullableString(Object? value) => value is String ? value : null;

int? _nullableInt(Object? value) => value is int && value >= 0 ? value : null;

double? _nullableDouble(Object? value) =>
    value is num && value >= 0 ? value.toDouble() : null;

String _safeType(Object? value) =>
    const {'input', 'output', 'temp'}.contains(value)
    ? value! as String
    : 'output';

ComfyMediaKind _mediaKind(Object? raw) {
  if (raw is String) {
    for (final value in ComfyMediaKind.values) {
      if (value.name == raw) return value;
    }
  }
  return ComfyMediaKind.image;
}

MediaCacheState _cacheState(Object? raw) {
  if (raw is String) {
    for (final value in MediaCacheState.values) {
      if (value.name == raw) return value;
    }
  }
  return MediaCacheState.remoteOnly;
}

DateTime _date(Object? raw, {DateTime? fallback}) {
  if (raw is String) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toUtc();
  }
  return fallback?.toUtc() ?? _epoch;
}
