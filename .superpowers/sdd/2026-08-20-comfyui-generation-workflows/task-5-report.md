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
