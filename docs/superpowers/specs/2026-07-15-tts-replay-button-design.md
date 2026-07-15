# TTS Replay Button — Design Spec

**Date:** 2026-07-15
**Project:** Hermes Android (Flutter) — `Documents\GitHub\hermes-android`
**Status:** Approved, ready for implementation plan

## Problem framing

The user wants to manually re-hear (replay) any assistant message's TTS on demand,
independent of the auto-speak-on-reply behavior.

Currently TTS only fires automatically when a reply arrives with `speakResponse: true`
(set during the voice-input flow). There is no way to re-listen to a past message, and no
way to listen at all when spoken replies are off. The replay button gives explicit,
per-message control directly in the chat UI.

**Consumer:** the phone user, mid-conversation.
**Constraint:** reuse the existing `XttsService` (XTTS-v2 server, `audioplayers` playback).
No new dependencies.

## I/O contracts

- **Input:** user taps the speaker `IconButton` on an assistant message bubble.
- **Transform:** stop any current XTTS playback → extract speakable text (quoted dialog via
  `extractDialog`, else `stripForSpeech` fallback) → POST to XTTS `/tts_to_audio/` → play
  returned WAV.
- **Output:** audio plays; the tapped message's icon toggles to a stop state; resets to the
  speaker icon on playback completion or stop.
- **Edge cases:** no speaker configured (can't speak), XTTS server unreachable, empty
  speakable text, rapid taps, screen disposed mid-playback, message scrolled offscreen.

## Chosen approach

Per-message speaker `IconButton` on each **assistant** message bubble only (user messages
get no button). Tapping replays that message via the existing `XttsService`, re-synthesizing
on each tap — **no client-side audio cache**. A new `_speakingMessageId` field tracks which
message is actively speaking for icon state.

Replay is **decoupled from `_voiceReplyEnabled`** — it is a manual action and works even
with spoken replies off (the motivating use case: keep auto-speak off, replay chosen
messages). It does require a configured XTTS speaker.

### Rejected alternatives

- **Single "replay last" button** (app bar / input bar): simpler, but cannot replay older
  messages. Rejected — per-message matches standard chat UX and is far more useful at
  near-equal implementation cost.
- **Client-side WAV caching** for instant repeat replays: faster second replays, but adds
  cache lifecycle (eviction, size limits, invalidation) and complexity. Rejected now (YAGNI);
  one XTTS round-trip per tap is acceptable. Can be layered behind the same button later if
  latency becomes a problem.

## Components

1. **`lib/core/screens/chat_screen.dart`**
   - New state field `String? _speakingMessageId`.
   - New handler `_replayMessage(ChatMessage msg)`:
     1. `_xtts.stop()`.
     2. If `msg.id == _speakingMessageId` → clear it (toggle off), return.
     3. Else set `_speakingMessageId = msg.id`, extract speakable text, call
        `_xtts.speak(spoken, onComplete: …)`, clear state via the completion callback
        (mounted-guarded).
     4. Catch errors → snackbar, clear `_speakingMessageId`.
   - Speaker-config guard: if no speaker set in prefs → snackbar
     "Set a voice in Settings → Voice", no speak call.
   - Speaker `IconButton` rendered in/under each assistant bubble; icon `volume_up`
     normally, `stop` when `_speakingMessageId == msg.id`.

2. **`lib/core/services/xtts_service.dart`**
   - Add an optional `Future<void> Function()? onComplete` parameter to `speak()`,
     wired to `AudioPlayer.onPlayerComplete`. This is the committed completion hook
     (chosen over an exposed stream — simpler, sufficient for the single screen that
     needs it; backward-compatible since the param is optional).
   - The hook must also fire on `stop()` and on a synthesis error, so the UI always resets.
   - Minimal and backward-compatible (optional param; existing callers unaffected).

## Data flow

```
tap bubble
  → _replayMessage(msg)
  → _xtts.stop()
  → set _speakingMessageId = msg.id  (setState)
  → XttsService.extractDialog(msg.text)  (fallback stripForSpeech)
  → _xtts.speak(text, onComplete)
  → POST {base}/tts_to_audio/  → WAV
  → audioplayers plays WAV
  → onPlayerComplete (or stop/error)
  → clear _speakingMessageId  (mounted-guarded setState)
```

## Error handling / failure modes

| Case | Handling |
|------|----------|
| No speaker configured | Snackbar "Set a voice in Settings → Voice"; no speak call |
| XTTS server unreachable / non-2xx | `speak()` throws → caught → snackbar "Can't reach XTTS server"; clear `_speakingMessageId` |
| Empty speakable text (after strip) | Silent no-op; do not set speaking state |
| Rapid tapping | `stop()`-then-`speak()` ordering; idempotent |
| Screen disposed mid-speak | Existing `_xtts.dispose()` in `dispose()`; every `setState` guarded by `mounted` |
| Message scrolled offscreen while speaking | Keep playing (least surprising); icon resets on completion regardless |

## Testing strategy

- **Unit (`xtts_service`):** `extractDialog` / `stripForSpeech` already covered. Add: `speak()`
  invokes `onComplete` on player completion, and on error (mock `http.Client` + `AudioPlayer`).
- **Widget (`chat_screen`):** render a chat with assistant messages → tap speaker → assert
  `_speakingMessageId` set and icon toggled; tap again → stopped; no-speaker guard → snackbar
  shown; server-error path → snackbar + state cleared.
- **Manual:** build + install → tap replay on messages with and without quoted dialog; with
  spoken replies on and off; kill the XTTS server mid-replay and observe graceful failure.

## Scope

Single feature, 2 files (`chat_screen.dart`, `xtts_service.dart`), no new dependencies.
Fits one implementation plan.
