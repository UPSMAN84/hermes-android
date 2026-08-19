// Foreground-service wrapper so a chat generation survives the app being
// backgrounded (screen off, switched away) instead of the OS suspending the
// process and losing the SSE stream mid-reply. Local LLMs can take a while;
// this is what lets you lock the phone and get the reply without having to
// keep the screen on.
//
// Mirrors CallController's identical use of flutter_foreground_task for
// phone-call-mode; both share the 'hermes_background' notification channel
// registered once in main.dart's FlutterForegroundTask.init().
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'foreground_service_lease.dart';

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

/// Acquires the shared foreground-service lease (see ForegroundServiceLease)
/// so a chat send and phone-call mode can safely overlap without one killing
/// the other's background protection. Returns true if background protection
/// is actually in effect -- callers should only consider themselves
/// protected (e.g. set a local "service active" flag) when this is true, and
/// must call [stopBackgroundSendService] exactly once for every call here
/// that returned true, matching the lease's acquire/release contract.
/// Best-effort: a permission or platform failure just means the app behaves
/// as it did before this feature (suspended when backgrounded), not a hard
/// failure of the send itself.
Future<bool> startBackgroundSendService() {
  return ForegroundServiceLease.acquire(
    notificationTitle: 'Hermes',
    notificationText: 'Waiting for a reply…',
    serviceTypes: const [ForegroundServiceTypes.dataSync],
    callback: backgroundSendTaskStartCallback,
  );
}

Future<void> stopBackgroundSendService() => ForegroundServiceLease.release();
