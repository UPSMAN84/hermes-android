import 'dart:convert';
import 'dart:typed_data';

/// One optimistic chat turn, including any attachment needed for retry.
class PendingChatSend {
  PendingChatSend({
    required this.text,
    required this.imageBytes,
    required this.imageMimeType,
  }) {
    final bytes = imageBytes;
    imageDataUrls = bytes == null
        ? null
        : ['data:${imageMimeType ?? 'image/jpeg'};base64,${base64Encode(bytes)}'];
    final urls = imageDataUrls;
    localContent = urls == null
        ? text
        : <Map<String, dynamic>>[
            if (text.isNotEmpty) {'type': 'text', 'text': text},
            for (final url in urls)
              {
                'type': 'image_url',
                'image_url': {'url': url},
              },
          ];
    optimisticUserRow = {'role': 'user', 'content': localContent};
    optimisticAssistantRow = {'role': 'assistant', 'content': ''};
  }

  final String text;
  final Uint8List? imageBytes;
  final String? imageMimeType;
  late final List<String>? imageDataUrls;
  late final Object localContent;
  late final Map<String, dynamic> optimisticUserRow;
  late final Map<String, dynamic> optimisticAssistantRow;

  void appendOptimisticRows(List<Map<String, dynamic>> messages) {
    messages.add(optimisticUserRow);
    messages.add(optimisticAssistantRow);
  }

  void rollbackOptimisticRows(List<Map<String, dynamic>> messages) {
    messages.removeWhere(
      (message) =>
          identical(message, optimisticUserRow) ||
          identical(message, optimisticAssistantRow),
    );
  }
}
