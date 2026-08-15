// Foreground-service wrapper so a chat generation survives the app being
// backgrounded (screen off, switched away) instead of the OS suspending the
// process and losing the SSE stream mid-reply. Local LLMs can take a while;
// this is what lets you lock the phone and get the reply without having to
// keep the screen on.
//
// Mirrors CallController's identical use of flutter_foreground_task for
// phone-call-mode; both share the 'hermes_background' notification channel
// registered once in main.dart's FlutterForegroundTask.init().
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void backgroundSendTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(_BackgroundSendTaskHandler());
}

// No-op handler: the actual send/stream loop runs on the main isolate. This
// just lets the service exist (notification + foreground status) so the OS
// doesn't suspend the process mid-stream.
class _BackgroundSendTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Distinct from CallController's serviceId (256) so the two never collide
/// if somehow both were active at once.
const int backgroundSendServiceId = 257;

/// Starts the foreground service. Safe to call while already running.
/// Best-effort: a permission or platform failure is logged and swallowed —
/// losing the background-keepalive just means the app behaves as it did
/// before this feature (suspended when backgrounded), not a hard failure.
Future<void> startBackgroundSendService() async {
  try {
    final notifPerm = await FlutterForegroundTask.checkNotificationPermission();
    if (notifPerm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    await FlutterForegroundTask.startService(
      serviceId: backgroundSendServiceId,
      notificationTitle: 'Hermes',
      notificationText: 'Waiting for a reply…',
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      callback: backgroundSendTaskStartCallback,
    );
  } catch (e) {
    debugPrint('[BackgroundSend] foreground service start failed: $e');
  }
}

Future<void> stopBackgroundSendService() async {
  try {
    await FlutterForegroundTask.stopService();
  } catch (_) {}
}
