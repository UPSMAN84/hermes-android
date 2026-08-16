import 'dart:convert';
import 'dart:typed_data';

/// Builds the `data:` URL for an attachment.
///
/// Split out so callers can do the base64 encode when the image is PICKED
/// rather than when Send is tapped. A 2000px/q85 JPEG is ~1MB in and ~1.4MB
/// out, and doing that synchronously inside _sendMessage put a visible hitch
/// on the main isolate at exactly the moment the user expects the message to
/// appear. Picking is already async and off the critical path.
String buildImageDataUrl(Uint8List bytes, String? mimeType) =>
    'data:${mimeType ?? 'image/jpeg'};base64,${base64Encode(bytes)}';

/// One optimistic chat turn, including any attachment needed for retry.
class PendingChatSend {
  PendingChatSend({
    required this.text,
    required this.imageBytes,
    required this.imageMimeType,
    String? imageDataUrl,
  }) {
    final bytes = imageBytes;
    imageDataUrls = bytes == null
        ? null
        : [imageDataUrl ?? buildImageDataUrl(bytes, imageMimeType)];
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
