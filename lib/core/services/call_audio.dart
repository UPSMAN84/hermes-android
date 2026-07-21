// Native (Android AudioManager) audio routing for phone-call-mode. Switches
// the device into a call audio state so mic + playback use a connected
// Bluetooth earpiece (HFP/SCO) instead of the loudspeaker. The Dart-side
// `startCallAudio` resolves only once Bluetooth SCO has actually connected
// (or timed out / is unavailable), so the speech recognizer is started AFTER
// the BT mic stream is live — otherwise Android hands it the phone mic and
// the BT earpiece user is silent.
import 'package:flutter/services.dart';

class CallAudio {
  static const MethodChannel _channel = MethodChannel('hermes_audio');

  /// Enter call audio mode + wait for Bluetooth SCO to connect.
  ///
  /// Returns `true` if a Bluetooth earpiece is the active audio route when the
  /// future completes (use it for mic input). Returns `false` if SCO is
  /// unavailable, timed out, or the device fell back to the handset. Failures
  /// are swallowed: the call proceeds on the default speaker either way.
  static Future<bool> startCallAudio() async {
    try {
      final ok = await _channel.invokeMethod<bool>('startCallAudio');
      return ok ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  /// Leave call audio mode: stop SCO, MODE_NORMAL.
  static Future<void> stopCallAudio() async {
    try {
      await _channel.invokeMethod('stopCallAudio');
    } on PlatformException catch (_) {
      // Ignore.
    } on MissingPluginException catch (_) {
      // Ignore.
    }
  }
}