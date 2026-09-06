import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

/// Builds the `data:` URL for an attachment.
///
/// Top-level (not an instance method) so it can be passed to [compute] /
/// [Isolate.run] without capturing any widget state. Callers that need to
/// keep encoding off the main isolate should use [buildImageDataUrlAsync]
/// instead of calling this directly.
String buildImageDataUrl(Uint8List bytes, String? mimeType) =>
    'data:${mimeType ?? 'image/jpeg'};base64,${base64Encode(bytes)}';

/// Runs [buildImageDataUrl] on a background isolate so the base64 encode
/// never stalls the UI thread. Safe to call from any context — the function
/// is top-level and carries no captured state.
Future<String> buildImageDataUrlAsync(Uint8List bytes, String? mimeType) =>
    Isolate.run(() => buildImageDataUrl(bytes, mimeType));

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
