// One-shot local notification for "your reply is ready" when a generation
// finishes while the app is backgrounded. Distinct from
// background_activity_service.dart's ongoing foreground-service notification
// ("Waiting for a reply…"), which is tied to that service's lifetime and
// disappears the instant the service stops -- nothing tells the user the
// reply actually landed without this.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class ReplyNotificationService {
  ReplyNotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channelId = 'hermes_reply_ready';
  static const _channelName = 'Reply Ready';

  static Future<void> _ensureInitialized() async {
    if (_ready) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(settings: initSettings);
    _ready = true;
  }

  /// Shows a dismissible "Hermes replied" notification with a text preview.
  /// [sessionId] becomes the notification id (hashed), so a second reply in
  /// the same session updates the existing notification instead of stacking,
  /// while a different session's reply gets its own. Failures are swallowed
  /// -- a missing notification permission must not surface as a chat error.
  static Future<void> showReplyReady(
    String sessionId, {
    required String title,
    required String preview,
  }) async {
    try {
      await _ensureInitialized();
      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription:
            'Shown when a reply finishes while Hermes is in the background.',
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
        styleInformation: BigTextStyleInformation(preview),
      );
      final details = NotificationDetails(android: androidDetails);
      await _plugin.show(
        id: sessionId.hashCode,
        title: title,
        body: preview,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('[ReplyNotification] show failed: $e');
    }
  }
}
