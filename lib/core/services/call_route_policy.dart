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
  return phase == CallAudioPhase.listening
      ? CallNativeRoute.released
      : CallNativeRoute.handset;
}
