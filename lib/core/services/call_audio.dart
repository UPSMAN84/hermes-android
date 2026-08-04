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
  static const EventChannel _focusChannel = EventChannel('hermes_audio_focus');

  static Stream<int> get audioFocusChanges =>
      _focusChannel.receiveBroadcastStream().where((event) => event is int).cast<int>();

  static Future<bool> requestAudioFocus() async {
    try {
      return await _channel.invokeMethod<bool>('requestCallAudioFocus') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> abandonAudioFocus() async {
    try {
      await _channel.invokeMethod('abandonCallAudioFocus');
    } catch (_) {}
  }

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

  /// Toggle the device loudspeaker while in call mode. The native side keeps
  /// MODE_IN_COMMUNICATION intact and only flips `isSpeakerphoneOn`. Returns
  /// the resulting speakerphone state, or `false` if the channel is missing /
  /// the call threw — the UI treats that as "switch failed".
  static Future<bool?> setSpeakerphone({required bool enabled}) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setSpeakerphone',
        {'enabled': enabled},
      );
      return ok;
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      return null;
    }
  }
}
