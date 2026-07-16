# Phone Call Mode — Design Spec

**Date:** 2026-07-15
**Project:** Hermes Android (Flutter) — `Documents\GitHub\hermes-android`
**Status:** Approved, ready for implementation plan

## Problem framing

Add a "phone call mode" to the Hermes chat app: a dedicated, full-screen, hands-free
voice conversation with the agent that persists when the app is backgrounded or the screen
locks, presenting like an active phone call (persistent notification, audio focus).

Today the app does voice **per turn** — tap the mic in chat, dictate up to 60 s, auto-send,
auto-speak the reply. There is no continuous, hands-free, call-shaped experience and no
mechanism to keep it alive in the background.

**Consumer:** the phone user, wanting a natural back-and-forth voice conversation (talk,
agent replies, talk again) without tapping each turn.

**Constraints:** Flutter (not native Kotlin); reuse the existing `speech_to_text`,
`XttsService`, and `GatewayChatClient.sendMessageStreaming`; LAN/Tailscale reachability
to Gateway + XTTS server as today.

## I/O contracts

- **Input:** user taps a phone icon in a chat session → enters call mode bound to that
  session. Voice turns: speech_to_text recognized phrases (text). Loop is driven by STT
  final results and XTTS playback completion.
- **Transform:** `listen → finalResult(text) → sendMessageStreaming(sessionId, text)
  → tokens accumulate → onDone(reply) → xtts.speak(reply, onComplete) → onComplete
  → listen again`. Hang-up stops everything.
- **Output:** spoken agent replies (XTTS WAV playback via audioplayers) + a live call UI
  (state label, controls) + a persistent foreground notification while the call is active.
- **Edge cases:** mic permission denied, STT unavailable, XTTS server down, Gateway send
  failure, barge-in (user talks over TTS — ignored in v1), app backgrounded / screen lock,
  real phone call interrupting (audio focus loss), 60 s listen with no speech, hang-up
  mid-speech.

## Chosen approach

**In-app call screen + hands-free (auto VAD) turn-taking + foreground service.**

A full-screen `CallScreen` (go_router route `/call/:sessionId`) launched from a phone icon
in the chat app bar. A `CallController` (ChangeNotifier) runs a state-machine loop
(`listening → thinking → speaking → listening…`) that owns the `speech_to_text` mic, the
`XttsService`, and calls `GatewayChatClient.sendMessageStreaming` directly per turn. A
foreground service (`flutter_foreground_task`, new dep) holds a persistent notification +
wake lock + audio focus so the call survives backgrounding and screen lock.

Audio routes to the **speaker** (audioplayers media channel) by default. **Barge-in is off
in v1** — the agent's TTS must finish playing before listening resumes.

### Rejected alternatives

- **Real system call (Android Telecom self-managed ConnectionService):** maximum realism
  (lock-screen call UI, Bluetooth/car buttons) but heavy native integration, stricter
  runtime permissions, and fragile OEM behavior. Rejected — the in-app screen delivers the
  call feel with far less surface area.
- **Push-to-talk turn-taking:** tap/hold to speak. Simpler and robust, but not hands-free
  and not call-like. Rejected for v1 (could be added as a fallback later if auto-VAD proves
  unreliable in noisy environments).
- **Simple continuous voice toggle (no dedicated screen):** flip always-listen + auto-speak
  inside the existing chat, no call UI, no foreground service. Rejected — no persistence, no
  call presentation; misses the point of a "phone call mode."

## Components (new)

1. **`lib/core/screens/call_screen.dart`** — full-screen UI. Caller identity (session
   name/title), a live state label (`Listening…` / `Thinking…` / `Speaking…`), mute toggle,
   speaker toggle, and a prominent hang-up button. Binds to a `CallController`.
2. **`lib/core/services/call_controller.dart`** (`ChangeNotifier`) — the loop. Owns
   `SpeechToText` + `XttsService` + a `GatewayChatClient`. Exposes state
   (`CallState { idle, listening, thinking, speaking }`) and methods
   `start(session)`, `hangUp()`, `setMuted(bool)`. Drives the listen→send→speak→listen
   cycle, wiring `speech_to_text` finalResult → `sendMessageStreaming` onDone →
   `xtts.speak(onComplete:)` → resume listen.
3. **Foreground service** via **`flutter_foreground_task`** (new dependency) — started on
   call enter, stopped on hang-up. Persistent notification "Hermes call in progress",
   wake lock, and audio focus request (`AUDIOFOCUS_GAIN_TRANSIENT` / media usage) so other
   audio apps pause. Requires Android manifest entries: foreground service type
   (`microphone` + `mediaPlayback`), `FOREGROUND_SERVICE`,
   `FOREGROUND_SERVICE_MICROPHONE`, `POST_NOTIFICATIONS`, plus the existing `RECORD_AUDIO`.
4. **Entry point + routing** — phone icon in `chat_screen.dart` TopAppBar →
   `context.push('/call/${session.id}')`; go_router route registered in the app router.

### Reused (no new code)

- `GatewayChatClient.sendMessageStreaming(sessionId, text, onToken, onDone, onError)` —
  the call loop calls this per turn instead of the chat screen's `_sendMessage`.
- `XttsService.speak(text, {onComplete})` — the existing `onComplete` hook (added for the
  replay feature) is exactly the "resume listening after speech ends" signal.
- `speech_to_text` initialization pattern from `chat_screen._initVoice` (locale derived from
  saved XTTS language pref).

## Data flow

```
enter call → start foreground service + audio focus + mic perm
  state = listening: speech_to_text.listen(dictation, 60s)
    finalResult(text) ────────────────────────────────────┐
                                                          ▼
  state = thinking: gateway.sendMessageStreaming(session, text)
    onToken(tok) → accumulate reply text
    onDone ──────────────────────────────────────────────┐
                                                         ▼
  state = speaking: xtts.speak(fullReply, onComplete:)
    onComplete ──────────────────────────────────────────┐
                                                         ▼
  state = listening: (loop back)
hang-up → speechToText.stop() + xtts.stop() + stop service + release focus → pop to chat
```

## Error handling / failure modes

| Case | Handling |
|------|----------|
| Mic permission denied | Block call start; show rationale, re-request; cancel if denied |
| STT unavailable (`_speechAvailable=false`) | Show error, allow cancel (no PTT fallback in v1) |
| XTTS server unreachable | Reply is silent; show "voice offline" indicator; **keep listening** (loop continues) |
| Gateway send fails (`onError`) | Snackbar the error; resume listening |
| Barge-in (user talks while TTS plays) | Ignored in v1 — TTS finishes, then listens |
| App backgrounded / screen locks | Foreground service + wake lock keep loop alive |
| Real phone call / audio focus loss | Pause our TTS + mic on focus loss; resume after focus regained |
| 60 s listen, no speech | Re-arm listen automatically (stay in call) |
| Hang-up mid-speech | `xtts.stop()` + `speechToText.stop()` + stop service, exit clean |
| Hang-up mid-stream (thinking) | `gateway.abort()` + stop service, exit clean |
| Controller `dispose` without hang-up | Treat as hang-up (defensive cleanup) |

## Testing strategy

- **Unit (`call_controller`):** fake `SpeechToText`, `XttsService`, `GatewayChatClient`.
  Assert state transitions `listening→thinking→speaking→listening`; finalResult drives a send;
  onDone drives speak; onComplete re-arms listen; hangUp stops all and releases; onError
  resumes listening; 60 s timeout re-arms.
- **Widget (`call_screen`):** renders state label per `CallState`; mute/speaker/hang-up
  buttons call the controller; denied-permission path shows rationale.
- **Integration (manual):** start call from a chat → speak a turn → hear reply → speak again
  (hands-free loop). Background the app → notification persists, audio continues. Lock
  screen → call survives. Hang-up → returns to chat, notification gone, no orphaned audio.
  Kill XTTS mid-call → silent replies, loop continues. Trigger a real incoming call → audio
  pauses/resumes.

## Scope

Multi-file sub-project: ~4 new files (`call_screen.dart`, `call_controller.dart`, foreground
service wiring, router entry) + 1 new dependency (`flutter_foreground_task`) + Android
manifest changes (foreground-service type + permissions). Warrants an implementation plan
broken into skeleton → happy path → edge cases → polish.
