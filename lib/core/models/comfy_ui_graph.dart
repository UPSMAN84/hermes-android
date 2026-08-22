import 'comfy_workflow.dart';

/// Which JSON shape a decoded workflow graph is in: the flat API-format map
/// this app has always required (`{nodeId: {class_type, inputs}}`), or
/// ComfyUI's own regular "Save" export (`nodes`/`links`/positions/widget
/// values). Detected from the JSON itself -- never persisted -- so a raw
/// edit can't leave a stored shape flag out of sync with the actual graph.
enum ComfyGraphShape { flatApi, uiFormat }

ComfyGraphShape detectGraphShape(JsonObject graph) {
  if (graph['nodes'] is List && graph['links'] is List) {
    return ComfyGraphShape.uiFormat;
  }
  return ComfyGraphShape.flatApi;
}

/// One entry in a node's `inputs` or `outputs` array. [hasWidgetMarker] is
/// set when the entry carries a `widget` property -- ComfyUI's marker for an
/// input that was converted from a widget to a socket and may be converted
/// back, which the UI->API converter (Stage 3) needs to fall back on when
/// the link is absent.
final class UiGraphSocket {
  const UiGraphSocket({
    required this.name,
    required this.type,
    this.link,
    this.hasWidgetMarker = false,
  });

  final String name;
  final String type;
  final int? link;
  final bool hasWidgetMarker;

  factory UiGraphSocket.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Socket entry must be an object');
    }
    final name = raw['name'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('Socket entry requires a non-empty name');
    }
    final type = raw['type'];
    final link = raw['link'];
    return UiGraphSocket(
      name: name,
      type: type is String ? type : '*',
      link: link is int ? link : null,
      hasWidgetMarker: raw['widget'] != null,
    );
  }
}

final class UiGraphNode {
  const UiGraphNode({
    required this.id,
    required this.type,
    required this.pos,
    required this.size,
    required this.mode,
    required this.inputs,
    required this.outputs,
    required this.widgetsValues,
    this.widgetsValuesNamed,
    required this.properties,
    this.title,
  });

  final int id;
  final String type;
  final (double, double) pos;
  final (double, double) size;

  /// ComfyUI mode: 0 normal, 2 muted (never executed), 4 bypassed
  /// (feed-through). See `ComfyUiGraphConverter` (Stage 3) for how these are
  /// handled at conversion time.
  final int mode;
  final List<UiGraphSocket> inputs;
  final List<UiGraphSocket> outputs;
  final List<Object?> widgetsValues;

  /// Name-keyed widget values (`widgets_values_named`), when the exporting
  /// ComfyUI frontend is recent enough to include them (added in
  /// Comfy-Org/ComfyUI_frontend PR #10392, merged 2026-07-30). Prefer this
  /// over positional [widgetsValues] when resolving a widget's value --
  /// null when the file doesn't carry it, which is still the common case.
  final Map<String, Object?>? widgetsValuesNamed;
  final Map<String, Object?> properties;
  final String? title;

  String get displayTitle => (title != null && title!.isNotEmpty) ? title! : type;

  factory UiGraphNode.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Node entry must be an object');
    }
    final id = raw['id'];
    final type = raw['type'];
    if (id is! int) {
      throw const FormatException('Node requires an integer id');
    }
    if (type is! String || type.isEmpty) {
      throw const FormatException('Node requires a non-empty string type');
    }
    final namedRaw = raw['widgets_values_named'];
    return UiGraphNode(
      id: id,
      type: type,
      pos: _pair(raw['pos'], fallback: (0, 0)),
      size: _pair(raw['size'], fallback: (0, 0)),
      mode: raw['mode'] is int ? raw['mode'] as int : 0,
      inputs: _sockets(raw['inputs']),
      outputs: _sockets(raw['outputs']),
      widgetsValues: _widgetsValues(raw['widgets_values']),
      widgetsValuesNamed: namedRaw is Map
          ? Map<String, Object?>.from(namedRaw)
          : null,
      properties: raw['properties'] is Map
          ? Map<String, Object?>.from(raw['properties'] as Map)
          : const <String, Object?>{},
      title: raw['title'] is String ? raw['title'] as String : null,
    );
  }
}

final class UiGraphLink {
  const UiGraphLink({
    required this.id,
    required this.originNodeId,
    required this.originSlot,
    required this.targetNodeId,
    required this.targetSlot,
    required this.type,
  });

  final int id;
  final int originNodeId;
  final int originSlot;
  final int targetNodeId;
  final int targetSlot;
  final String type;
}

final class UiFormatGraph {
  const UiFormatGraph({required this.nodes, required this.links});

  final List<UiGraphNode> nodes;
  final List<UiGraphLink> links;

  UiGraphNode? nodeById(int id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  /// Parses and structurally validates ComfyUI's regular "Save" export
  /// shape. Individual malformed nodes/links/sockets are skipped rather than
  /// failing the whole parse -- ComfyUI's own export format has known
  /// version-to-version variance (e.g. `widgets_values` as a dict for some
  /// dynamic-input custom nodes, or links serialized as objects instead of
  /// positional tuples in newer exports) that shouldn't take down an
  /// otherwise-valid graph.
  static UiFormatGraph parse(JsonObject graph) {
    final rawNodes = graph['nodes'];
    final rawLinks = graph['links'];
    if (rawNodes is! List) {
      throw const FormatException('UI-format graph requires a nodes list');
    }
    if (rawLinks is! List) {
      throw const FormatException('UI-format graph requires a links list');
    }
    if (rawNodes.isEmpty) {
      throw const FormatException('UI-format graph has no nodes');
    }
    final nodes = <UiGraphNode>[];
    for (final entry in rawNodes) {
      nodes.add(UiGraphNode.fromJson(entry));
    }
    final links = <UiGraphLink>[];
    for (final entry in rawLinks) {
      final link = _parseLink(entry);
      if (link != null) links.add(link);
    }
    return UiFormatGraph(nodes: nodes, links: links);
  }
}

UiGraphLink? _parseLink(Object? raw) {
  if (raw is List) {
    if (raw.length < 6) return null;
    return _linkFromValues(
      id: raw[0],
      origin: raw[1],
      originSlot: raw[2],
      target: raw[3],
      targetSlot: raw[4],
      type: raw[5],
    );
  }
  if (raw is Map) {
    return _linkFromValues(
      id: raw['id'],
      origin: raw['origin_id'] ?? raw['originNodeId'],
      originSlot: raw['origin_slot'] ?? raw['originSlot'],
      target: raw['target_id'] ?? raw['targetNodeId'],
      targetSlot: raw['target_slot'] ?? raw['targetSlot'],
      type: raw['type'],
    );
  }
  return null;
}

UiGraphLink? _linkFromValues({
  required Object? id,
  required Object? origin,
  required Object? originSlot,
  required Object? target,
  required Object? targetSlot,
  required Object? type,
}) {
  if (id is! int ||
      origin is! int ||
      originSlot is! int ||
      target is! int ||
      targetSlot is! int) {
    return null;
  }
  return UiGraphLink(
    id: id,
    originNodeId: origin,
    originSlot: originSlot,
    targetNodeId: target,
    targetSlot: targetSlot,
    type: type is String ? type : '*',
  );
}

List<UiGraphSocket> _sockets(Object? raw) {
  if (raw is! List) return const [];
  final sockets = <UiGraphSocket>[];
  for (final entry in raw) {
    try {
      sockets.add(UiGraphSocket.fromJson(entry));
    } on FormatException {
      // Skip malformed socket entries rather than failing the whole node.
    }
  }
  return List.unmodifiable(sockets);
}

/// Almost always a list; defensively also accepts a dict (seen on some
/// dynamic-input custom nodes), taking values in iteration order.
List<Object?> _widgetsValues(Object? raw) {
  if (raw is List) return List.unmodifiable(raw);
  if (raw is Map) return List.unmodifiable(raw.values);
  return const [];
}

(double, double) _pair(Object? raw, {required (double, double) fallback}) {
  if (raw is! List || raw.length < 2) return fallback;
  final x = raw[0];
  final y = raw[1];
  if (x is! num || y is! num) return fallback;
  return (x.toDouble(), y.toDouble());
}

