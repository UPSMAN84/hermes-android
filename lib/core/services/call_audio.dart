// Native (Android AudioManager) audio routing for phone-call-mode. Switches
// the device into MODE_IN_COMMUNICATION so mic + playback get voice-quality
// processing and echo cancellation. The platform chooses the physical route
// automatically (Bluetooth, handset, or speaker) — we never call
// setCommunicationDevice() or startBluetoothSco(), because on Samsung OneUI
// those APIs trigger an AppOps UID attribution bug inside com.android.phone
// that throws SecurityException and destabilizes the telephony stack.
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

  /// Enter call audio mode (MODE_IN_COMMUNICATION). Returns true on success.
  /// The platform handles device routing automatically — Bluetooth earpieces
  /// are used when connected without explicit SCO management.
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

  /// Leave call audio mode: restore MODE_NORMAL.
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