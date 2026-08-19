/// Session model matching the Gateway API Server response format.
class Session {
  final String id;
  final String title;
  final String model;
  final String source;
  final int messageCount;
  final bool isActive;
  final String preview;
  final double startedAt;

  const Session({
    required this.id,
    required this.title,
    required this.model,
    required this.source,
    required this.messageCount,
    required this.isActive,
    required this.preview,
    required this.startedAt,
  });

  /// Only [title] is settable client-side today (via rename) -- everything
  /// else is server-derived, so a full field-by-field copyWith would just be
  /// unused surface area.
  Session copyWithTitle(String title) => Session(
    id: id,
    title: title,
    model: model,
    source: source,
    messageCount: messageCount,
    isActive: isActive,
    preview: preview,
    startedAt: startedAt,
  );

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      model: json['model'] ?? 'Default',
      source: json['source'] ?? '',
      // `num`, not `int`: JSON doesn't distinguish int/double, so a server
      // that ever serializes this as a float (e.g. 5.0) must not throw a
      // type-cast error here the way a bare `?? 0` with an `int` field would.
      messageCount: (json['message_count'] as num?)?.round() ?? 0,
      isActive: json['ended_at'] == null,
      preview: json['preview'] ?? '',
      startedAt: (json['started_at'] ?? 0).toDouble(),
    );
  }
}
