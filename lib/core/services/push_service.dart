// Push notification device registration (Firebase Cloud Messaging), wired to
// the gateway's /api/devices/register contract (gateway/platforms/push.py on
// the Hermes gateway). Registration only does anything useful when BOTH sides
// are configured:
//   - this app has android/app/google-services.json from a real Firebase
//     project (not included in this repo), and
//   - the gateway has a `platforms.push` block (service account + project id).
// Either side missing is treated as "push not available", not an error —
// nothing else in the app depends on push working, so every failure path
// here fails quiet rather than surfacing to the user.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_manager.dart';

/// Best-effort mobile push via FCM.
///
/// The gateway's push adapter routes by a `chat_id` key (e.g.
/// `"telegram:123456"`) — the same routing key every other platform
/// adapter's `send()` takes — NOT by account. So this service pushes a
/// device's current FCM token to the gateway under a specific chat_id that
/// the user must supply per connection (see [chatIdFor] / [setChatIdFor]):
/// there is no way to auto-discover "which Telegram chat shares this
/// session" from the app side alone.
class PushService {
  static const _chatIdPrefKeyPrefix = 'push_chat_id_';

  final ApiClient _client;
  final SharedPreferences _prefs;

  StreamSubscription<String>? _tokenRefreshSub;
  bool _firebaseReady = false;

  PushService(this._client, this._prefs);

  static String _prefKey(String connectionId) =>
      '$_chatIdPrefKeyPrefix$connectionId';

  /// The push routing key (e.g. "telegram:123456") this device is
  /// registered against for [connectionId]. Empty until the user sets one.
  String chatIdFor(String connectionId) =>
      _prefs.getString(_prefKey(connectionId)) ?? '';

  /// Updates the routing key for [connectionId] and re-syncs registration:
  /// unregisters the device from the old key (if any) and registers it
  /// under the new one (if non-empty).
  Future<void> setChatIdFor(String connectionId, String chatId) async {
    final trimmed = chatId.trim();
    final previous = chatIdFor(connectionId);
    if (trimmed.isEmpty) {
      await _prefs.remove(_prefKey(connectionId));
    } else {
      await _prefs.setString(_prefKey(connectionId), trimmed);
    }
    if (previous.isNotEmpty && previous != trimmed) {
      await _unregisterCurrentToken(previous);
    }
    if (trimmed.isNotEmpty) {
      await _registerCurrentToken(trimmed);
    }
  }

  /// Initializes Firebase (no-op if already done; fails quiet if
  /// google-services.json is missing), requests notification permission, and
  /// — if a chat_id is already configured for [connectionId] — registers the
  /// current FCM token with the gateway. Safe to call every time a chat
  /// screen for [connectionId] opens; cheap when already started.
  Future<void> start(String connectionId) async {
    if (!await _ensureFirebase()) return;

    final messaging = FirebaseMessaging.instance;
    try {
      await messaging.requestPermission(alert: true, badge: true, sound: false);
    } catch (e) {
      debugPrint('[Push] requestPermission failed: $e');
    }

    final chatId = chatIdFor(connectionId);
    if (chatId.isNotEmpty) {
      await _registerCurrentToken(chatId);
    }

    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = messaging.onTokenRefresh.listen((newToken) {
      final current = chatIdFor(connectionId);
      if (current.isEmpty) return;
      _client.registerDevice(current, newToken).catchError((e) {
        debugPrint('[Push] token-refresh registration failed: $e');
        return false;
      });
    });
  }

  Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
  }

  Future<bool> _ensureFirebase() async {
    if (_firebaseReady) return true;
    try {
      await Firebase.initializeApp();
      _firebaseReady = true;
      return true;
    } catch (e) {
      // No google-services.json / no Firebase project configured yet.
      debugPrint('[Push] Firebase not available: $e');
      return false;
    }
  }

  Future<void> _registerCurrentToken(String chatId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      final ok = await _client.registerDevice(chatId, token);
      debugPrint('[Push] registerDevice($chatId) -> $ok');
    } catch (e) {
      debugPrint('[Push] registerDevice($chatId) failed: $e');
    }
  }

  Future<void> _unregisterCurrentToken(String chatId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _client.unregisterDevice(chatId, token);
    } catch (e) {
      debugPrint('[Push] unregisterDevice($chatId) failed: $e');
    }
  }
}
