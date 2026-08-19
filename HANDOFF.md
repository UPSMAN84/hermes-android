# Handoff — Codex Deep Pipeline Audit Fix-Through

**Source document:** `C:\Users\charl\Desktop\hermes-deep-pipeline-audit-2026-08-19.md` (external audit, method described as fresh inspection + disposable emulator/mock-server tests + release build). Treat every claim in it as **unverified until checked against actual code in this repo** — verify first, then fix. One claim already double-checked this session ("replace media polls with SSE events") turned out to be a false positive from a *different*, less careful pass; this document itself is more careful (explicitly credits the SSE-filename guard as already correct), but individual line numbers can still drift as the file changes — re-grep before trusting a cited line number.

**Working tree:** all changes uncommitted (never committed this session). Run `git status --short` to see the full current diff list before starting each item, so you don't refix something already done.

**Verify-before-fix workflow used throughout:** read the cited code, confirm the mechanism the audit describes actually behaves that way (don't take the claim on faith), design the smallest correct fix, run `flutter analyze` + `flutter test` after every change, add a regression test proving the specific behavior, then move on.

---

## Status

### ✅ Fixed, tested, verified (this session)

**#1 — Streaming POST retries can duplicate turns**
`lib/core/services/connection_manager.dart`, `sendMessageStreaming`. `Future.timeout()` does not cancel the underlying `_api._http.send(request)` — a slow-but-eventually-successful server response could still be in flight server-side when the client gave up and retried, risking a duplicate turn. Fixed: a `TimeoutException` on the connect attempt is now terminal (`onError`), not retried — only genuine pre-send connection failures (DNS, refused, socket error) go through the retry ladder. Also made `connectTimeout` an injectable constructor param (`GatewayChatClient(api, connectTimeout: ...)`) so this is testable without a real 15s wait.
Tests: `test/connection_manager_test.dart` — "does NOT retry after a connect timeout".

**#2 — SSE errors/truncated streams reported as success**
Same file, same method. A clean-but-premature socket close (no exception — Dart's `StreamSubscription.onDone`, indistinguishable at that layer from a real finish) was always treated as full success, so a truncated reply could be spoken/persisted/auto-continued on as if complete. Fixed: track whether the literal `data: [DONE]` frame was ever seen (`sawDone` flag, set via new `_frameDataIs()` static helper mirroring `parseSseFrame`'s data-line extraction). If the stream closes without having seen it, route through `onError('Connection closed before the reply finished')` instead of `onDone()` — this reuses the *already-built* interrupted-reply recovery path in `chat_screen.dart`'s `_handleSendError` (checks the gateway for a persisted partial turn, shows the right UI) rather than needing new UI.
**Required updating two test fakes** that faked "success" without a `[DONE]` frame (now correctly caught by the new detection) — `_CountingFailThenSucceedClient` in `connection_manager_test.dart`, and `_FakeClient` in `chat_screen_test.dart`. Both now append `data: [DONE]\n\n` after their configured frames, matching real gateway behavior.
Tests: `test/connection_manager_test.dart` — "closes cleanly without [DONE] is reported as an error" + "closes with [DONE] is reported as a normal success" (positive control).

Test count after #1+#2: **159/159 passing**, `flutter analyze` clean.

**#3 — Chat and call foreground services destroy each other**
`lib/core/services/background_activity_service.dart`, `lib/core/screens/chat_screen.dart`, `lib/core/services/call_controller.dart`.

Confirmed by reading the plugin source: `flutter_foreground_task` manages ONE process-global service. `startService()` throws `ServiceAlreadyStartedException` if already running (both call sites previously discarded the `ServiceRequestResult`), and `stopService()` takes no service-ID at all — it stops whichever service is running, full stop, regardless of who started it. Distinct `serviceId`s (256 call, 257 chat-send) only labelled the notification.

Fixed: new `lib/core/services/foreground_service_lease.dart` (`ForegroundServiceLease`) — a static refcounted lease. `acquire()` only calls the real `startService()` on a genuine 0→1 transition; later concurrent acquirers just increment and ride on what's already running. `release()` only calls `stopService()` on the 1→0 transition, and safely no-ops if called without a matching successful acquire. Also closes a *second*, subtler race: two `acquire()` calls arriving before either's first `await` resolves would otherwise both see refcount 0 and both call `startService()` concurrently — guarded with an in-flight `_startingFuture` that a concurrent second caller rides on instead (same coalescing pattern already used in `MediaCacheService`/`SpeechRecognitionCoordinator` this session).

`background_activity_service.dart`'s `startBackgroundSendService()`/`stopBackgroundSendService()` now route through the lease (signature changed to `Future<bool>`, but the chat_screen.dart call site didn't need updating — it already called it fire-and-forget without awaiting the result, and the lease's `release()` is safe to call even if the matching `acquire()` hasn't resolved yet). `call_controller.dart` gained `_foregroundServiceActive` (mirrors chat's flag) plus `_startForegroundService()`/`_stopForegroundService()` wrappers around the lease, replacing all 4 direct `FlutterForegroundTask.startService()/stopService()` call sites.

**Not tested with an automated test** — `ForegroundServiceLease` calls real `flutter_foreground_task` platform-channel methods (`checkNotificationPermission`, `startService`, `stopService`), which throw `MissingPluginException` in a plain `flutter_test` run with no platform mocking, and this plugin has no existing test-mocking setup in this repo (matches the audit's own note that `CallController` has near-zero coverage). Verified by direct reasoning instead (documented in the session, not re-derived here) — if you want real coverage, the plugin would need its method channel mocked via `TestDefaultBinaryMessengerBinding` or similar, which is more setup than this fix alone warrants; consider it a good target for the "real-device pipeline suite" addon instead.

`flutter analyze` clean, `flutter test` 159/159 (unchanged from before #3 — nothing in this fix was unit-testable without new platform-mocking infrastructure).

### ✅ Fixed, tested, verified (continued — all 8 high-severity findings done)

**#4 — Muting a call can transmit buffered speech — ✅ FIXED**
`lib/core/services/call_controller.dart`, `setMuted()` + `_onResult()`.

Verified directly against the installed `speech_to_text-7.4.0` source: `cancel()`'s own doc comment says "Canceling means that there will be no final result returned from the recognizer" — the implied contrast confirms `stop()` does NOT make that guarantee; it still delivers one more final result asynchronously after returning. `_onResult` checked `!_active || epoch != _listenEpoch` but never `_muted`, so that stray post-stop result sailed through and got sent to the gateway as if the user hadn't muted.

Fixed: `setMuted(true)` now calls `_speech.cancel()` instead of `.stop()` (root fix — the package guarantees no result follows), plus bumps `_listenEpoch` and clears `_lastTranscript` (belt-and-braces, matches the existing epoch-invalidation pattern `_listen()` already uses). Also added an explicit `_muted` check to `_onResult`'s guard clause directly — technically redundant given the epoch bump (nothing else sets `_muted`), but kept as a self-evidently-correct guard rather than relying solely on the epoch invariant holding forever.

Not unit-tested — same `CallController`/platform-channel limitation as #3 (no existing test harness, would need `speech_to_text` platform mocking). `flutter analyze` clean, `flutter test` 159/159 (unchanged).

**#5 — Stop cannot cancel pending XTTS/Chatterbox synthesis — ✅ FIXED**
`lib/core/services/xtts_service.dart`, `lib/core/services/chatterbox_service.dart`.

Verified directly: both services' `_speakEpoch` was only bumped inside `speakPrepared()`/`stop()`, never at `speak()`/`prepare()` entry — so a `stop()` that landed while `prepare()`'s HTTP call was in flight had nothing to invalidate yet. When `prepare()` eventually resolved, `speak()` handed the result straight to `speakPrepared()`, which unconditionally re-stops and re-claims its own fresh epoch and plays it regardless of the intervening stop. Confirmed a real call site hits this: `chat_screen.dart:2034`'s volume-toggle button calls `_xtts.stop()` without awaiting the in-flight `speak()` at all.

Fixed with a single generation counter renamed `_opEpoch`, now claimed at the *top* of `speak()` (before `prepare()`'s network round trip) and checked again after `prepare()` returns — a mismatch means stop()/a newer speak() superseded this call, so the stale result is discarded instead of played. Also added a cancel signal (`Completer<Never>` raced via `Future.any` against the network request) so `stop()` unblocks a pending `prepare()` immediately instead of waiting out its full 45s timeout — deliberately *not* implemented as "close an owned `http.Client` per call," because that would have broken this repo's existing `httpClient:`-injection test seam (`MockClient`) and, if applied to the shared `_http` instead, would have permanently broken every future request on the instance (Dart's `http.Client` can't be reopened after `close()`). Both the success and the exception path from a cancelled `prepare()` still fire the caller's `onComplete` (matching `TtsProvider`'s documented "stopped" contract) rather than swallowing it or surfacing a spurious "TTS failed" error for what was a deliberate Stop — an initial version of this fix returned silently on a cancelled `speak()`, which would have left `chat_screen.dart`'s `_speakingMessage` UI state stuck forever; caught before landing by tracing the real call site through to its `finish()` closure.

Tests: new `test/tts_cancellation_test.dart` — both services' `stop()` unblocks a `speak()` whose synthesis POST is deliberately never resolved by the mock (proves the fix without waiting out a timeout), and `onComplete` fires exactly once. Required mocking `xyz.luan/audioplayers` + `xyz.luan/audioplayers.global` method channels, since both services eagerly construct a real `AudioPlayer` in their constructor even though these tests never reach the play step.

`flutter analyze` clean, `flutter test` 161/161.

**#6 — "Script only" cron creates an unintended enabled job — ✅ FIXED**
`lib/core/screens/cron_screen.dart`, `lib/core/services/connection_manager.dart` (`DashboardClient.createJob`).

Verified against the installed gateway source (`C:\Users\charl\AppData\Local\hermes\hermes-agent`): the claim was right about the mechanism, but the on-disk app code had *already* been hardened to surface the follow-up-PATCH failure instead of silently swallowing it (a snackbar: `Job added, but "script only" flag failed to save: ...`) — so the "silent" framing in the audit was stale. That partial mitigation just made the real bug *visible* instead of fixing it: the Add Job dialog never had a script-path field at all, and unconditionally required a non-empty prompt — so toggling "Script only" was 100% guaranteed to fail every time (`no_agent=True requires a script`, confirmed in `hermes_cli/web_server.py`'s `_validate_dashboard_cron_effective_job`), always leaving a live, enabled, agent-driven job with the prompt as its instruction. The feature was dead on arrival, not flaky.

Also confirmed directly in the gateway source that the fix the audit suggested is fully supported server-side: `CronJobCreate` (`hermes_cli/web_models.py`) already accepts `script` and `no_agent` in the *create* body, and `_create_cron_job_sync` validates them atomically *before* calling into `cron/jobs.py` — an invalid combination (`no_agent=true` with no script) 400s with nothing ever created, so there's no partial-creation race to guard against once the client sends both fields together.

Fixed: `DashboardClient.createJob` now takes `script`/`noAgent` params and sends them in the single create POST — the two-step create-then-PATCH dance is gone entirely, along with its guaranteed-to-fail follow-up. `cron_screen.dart`'s job dialog gained a "Script path" field (shown when "Script only" is toggled on) and its validation now mirrors the backend's own rule: script required when script-only, prompt required otherwise (previously prompt was unconditionally required, which is what made the toggle impossible to use correctly). The edit dialog now round-trips `job['script']` too, so an existing job's script path can be viewed/changed the same way its prompt can.

Tests: `test/connection_manager_test.dart` — "createJob sends no_agent and script in the same create request (atomic, not a follow-up PATCH)" + "createJob omits script when not given" (positive control). No widget test for the dialog itself (no existing widget-test harness for `CronScreen` in this repo, matching the existing `cron_screen_test.dart`'s pure-function-only scope); the client-level atomicity is what the fix is actually about.

`flutter analyze` clean, `flutter test` 163/163.

**#7 — Memory screen is incompatible with the current Hermes API — ✅ FIXED**
`lib/core/screens/memory_screen.dart`.

Verified directly against `hermes_cli/web_server.py:12797` (`GET /api/memory`): confirmed the claim exactly — the handler returns `{"active": ..., "providers": [...], "builtin_files": {"memory": bytes, "user": bytes}}`, none of which are `entries`/`memory` list keys, so the old `_loadMemory()` always fell through to an empty list on a valid 200. Went further than the audit's framing while verifying: the `/api/config` fallback path (for older servers without `/api/memory`) was *also* stale — `_discover_memory_provider_statuses` confirms `config.yaml`'s `memory` key is itself now `{"provider": "..."}` (a single config dict), not a list of `{target, content}` entries, so that fallback's `mem is Map` branch would have produced one bogus fake "entry" (`{target: "provider", content: "mem0"}`) instead of correctly showing nothing. Checked every `/api/memory*` route in the gateway (`providers/{name}/config` GET+PUT, `providers/{name}/setup`, `memory/provider` PUT, `memory/reset` POST) — none of them return memory *content* (individual facts/entries) at all in this version of the gateway; only status/config. The "memory entry browser" premise the screen was built around no longer has any backing endpoint.

Fixed by rewriting the screen to match what's actually exposed: active backend (built-in file-based vs. a named external provider), built-in `MEMORY.md`/`USER.md` sizes (content isn't fetchable, so size is shown with an explicit "content isn't browsable from here" note rather than implying more than the API provides), and the discovered-providers list with its `status` (ready/needs_config/unavailable/missing). Dropped the `/api/config` fallback entirely — it was chasing a format that no longer exists either.

No regression test added: no existing widget-test harness for `MemoryScreen` (or any dashboard screen) in this repo — `DashboardClient` is constructed internally in `initState()`, not injectable, matching `cron_screen_test.dart`'s own scope (pure functions only, no widget tests for that screen either). Verified by direct comparison of the new parsing code against the real gateway handler's return statement instead.

`flutter analyze` clean, `flutter test` 163/163 (unchanged — no behavior touched here has existing coverage to regress).

**#8 — Gallery save incomplete on older Android — ✅ FIXED**
`android/app/src/main/AndroidManifest.xml`, `lib/core/services/media_export_service.dart`.

Verified against the installed `gal-2.3.3` package: its own example manifest (`gal-2.3.3/example/android/app/src/main/AndroidManifest.xml`) confirms the exact claim — `READ_EXTERNAL_STORAGE`/`WRITE_EXTERNAL_STORAGE` both capped at `maxSdkVersion="29"`, plus `android:requestLegacyExternalStorage="true"` on `<application>`. This app's manifest (`minSdk = 24` in `build.gradle.kts`) had none of them, and the plugin's own bundled `AndroidManifest.xml` is empty (no auto-merge), so nothing else would have supplied them.

Went further while verifying: reading `GalPlugin.java` (the native Android implementation) showed `putImage`/`putVideo` call straight into a file write with **no permission check or request** — `hasAccess`/`requestAccess` are separate methods the Dart caller must invoke itself; `requestAccess` is the only path that actually calls `ActivityCompat.requestPermissions()` to show the OS dialog. `media_export_service.dart`'s `saveToGallery()` (written this session for the save-to-gallery feature) never called it. So the manifest fix alone would have been incomplete: on a fresh install on API 24-29, the permission would never be granted *and the OS dialog would never even appear*, since only `requestAccess()` triggers it — every save attempt would permanently report "Photos permission denied" with no way out. Fixed by calling `Gal.hasAccess(toAlbum: true)` / `Gal.requestAccess(toAlbum: true)` before the write (`toAlbum: true` matches the `album: 'Hermes'` save target — per the native source, a plain gallery save skips the prompt on API 29 but a named-album save doesn't). No-ops correctly on API 30+, where `hasAccess` is unconditionally true in the native code (scoped storage handles per-write consent instead).

Caught and fixed a build-breaking XML mistake before it could land: my first draft of the manifest comment used `--` as a dash separator, which is illegal inside an XML comment (`--` may never appear in a comment body) — `flutter analyze` doesn't parse the manifest at all, so this was invisible until an actual `flutter build apk --debug` failed at Gradle's `processDebugMainManifest` step with a `SAXParseException`. Re-ran the build after fixing the comment; verified the merged output manifest (`build/app/intermediates/packaged_manifests/debug/processDebugManifestForPackage/AndroidManifest.xml`) actually contains all three entries post-merge, not just the source file.

No regression test: `Gal.hasAccess`/`requestAccess` are real platform-channel calls (same limitation as `ForegroundServiceLease`/`CallController` earlier in this session) and the manifest change has no Dart-level surface to test at all. Verified by direct build + merged-manifest inspection instead of a unit test.

`flutter analyze` clean, `flutter test` 163/163 (unchanged — nothing here has Dart-testable surface), `flutter build apk --debug` succeeds and the merged manifest was inspected directly.

---

### ⬜ Other confirmed findings (lower priority than the 8 above, not started)

- `onDone` typed `void Function()` but chat passes an async callback — foreground service can stop before reconciliation/TTS/notification/auto-continue actually finish. Also: pending-token buffer is cleared before the final GET, so a failed final GET silently drops the last unflushed token batch with no error shown.
- `chat_screen.dart` `initState` → `_initVoice()` requests mic + Bluetooth permissions immediately on opening any chat, not gated on an explicit Mic/Call tap.
- Media cache: 30-day trust window can serve a stale image if ComfyUI reuses a filename after a counter reset; the offline stale-fallback only covers non-2xx responses, not thrown network exceptions (so offline mode can reject an available cached file it should be serving).
- `lib/main.dart:566-625` — clearing a dashboard-port override validates against the *old* override value instead of the default, then persists null and switches to an untested port.
- `lib/main.dart:204-263` — a slow last-session lookup on startup can navigate late, after the user already manually picked a different connection/session (the `mounted` check doesn't prevent this because the Home route is still mounted underneath).
- Voice config inconsistencies: Chatterbox reads its STT locale from the *XTTS* language setting; call mode doesn't use per-character voice at all (already known — explicitly out of scope when I built per-character voice this session); a removed server voice is only cleared from the dropdown UI, not the persisted preference, so runtime requests keep using the stale/removed voice name.
- `session_list_screen.dart:149-168,439-449` — returning from a chat doesn't refetch, so a newly created session or updated preview/count doesn't show until manual pull-to-refresh.
- `connection_manager.dart:269-286`, `main.dart:835-840` — DNS failure, timeout, 500, and unsupported-endpoint are all presented identically as "invalid API key."
- `lib/core/models/connection.dart:53-55,88-123` — IPv6 host normalization strips brackets, so `baseUrl` emits `http://::1:8642` instead of the valid `http://[::1]:8642`.
- Security: API keys and dashboard passwords serialized to plain `SharedPreferences` (`connection.dart:125-149`) — not Keystore-backed. `AndroidManifest.xml:20-22` globally permits cleartext traffic, matching the Gateway/TTS HTTP-by-default design (LAN-only tool, but worth a conscious call on whether that's still the right default).

### ⬜ Performance (not started)

- **Confirmed + measured:** `onDone` always calls `_pollForLateMedia()` on a text-only turn until the SSE-filename capability has been learned once — 4 wasted full-transcript GETs (~427KB measured on a 502-message transcript) even though no media tool ran that turn. Fix direction per audit: track whether *this specific turn* actually emitted a media-tool completion without a filename; only poll in that state, not unconditionally pre-capability-discovery.
- **Measured, architectural:** 500-message transcript costs ~86MB PSS over empty state, scroll median 16.5ms/p95 36.8ms (39/114 frames over 25ms budget). Root cause is client-side full download + full `jsonDecode` of the whole session on the main isolate (`connection_manager.dart:172-194`) — virtualized rendering doesn't help transfer/decode cost. Real fix is server pagination/windowing + isolate decoding, which is a bigger architecture change, not a quick patch — worth a separate scoping conversation before starting.
- **Unmeasured, flagged for follow-up benchmarking:** quadratic `removeAt(0)` in tool-message grouping on tool-heavy turns; full-transcript lowercase+scan on every search keystroke; unbounded media response buffering (no app-level size ceiling); attachment previews decoded without target dimensions.

### Recommended addons (new features per the audit — separate track from bug fixes, not started, don't conflate with the "fix" list)

Connection diagnostics screen, durable send/resume protocol (request IDs + backend streaming idempotency), paginated/server-backed transcript search, Android Keystore-backed credential storage, media cache management UI (size/clear/revalidate), a real-device (not just emulator) pipeline test suite across API 24/29/35.

---

## How to resume

1. `cd C:\Users\charl\Documents\GitHub\hermes-android && git status --short` — confirm what's already changed matches the "Fixed" section above.
2. `flutter analyze && flutter test` — confirm baseline is still green (163+ passing) before touching anything new.
3. All 8 high-severity findings from the audit are now fixed. If continuing, pick up in the "Other confirmed findings" section (9 items, not yet started), then "Performance," then "Recommended addons" if the user wants new features rather than more fixes.
4. For each new item tackled: `flutter analyze`, `flutter test`, add a regression test for the specific behavior where the code has Dart-testable surface (several of the fixes above hit real platform-channel limits — see their write-ups for what "verified by direct reasoning instead" means in this repo), update this file's Status section (move the item to ✅ with a one-paragraph summary matching the style above), then move to the next.
5. Rebuild + reinstall the APK periodically (`flutter build apk --debug`, copy to `C:\Users\charl\Desktop\hermes-android-app-debug.apk`) so there's always a current build available, same pattern as the rest of this session.
6. None of this is on-device verified (no phone was connected for any of this session) — flag that honestly when reporting progress, don't imply device testing happened.
