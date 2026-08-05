# Wire speaker button to real audio routing

## Context

In call mode the Speaker button currently only flips `_speakerOn` and redraws the UI; it never touches Android `AudioManager`. The user enters the call through `_applyCallAudio` (`lib/core/services/call_controller.dart:128-131`) which forces `MODE_IN_COMMUNICATION` and `isSpeakerphoneOn = false` via native SCO (`android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt:57-66`). The UI keeps claiming speaker is on. Reviewer flagged this as misaligned and a P0 release risk (`test plan: Speaker toggle is presentation-only`).

Outcome: tap Speaker → actually toggle `AudioManager.isSpeakerphoneOn` during an active call. Keep BT SCO start/stop unchanged. No new permission needed.

## Approach

Add one native method `setSpeakerphone(enabled: bool)` on the existing `hermes_audio` MethodChannel. Wire `CallAudio.setSpeakerphone()`. Make `CallController.toggleSpeaker()` async, dispatch to native, update state. Initial state at call entry reflects current native mode.

### Files

- `android/app/src/main/kotlin/com/hermesagent/hermes_android/MainActivity.kt`
  - Add `"setSpeakerphone"` branch in `configureFlutterEngine` switch (`MainActivity.kt:46-50`).
  - Implement `setSpeakerphone(am, result)`: read `enabled` arg, call `am.isSpeakerphoneOn = enabled`, return resulting state as Boolean. Reject null/non-bool with `IllegalArgumentException` → existing catch maps to `AUDIO_ERROR`. No mode change here — `MODE_IN_COMMUNICATION` set in `startCallAudio` stays.

- `lib/core/services/call_audio.dart`
  - Add `static Future<bool> setSpeakerphone({required bool enabled})`. Same pattern as `startCallAudio`/`stopCallAudio` (`call_audio.dart:19-28`): try-catch swallow `PlatformException`/`MissingPluginException`, return `false` on failure.

- `lib/core/services/call_controller.dart`
  - Change `bool _speakerOn = true;` initial state to a nullable or computed; reflect native post-start state.
  - `_applyCallAudio()` already returns `scoOn`. Add step after: query current speakerphone state to seed `_speakerOn` truthfully.
  - `toggleSpeaker()` becomes `Future<void> async`:
    ```dart
    void toggleSpeaker() async {
      final next = !_speakerOn;
      final ok = await CallAudio.setSpeakerphone(enabled: next);
      if (!ok) {
        _status = 'Speaker switch failed';
        notifyListeners();
        return;
      }
      _speakerOn = next;
      notifyListeners();
    }
    ```
  - `hangUp()` and `dispose()` do not need changes — `_restoreAudio` already returns to `MODE_NORMAL` via `stopCallAudio` (`MainActivity.kt:86-101`).

- `lib/core/screens/call_screen.dart`
  - `_ControlButton.onPressed` is typed `VoidCallback` (`call_screen.dart:272`). Keep that type. At the callsite (`call_screen.dart:259-263`), wrap the speaker handler in an unawaited async lambda so `_speakerOn` updates through `ChangeNotifier` and the icon re-renders:
    ```dart
    _ControlButton(
      icon: speakerOn ? Icons.volume_up : Icons.volume_off,
      label: 'Speaker',
      onPressed: () { controller.toggleSpeaker(); },  // fire-and-forget; controller updates via notifyListeners
    ),
    ```
  - Read the parent screen at `call_screen.dart:54-90` to confirm `speakerOn` is sourced from `controller.speakerOn` (likely via `Consumer<CallController>` or `AnimatedBuilder`). No widget-state changes required.

## Verification

1. `flutter test` — connection_manager tests unaffected; no widget tests for call screen exist (`test/widget_test.dart:1-7` placeholder). New test not required for v1 but recommend lightweight: assert `toggleSpeaker` flips `_speakerOn` after fake channel.

2. Manual on Android 13+:
   - BT earpiece connected: enter call → route is earpiece. Tap Speaker → route is loudspeaker, icon reflects state. Tap again → back to earpiece.
   - No BT: enter call → handset. Toggle speaker → loudspeaker/handset. Icon matches.
   - Hang up → `_restoreAudio` → `MODE_NORMAL`, state returns to media context.

3. Edge: kill Dart mid-toggle — next `toggleSpeaker` is a new invocation; Channel handler is idempotent (set same state twice is no-op).

4. Edge: toggle rapidly — last write wins, state stays consistent.

## Out of scope

- Adding a Toggle for `MODE_IN_COMMUNICATION` exit at idle.
- Removing the cosmetic `_speakerOn` field (kept for UI; now truthful).
- Settings persistence of last speaker state (caller asked for the bug, not preference).
- Fix `dispose()` audio restore or empty foreground task handler (separate, previously listed bugs).

## Risk

- `AudioManager.isSpeakerphoneOn = true` while `MODE_IN_COMMUNICATION` is set forces loudspeaker on Android — desired. No manifest change needed (no new permission).
- If the channel handler is missing (older APK still installed), CallAudio.setSpeakerphone returns false → controller shows status, no crash.
