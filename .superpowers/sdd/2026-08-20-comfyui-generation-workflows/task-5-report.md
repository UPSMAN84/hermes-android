# Task 5 Streamed, Bounded Media Cache and Export Report

## Outcome

Implemented streamed, bounded media download/cache/export behavior with deterministic cleanup, rollback, retry, and UI lifecycle safety.

## RED/GREEN

- RED 1: new `test/media_cache_service_test.dart` initially failed to compile because `MediaDownloadPort`, `MediaCachePort`, `DefaultMediaDownloadService`, injected `MediaCacheService`/`MediaExportService` APIs did not exist.
- RED 2: `C:\src\flutter\bin\flutter.bat test test\media_gallery_screen_test.dart test\chat_screen_test.dart` exited 1: `CachedMediaThumbnail` and `ChatScreen` missing `mediaCache` named parameters.
- GREEN: service-focused tests 17/17.
- GREEN: combined focused `flutter test test\media_cache_service_test.dart test\media_gallery_screen_test.dart test\chat_screen_test.dart` 42/42.
- GREEN: touched analyzer command over the 7 files: no issues.
- GREEN: final full `flutter test`: 257 passed, 1 skipped due Windows symlink privilege.

## Concurrency interleavings

- Same URI: first future inserted, second reuses it, yielding one send.
- Different URL keys remain independent.
- Identity-guarded `whenComplete` removes only its own success/failure future; retry sends anew.
- Each operation uses a unique `.part`; body error/limit cleans it up.
- `.old` rollback preserves the complete record through promotion.
- Rejected headers never subscribe to the body.
- Video opens from its remote URL and never touches the image cache.
- Async UI uses mounted/epoch guards and `FutureBuilder` to avoid post-dispose mutation.

## Tests

Deterministic fixtures cover non-2xx, declared-over, missing/lying length, content type/headers-before-body, stale complete fallback, zero-byte rejection, video no-auto-cache, accept/decline export, counted hard limit, and stream cleanup.

## Files

- `lib/core/services/media_cache_service.dart`
- `lib/core/services/media_export_service.dart`
- `lib/core/widgets/cached_media_thumbnail.dart`
- `lib/core/screens/chat_screen.dart`
- `test/media_cache_service_test.dart`
- `test/media_gallery_screen_test.dart`
- `test/chat_screen_test.dart`
- `.superpowers/sdd/2026-08-20-comfyui-generation-workflows/task-5-report.md`

## Concerns

- Repository tests/analyzer only; no live gateway/device or actual huge transfer.
- Windows test logged missing `libmpv` and exercised graceful video-unavailable fallback.
- Task 8 may replace app-default composition; optional injections preserve migration.
- Full suite had one environment skip.

# Review round 1 (2026-08-20)

## RED/GREEN

- RED focused run exited 1: missing `MediaFileOperations`, `fileOperations`, and `close`; 2 GiB default; gallery `mediaCache`; and chat's injected gallery path.
- Intermediate: 51 passed, 2 fixture failures. The old async generator counted subscription, and Windows popup paint was flaky.
- GREEN focused run: 53/53 passed.
- Touched Dart analyzer: seven files, no issues.
- Final full `flutter test`: 268 passed, 1 skipped for Windows symlink privilege.
- Supersedes the earlier statement: pre-body rejects now subscribe then immediately cancel exactly once, with zero accepted or delivered chunks in cancellable fixtures.

## Concurrency interleavings

- Cache miss future completes before deferred scan.
- Concurrent different-URI completions use one serialized/coalesced scan.
- `close`/drain waits for outstanding work.
- Same-URI coalescing and video remote behavior are unchanged.
- Chat passes the injected cache through gallery thumbnails.

## Tests

- Hard cap defaults to 2 GiB, above the confirmed 512 MiB requirement.
- Declared-over, missing-length, and lying-length responses enforce the cap.
- Failed `.part`/`.old` cleanup is retried; undeletable artifacts are counted.
- Actual promotion rollback preserves prior bytes.
- Popup regression invokes the rendered `PopupMenuButton.onSelected`; Windows hit-test animation was nondeterministic.

## Files

- `lib/core/services/media_cache_service.dart`
- `lib/core/services/media_export_service.dart`
- `lib/core/screens/media_gallery_screen.dart`
- `lib/core/screens/chat_screen.dart`
- `test/media_cache_service_test.dart`
- `test/media_gallery_screen_test.dart`
- `test/chat_screen_test.dart`
- `.superpowers/sdd/2026-08-20-comfyui-generation-workflows/task-5-report.md`

## Concerns

- Repository-only verification; no live gateway/device or real multi-GiB transfer.
- Missing `libmpv` log remains graceful.
- Popup regression uses direct rendered callback because Windows hit-test animation was nondeterministic.
- One symlink privilege skip.

# Review round 2 (2026-08-20)

## RED/GREEN

- RED 1: focused media test first failed to compile because export cleanup had no lifecycle drain/close seam.
- RED 2 after the cleanup seam: 27 passed and exactly 2 intended regressions failed—the paused maintenance scan deleted freshly promoted bytes, and repeated complete hits increased scan count from 1 to 2.
- GREEN focused media: 29/29 passed.
- GREEN focused gallery/chat: 27/27 passed.
- Touched Dart analyzer: three files, no issues.
- Final full Flutter test: 271 passed, 1 skipped for Windows symlink privilege.

## Concurrency interleavings

- Maintenance snapshots canonical stat plus a per-path generation under the same FIFO gate used by default-service promotion.
- In the deterministic overlap, scan snapshots old metadata, refresh promotes fresh bytes and advances the generation, then resumed eviction revalidates under the gate, skips the stale target, and evicts the unchanged pressure file.
- Network/body streaming stays outside the gate, so different-URI downloads remain independent; only canonical promotion, rollback/restore, removal, and capacity deletion serialize.
- Changed snapshots request one fresh maintenance pass; delete failures do not self-spin.
- Fresh complete hits do not schedule maintenance. Download success/failure schedules deferred coalesced maintenance, while close remains an explicit drain.
- Export partial cleanup is owned by the default downloader, coalesced by one drain future, and retried through MediaExportService.close.

## Tests

- Added a paused-list deterministic stale-snapshot regression proving fresh bytes survive and capacity remains bounded.
- Added a repeated-hit scan counter proving ordinary cache hits perform no full list/sort.
- Added injected first-delete failure coverage proving export close retries and leaves no .part file.
- Existing same-URI coalescing, different-URI independence, 2 GiB cap, rollback, video stream-first, gallery injection, and disposal guards remain green.

## Files

- lib/core/services/media_cache_service.dart
- lib/core/services/media_export_service.dart
- test/media_cache_service_test.dart
- .superpowers/sdd/2026-08-20-comfyui-generation-workflows/task-5-report.md

## Concerns

- Repository-only verification; no live gateway/device or real multi-GiB transfer.
- Missing libmpv remains a graceful Windows test log.
- Full suite retained the expected Windows symlink privilege skip.

# Review round 3 (2026-08-20)

## RED/GREEN

- RED focused media: 29 passed and exactly 3 intended regressions failed. A second same-root cache with an injected identical-metadata replacement lost the fresh canonical file; close finished before a late stream/delete failure registered cleanup; and a new export was admitted after close began.
- GREEN focused media: 32/32 passed.
- GREEN focused gallery/chat: 27/27 passed.
- Touched Dart analyzer: three files, no issues.
- Final full Flutter test: 274 passed, 1 skipped for Windows symlink privilege.

## Concurrency interleavings

- Same-root cache instances acquire one normalized-root MediaCacheMutationCoordinator from a weak registry; callers may explicitly inject a coordinator.
- Every cache downloader now receives a unique registered staging path. HTTP and body streaming remain independent and outside the FIFO coordinator.
- Cache-owned promotion, rollback, removal, recovery, snapshot, and eviction are serialized by the root coordinator regardless of the injected downloader.
- The deterministic overlap snapshots old generation/stat, promotes equal-size/equal-mtime fresh bytes through a second cache, then revalidation observes the generation change, preserves fresh target bytes, and evicts pressure.
- Registered staging paths and nested downloader partials are protected from maintenance in other cache instances.
- Export close sets admission closed synchronously, awaits an identity-tracked stable set of active share/save futures, then performs at most three cleanup passes. Persistent cleanup failure surfaces instead of spinning.

## Tests

- Added two-cache-instance injected-downloader overlap coverage with identical size and mtime.
- Added close-before-body-failure coverage proving close waits, retries the late partial deletion, and leaves no temp.
- Added shutdown-admission coverage proving a second export is rejected and no second HTTP send occurs.
- Existing coalescing, independent URI streaming, rollback, bounds, video stream-first, gallery injection, and disposal tests remain green.

## Files

- lib/core/services/media_cache_service.dart
- lib/core/services/media_export_service.dart
- test/media_cache_service_test.dart
- .superpowers/sdd/2026-08-20-comfyui-generation-workflows/task-5-report.md

## Concerns

- Repository-only verification; no live gateway/device or real multi-GiB transfer.
- Missing libmpv remains a graceful Windows test log.
- Full suite retained the expected Windows symlink privilege skip.

# Review round 4 (2026-08-20)

## RED/GREEN

- RED 1 focused media: 20 passed before the deterministic dot-dot/trailing root-alias overlap failed because maintenance deleted another cache instance's live staging file. The symlink variant capability-skipped on Windows privilege error 1314.
- GREEN 1 focused media: 33/33 passed, with the symlink capability skip.
- RED 2 focused media: 25 passed before the shared-downloader overlap failed because closing export service A drained export service B's pending partial.
- RED/GREEN confinement mutation: disabling produced-file confinement made the targeted outside-root adoption test fail; restoring confinement passed 1/1.
- Final focused media: 35/35 passed, with one symlink capability skip.
- Combined cache/gallery/chat: 62/62 passed, with one symlink capability skip.
- Touched Dart analyzer: three files, no issues.
- Final full Flutter test: 277 passed, 2 skipped because Windows could not create symlinks.

## Concurrency interleavings

- Every cache root is created, resolved through filesystem aliases, normalized, and case-folded on Windows/macOS before the weak coordinator registry is consulted.
- App-default and injected-root cache instances now acquire their coordinator from that registry; the cache-owned default downloader is created only after root resolution and receives the registered coordinator.
- Canonical, staging, nested partial, rollback, generation, and maintenance identities normalize consistently. Produced files are root-confined before promotion.
- Dot-dot/trailing and case aliases share one coordinator. The deterministic paused download stays registered while maintenance lists the same physical root through another spelling.
- Each cache/export service passes its own additive cleanup scope to ownership-aware downloaders. Legacy MediaDownloadPort implementations and callers keep the unchanged download signature.
- Export close still closes admission synchronously and awaits its stable active set, but drains only its own failed partial/destination cleanup. Another service sharing the downloader keeps its pending partial until its own close.

## Tests

- Added dot-dot/trailing and case alias overlap coverage.
- Added capability-gated real-symlink alias overlap coverage.
- Added outside-root injected-download rejection and preservation coverage.
- Added two-export-service shared-downloader overlap coverage proving the late export partial is removed and the other owner's partial is not drained early.

## Files

- lib/core/services/media_cache_service.dart
- lib/core/services/media_export_service.dart
- test/media_cache_service_test.dart
- .superpowers/sdd/2026-08-20-comfyui-generation-workflows/task-5-report.md

## Concerns

- Repository-only verification; no live gateway/device or real multi-GiB transfer.
- The two full-suite skips are capability-gated symlink tests on Windows privilege error 1314.
- Missing libmpv remains a graceful Windows test log.

# Review round 5 (2026-08-20)

## RED/GREEN

- RED 1 focused media failed to compile because owned legacy cleanup had no explicit `ownsDownloadService` lifecycle contract.
- RED 2 targeted confinement ran through a real Windows directory junction and failed because the injected `<root>/escape/outside.png` was promoted into the cache instead of being rejected.
- GREEN targeted symlink/junction escape: 1/1 passed and outside bytes remained unchanged.
- GREEN focused media: 38/38 passed, with the pre-existing root-alias symlink capability skip.
- GREEN combined cache/gallery/chat: 65/65 passed, with the same capability skip.
- Final full Flutter test: 280 passed, 2 capability skips.
- Final full Flutter analyzer: no issues.

## Confinement and lifecycle

- Existing produced/staging paths and their nearest existing ancestors resolve against the canonical real cache root before confinement.
- Promotion re-resolves source and destination inside the root mutation coordinator before equality or rename.
- A rejected injected symlink-parent path is never promoted or deleted; only a final link at the cache-owned staging entry may be unlinked without following its target.
- Ownership-aware downloaders retain per-export cleanup scopes.
- A legacy `MediaDownloadPort + MediaDownloadCleanupPort` is accepted only with explicit exclusive ownership; close waits for active export failure, then drains that service-local legacy cleanup.
- Cleanup-global legacy downloaders without explicit ownership fail construction with a clear compatibility error instead of silently leaking.

## Tests

- Added a real symlink/junction-parent escape regression using an injected returned file; the outside file remains byte-for-byte unchanged.
- Added active-export legacy cleanup coverage proving `close` drains a late registered partial.
- Added construction rejection coverage for unsupported shared legacy cleanup.

## Files

- `lib/core/services/media_cache_service.dart`
- `lib/core/services/media_export_service.dart`
- `test/media_cache_service_test.dart`
- `.superpowers/sdd/2026-08-20-comfyui-generation-workflows/task-5-report.md`

## Concerns

- Repository-only verification; no live gateway/device or real multi-GiB transfer.
- Full-suite skips remain capability-gated symlink tests for the older media-root alias and workflow-store cases.
- Missing `libmpv` remains a graceful Windows test log.
