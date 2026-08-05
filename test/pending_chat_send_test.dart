import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/pending_chat_send.dart';

void main() {
  test(
    'failed image send removes its optimistic rows and retains attachment',
    () {
      final imageBytes = Uint8List.fromList([1, 2, 3]);
      final pending = PendingChatSend(
        text: 'Describe this',
        imageBytes: imageBytes,
        imageMimeType: 'image/png',
      );
      final prior = <String, dynamic>{
        'role': 'assistant',
        'content': 'Earlier reply',
      };
      final messages = <Map<String, dynamic>>[prior];

      pending.appendOptimisticRows(messages);
      expect(messages[messages.length - 2]['content'], isA<List<dynamic>>());
      pending.rollbackOptimisticRows(messages);

      expect(messages, hasLength(1));
      expect(messages.single, same(prior));
      expect(pending.imageBytes, same(imageBytes));
      expect(pending.imageMimeType, 'image/png');
    },
  );
}
