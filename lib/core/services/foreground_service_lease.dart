// Coordinates ownership of flutter_foreground_task's single process-global
// foreground service between chat's background-send keepalive
// (background_activity_service.dart) and phone-call mode (call_controller.dart).
//
// The plugin has no concept of "two independent leases": distinct serviceIds
// only label the Android notification, startService() throws
// ServiceAlreadyStartedException if a service is already running (both
// previous call sites discarded the returned ServiceRequestResult and never
// noticed), and stopService() takes NO id at all -- it stops whichever
// service is currently running, full stop, regardless of which feature
// started it. Without this coordinator, overlapping a call and a background
// chat send meant whichever operation finished (or started) first could
// silently kill the other's background-suspend protection.
//
// A real service restart mid-lease isn't attempted when a second acquirer
// wants different `serviceTypes`: updateService() can change the
// notification but not the declared types once started, and the plugin has
// no supported way to union them after the fact. In practice this is fine --
// any running foreground service is enough to keep the whole process alive
// against OS suspension, which is the actual guarantee both callers need;
// the declared type mainly governs what background *resource use* Android
// permits under that service, which each caller already restricts itself to
// its own work regardless of what type is on record.
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class ForegroundServiceLease {
  ForegroundServiceLease._();

  static int _refCount = 0;

  /// Set the instant a 0 -> 1 start attempt begins, cleared once it settles.
  /// Without this, two acquire() calls arriving before either's first
  /// `await` resolves would BOTH see _refCount == 0 and both call
  /// startService() concurrently -- the exact "two concurrent callers race
  /// past the same unset check" bug this lease exists to prevent one layer
  /// up. A second concurrent caller rides on this Future instead.
  static Future<bool>? _startingFuture;

  /// Acquires a lease. On the first (0 -> 1) acquire, actually starts the
  /// service with the caller's parameters; a concurrent second acquirer
  /// just increments the refcount and rides on whatever's already running
  /// (or, if a start is already in flight, rides on that same attempt).
  ///
  /// Returns true if the service is confirmed running under this lease
  /// (already running, or this call started it successfully) -- false only
  /// if a genuinely fresh start failed, in which case the caller must NOT
  /// treat itself as background-protected (matches the previous best-effort
  /// contract: a failure here should not block the operation, only its
  /// background persistence).
  static Future<bool> acquire({
    required String notificationTitle,
    required String notificationText,
    required List<ForegroundServiceTypes> serviceTypes,
    required Function callback,
    int serviceId = 1,
  }) {
    if (_refCount > 0) {
      _refCount++;
      return Future.value(true);
    }
    final inFlight = _startingFuture;
    if (inFlight != null) {
      return inFlight.then((ok) {
        if (ok) _refCount++;
        return ok;
      });
    }
    final attempt = _start(
      notificationTitle: notificationTitle,
      notificationText: notificationText,
      serviceTypes: serviceTypes,
      callback: callback,
      serviceId: serviceId,
    );
    _startingFuture = attempt;
    attempt.whenComplete(() => _startingFuture = null);
    return attempt;
  }

  static Future<bool> _start({
    required String notificationTitle,
    required String notificationText,
    required List<ForegroundServiceTypes> serviceTypes,
    required Function callback,
    required int serviceId,
  }) async {
    try {
      final notifPerm =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notifPerm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: serviceId,
        notificationTitle: notificationTitle,
        notificationText: notificationText,
        serviceTypes: serviceTypes,
        callback: callback,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('[ForegroundServiceLease] start failed: ${result.error}');
        return false;
      }
      _refCount = 1;
      return true;
    } catch (e) {
      debugPrint('[ForegroundServiceLease] start failed: $e');
      return false;
    }
  }

  /// Releases a lease. Only stops the real service on the last (1 -> 0)
  /// release. Safe to call even if [acquire] returned false or was never
  /// called by this holder -- a no-op once the refcount is already at 0, so
  /// a caller that gave up waiting for a failed acquire can still
  /// unconditionally call release() in a finally block.
  static Future<void> release() async {
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount > 0) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
