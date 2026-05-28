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
  final double? endedAt;

  const Session({
    required this.id,
    required this.title,
    required this.model,
    required this.source,
    required this.messageCount,
    required this.isActive,
    required this.preview,
    required this.startedAt,
    this.endedAt,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    final endedAt = json['ended_at'];
    return Session(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      model: json['model'] ?? 'Default',
      source: json['source'] ?? '',
      messageCount: json['message_count'] ?? 0,
      isActive: endedAt == null,
      preview: json['preview'] ?? '',
      startedAt: (json['started_at'] ?? 0).toDouble(),
      endedAt: endedAt?.toDouble(),
    );
  }
}
