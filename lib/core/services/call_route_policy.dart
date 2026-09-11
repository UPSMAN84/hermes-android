enum CallAudioPhase { listening, speaking }

enum CallNativeRoute { released, handset, speaker, bluetooth }

enum CallAudioFocusStrategy { manualCall, platformComponents }

CallAudioFocusStrategy callAudioFocusStrategy() =>
    CallAudioFocusStrategy.platformComponents;

CallNativeRoute callRouteForPhase({
  required CallAudioPhase phase,
  required bool bluetoothActive,
  required bool speakerOn,
}) {
  if (bluetoothActive) return CallNativeRoute.bluetooth;
  if (speakerOn) return CallNativeRoute.speaker;
  // Keep MODE_IN_COMMUNICATION active for both recognition and playback.
  // Releasing it between turns resets the microphone/audio route and can make
  // Android emit a recognizer transition sound.
  return CallNativeRoute.handset;
}
