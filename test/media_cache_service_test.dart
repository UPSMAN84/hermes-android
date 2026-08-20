import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/media_cache_service.dart';
import 'package:hermes_android/core/services/media_export_service.dart';
import 'package:http/http.dart' as http;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hermes-media-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('DefaultMediaDownloadService', () {
    test(
      'streams a response and exposes its headers before body chunks',
      () async {
        var chunksRead = 0;
        final client = _FixtureClient(
          (_) => _response(
            chunks: [
              Uint8List.fromList([1, 2]),
              Uint8List.fromList([3]),
            ],
            declaredLength: 3,
            headers: const {'content-type': 'image/png'},
            onChunk: () => chunksRead++,
          ),
        );
        final destination = File(
          '${temp.path}${Platform.pathSeparator}image.png',
        );

        MediaDownloadInfo? confirmed;
        final file = await DefaultMediaDownloadService(httpClient: client)
            .download(
              Uri.parse('http://host/view?filename=image.png'),
              destination: destination,
              maxBytes: 6,
              headers: const {'Authorization': 'Bearer secret'},
              confirmAfterHeaders: (info) async {
                expect(chunksRead, 0);
                confirmed = info;
                return true;
              },
            );

        expect(await file.readAsBytes(), [1, 2, 3]);
        expect(confirmed?.statusCode, 200);
        expect(confirmed?.contentType, 'image/png');
        expect(confirmed?.declaredBytes, 3);
        expect(
          client.requests.single.headers['authorization'],
          'Bearer secret',
        );
        expect(_partFiles(temp), isEmpty);
      },
    );

    test('rejects non-2xx without publishing a destination', () async {
      final body = _CancellableResponseBody([
        Uint8List.fromList([1, 2, 3]),
      ]);
      final client = _FixtureClient((_) => http.StreamedResponse(body, 404));
      final destination = File(
        '${temp.path}${Platform.pathSeparator}missing.png',
      );

      await expectLater(
        DefaultMediaDownloadService(httpClient: client).download(
          Uri.parse('http://host/missing.png'),
          destination: destination,
          maxBytes: 6,
        ),
        throwsA(isA<MediaDownloadHttpException>()),
      );

      expect(body.listenCount, 1);
      expect(body.cancelCount, 1);
      expect(body.acceptedChunks, isEmpty);
      expect(body.deliveredChunks, isEmpty);
      expect(await destination.exists(), isFalse);
      expect(_files(temp), isEmpty);
    });

    test('rejects a declared over-limit response before body chunks', () async {
      final body = _CancellableResponseBody([Uint8List(1)]);
      final client = _FixtureClient(
        (_) => http.StreamedResponse(body, 200, contentLength: 7),
      );
      final destination = File(
        '${temp.path}${Platform.pathSeparator}large.png',
      );

      await expectLater(
        DefaultMediaDownloadService(httpClient: client).download(
          Uri.parse('http://host/large.png'),
          destination: destination,
          maxBytes: 6,
        ),
        throwsA(isA<MediaDownloadLimitException>()),
      );

      expect(body.listenCount, 1);
      expect(body.cancelCount, 1);
      expect(body.acceptedChunks, isEmpty);
      expect(body.deliveredChunks, isEmpty);
      expect(await destination.exists(), isFalse);
      expect(_files(temp), isEmpty);
    });

    test('counts a missing content-length response', () async {
      final client = _FixtureClient(
        (_) => _response(chunks: [Uint8List(4), Uint8List(4)]),
      );
      final destination = File(
        '${temp.path}${Platform.pathSeparator}unknown.png',
      );

      await expectLater(
        DefaultMediaDownloadService(httpClient: client).download(
          Uri.parse('http://host/unknown.png'),
          destination: destination,
          maxBytes: 6,
        ),
        throwsA(isA<MediaDownloadLimitException>()),
      );

      expect(await destination.exists(), isFalse);
      expect(_partFiles(temp), isEmpty);
    });

    test('aborts a lying content-length response at the byte limit', () async {
      final client = _FixtureClient(
        (_) =>
            _response(declaredLength: 3, chunks: [Uint8List(4), Uint8List(4)]),
      );
      final destination = File(
        '${temp.path}${Platform.pathSeparator}lying.png',
      );

      await expectLater(
        DefaultMediaDownloadService(httpClient: client).download(
          Uri.parse('http://host/view?filename=lying.png'),
          destination: destination,
          maxBytes: 6,
        ),
        throwsA(isA<MediaDownloadLimitException>()),
      );

      expect(await destination.exists(), isFalse);
      expect(_partFiles(temp), isEmpty);
    });

    test(
      'declined confirmation reads no chunks and cleans the partial',
      () async {
        final body = _CancellableResponseBody([
          Uint8List.fromList([1, 2, 3]),
        ]);
        final client = _FixtureClient((_) => http.StreamedResponse(body, 200));
        final destination = File(
          '${temp.path}${Platform.pathSeparator}declined.png',
        );

        await expectLater(
          DefaultMediaDownloadService(httpClient: client).download(
            Uri.parse('http://host/declined.png'),
            destination: destination,
            maxBytes: 6,
            confirmAfterHeaders: (_) async => false,
          ),
          throwsA(isA<MediaDownloadDeclinedException>()),
        );

        expect(body.listenCount, 1);
        expect(body.cancelCount, 1);
        expect(body.acceptedChunks, isEmpty);
        expect(body.deliveredChunks, isEmpty);
        expect(await destination.exists(), isFalse);
        expect(_files(temp), isEmpty);
      },
    );

    test(
      'restores an existing destination when publishing the partial fails',
      () async {
        final destination = File(
          '${temp.path}${Platform.pathSeparator}existing.png',
        );
        await destination.writeAsBytes([1, 2, 3]);
        final operations = _FaultInjectingFileOperations(
          failRename: (file, newPath) =>
              file.path.endsWith('.part') && newPath == destination.path,
        );
        final client = _FixtureClient(
          (_) => _response(
            chunks: [
              Uint8List.fromList([9, 8, 7]),
            ],
          ),
        );

        await expectLater(
          DefaultMediaDownloadService(
            httpClient: client,
            fileOperations: operations,
          ).download(
            Uri.parse('http://host/replacement.png'),
            destination: destination,
            maxBytes: 6,
          ),
          throwsA(isA<StateError>()),
        );

        expect(await destination.readAsBytes(), [1, 2, 3]);
        expect(_partFiles(temp), isEmpty);
        expect(_oldFiles(temp), isEmpty);
      },
    );

    test(
      'stream errors delete the unique partial and keep no destination',
      () async {
        final client = _FixtureClient(
          (_) => http.StreamedResponse(
            Stream<List<int>>.multi((controller) {
              controller.add([1, 2, 3]);
              controller.addError(StateError('socket cancelled'));
              controller.close();
            }),
            200,
          ),
        );
        final destination = File(
          '${temp.path}${Platform.pathSeparator}cancelled.png',
        );

        await expectLater(
          DefaultMediaDownloadService(httpClient: client).download(
            Uri.parse('http://host/cancelled.png'),
            destination: destination,
            maxBytes: 6,
          ),
          throwsA(isA<StateError>()),
        );

        expect(await destination.exists(), isFalse);
        expect(_partFiles(temp), isEmpty);
      },
    );
  });

  group('MediaCacheService', () {
    test('coalesces concurrent downloads for the same URI', () async {
      final release = Completer<void>();
      final client = _FixtureClient(
        (_) => _response(
          chunks: [
            Uint8List.fromList([1, 2, 3]),
          ],
          beforeChunks: release.future,
        ),
      );
      final cache = MediaCacheService(root: temp, httpClient: client);
      final uri = Uri.parse('http://host/view?filename=a.png');

      final first = cache.cache(uri);
      final second = cache.cache(uri);
      await _waitUntil(() => client.sendCount == 1);
      expect(client.sendCount, 1);
      release.complete();

      final files = await Future.wait([first, second]);
      expect(identical(files[0], files[1]), isTrue);
      expect(client.sendCount, 1);
    });

    test('different URIs download independently', () async {
      final releases = <String, Completer<void>>{};
      final client = _FixtureClient((request) {
        final release = releases.putIfAbsent(
          request.url.toString(),
          Completer<void>.new,
        );
        return _response(
          chunks: [
            Uint8List.fromList([request.url.toString().length]),
          ],
          beforeChunks: release.future,
        );
      });
      final cache = MediaCacheService(root: temp, httpClient: client);
      final firstUri = Uri.parse('http://host/view?filename=a.png');
      final secondUri = Uri.parse('http://host/view?filename=b.png');

      final first = cache.cache(firstUri);
      final second = cache.cache(secondUri);
      await _waitUntil(() => client.sendCount == 2);
      expect(client.sendCount, 2);
      releases[firstUri.toString()]!.complete();
      releases[secondUri.toString()]!.complete();

      expect(await Future.wait([first, second]), everyElement(isA<File>()));
    });

    test(
      'failed coalesced futures are evicted and a retry sends once',
      () async {
        var fail = true;
        final release = Completer<void>();
        final client = _FixtureClient((_) {
          if (fail) {
            return _response(
              statusCode: 503,
              chunks: const [],
              beforeChunks: release.future,
            );
          }
          return _response(
            chunks: [
              Uint8List.fromList([9]),
            ],
          );
        });
        final cache = MediaCacheService(root: temp, httpClient: client);
        final uri = Uri.parse('http://host/view?filename=retry.png');

        final first = cache.cache(uri);
        final coalesced = cache.cache(uri);
        release.complete();
        await expectLater(first, throwsA(isA<MediaDownloadHttpException>()));
        await expectLater(
          coalesced,
          throwsA(isA<MediaDownloadHttpException>()),
        );
        expect(client.sendCount, 1);

        fail = false;
        final retried = await cache.cache(uri);
        expect(await retried!.readAsBytes(), [9]);
        expect(client.sendCount, 2);
      },
    );

    test('falls back to an already complete stale cache record', () async {
      final responses = Queue<http.StreamedResponse>.of([
        _response(
          chunks: [
            Uint8List.fromList([4, 5, 6]),
          ],
        ),
        _response(statusCode: 503, chunks: const []),
      ]);
      final client = _FixtureClient((_) => responses.removeFirst());
      final cache = MediaCacheService(
        root: temp,
        httpClient: client,
        maxAge: const Duration(seconds: 1),
      );
      final uri = Uri.parse('http://host/view?filename=stale.png');
      final first = await cache.cache(uri);
      await first!.setLastModified(
        DateTime.now().subtract(const Duration(days: 1)),
      );

      final fallback = await cache.cache(uri);

      expect(fallback!.path, first.path);
      expect(await fallback.readAsBytes(), [4, 5, 6]);
      expect(client.sendCount, 2);
    });

    test(
      'does not treat a zero-byte cache record as a stale fallback',
      () async {
        final responses = Queue<http.StreamedResponse>.of([
          _response(
            chunks: [
              Uint8List.fromList([4]),
            ],
          ),
          _response(statusCode: 503, chunks: const []),
        ]);
        final client = _FixtureClient((_) => responses.removeFirst());
        final cache = MediaCacheService(
          root: temp,
          httpClient: client,
          maxAge: Duration.zero,
        );
        final uri = Uri.parse('http://host/view?filename=partial.png');
        final first = await cache.cache(uri);
        await first!.writeAsBytes(const []);

        await expectLater(
          cache.cache(uri),
          throwsA(isA<MediaDownloadHttpException>()),
        );
      },
    );

    test(
      'known generated videos remain remote and are not auto-cached',
      () async {
        final client = _FixtureClient((_) => _response(chunks: [Uint8List(1)]));
        final cache = MediaCacheService(root: temp, httpClient: client);

        final file = await cache.cache(
          Uri.parse('http://host/view?filename=clip.mp4&type=output'),
        );

        expect(file, isNull);
        expect(client.sendCount, 0);
        expect(_files(temp), isEmpty);
      },
    );

    test(
      'retries cleanup of a partial left by a stream error on close',
      () async {
        var failedOnce = false;
        final operations = _FaultInjectingFileOperations(
          failDelete: (file) {
            if (!failedOnce && file.path.endsWith('.part')) {
              failedOnce = true;
              return true;
            }
            return false;
          },
        );
        final client = _FixtureClient(
          (_) => http.StreamedResponse(
            Stream<List<int>>.multi((controller) {
              controller.add([1, 2]);
              controller.addError(StateError('stream failed'));
              controller.close();
            }),
            200,
          ),
        );
        final cache = MediaCacheService(
          root: temp,
          httpClient: client,
          fileOperations: operations,
        );

        await expectLater(
          cache.cache(Uri.parse('http://host/view?filename=broken.png')),
          throwsA(isA<StateError>()),
        );
        await cache.close();

        expect(
          operations.deleteAttempts
              .where((path) => path.endsWith('.part'))
              .length,
          2,
        );
        expect(_partFiles(temp), isEmpty);
      },
    );

    test('retries stale replacement old-file cleanup on close', () async {
      var failedOnce = false;
      final operations = _FaultInjectingFileOperations(
        failDelete: (file) {
          if (!failedOnce && file.path.endsWith('.old')) {
            failedOnce = true;
            return true;
          }
          return false;
        },
      );
      final responses = Queue<http.StreamedResponse>.of([
        _response(
          chunks: [
            Uint8List.fromList([1, 2, 3]),
          ],
        ),
        _response(
          chunks: [
            Uint8List.fromList([7, 8, 9]),
          ],
        ),
      ]);
      final cache = MediaCacheService(
        root: temp,
        httpClient: _FixtureClient((_) => responses.removeFirst()),
        fileOperations: operations,
        maxAge: Duration.zero,
      );
      final uri = Uri.parse('http://host/view?filename=stale.png');

      await cache.cache(uri);
      final replacement = await cache.cache(uri);
      await cache.close();

      expect(await replacement!.readAsBytes(), [7, 8, 9]);
      expect(_oldFiles(temp), isEmpty);
      expect(
        operations.deleteAttempts.where((path) => path.endsWith('.old')).length,
        2,
      );
    });

    test(
      'counts an undeletable partial when enforcing cache capacity',
      () async {
        final operations = _FaultInjectingFileOperations(
          failDelete: (file) => file.path.endsWith('orphan.part'),
        );
        final responses = Queue<http.StreamedResponse>.of([
          _response(
            chunks: [
              Uint8List.fromList([1, 1, 1, 1]),
            ],
          ),
          _response(
            chunks: [
              Uint8List.fromList([2, 2, 2, 2]),
            ],
          ),
        ]);
        final cache = MediaCacheService(
          root: temp,
          httpClient: _FixtureClient((_) => responses.removeFirst()),
          fileOperations: operations,
          maxCacheBytes: 6,
        );
        final oldUri = Uri.parse('http://host/view?filename=old.png');
        final newUri = Uri.parse('http://host/view?filename=new.png');
        final old = await cache.cache(oldUri);
        await old!.setLastModified(DateTime(2000));
        await File(
          '${temp.path}${Platform.pathSeparator}orphan.part',
        ).writeAsBytes([3, 3]);

        final newest = await cache.cache(newUri);
        await cache.close();

        expect(await old.exists(), isFalse);
        expect(await newest!.readAsBytes(), [2, 2, 2, 2]);
        expect(await _totalBytes(temp), 6);
      },
    );

    test(
      'different downloads finish before one serialized capacity scan',
      () async {
        final listGate = Completer<void>();
        final operations = _FaultInjectingFileOperations(
          listGate: listGate.future,
        );
        final cache = MediaCacheService(
          root: temp,
          httpClient: _FixtureClient(
            (_) => _response(
              chunks: [
                Uint8List.fromList([1, 2, 3, 4]),
              ],
            ),
          ),
          fileOperations: operations,
          maxCacheBytes: 5,
        );
        var firstFinished = false;
        var secondFinished = false;
        final first = cache
            .cache(Uri.parse('http://host/view?filename=first.png'))
            .whenComplete(() => firstFinished = true);
        final second = cache
            .cache(Uri.parse('http://host/view?filename=second.png'))
            .whenComplete(() => secondFinished = true);

        try {
          await _waitUntil(() => firstFinished && secondFinished);
          expect(operations.listCount, 1);
        } finally {
          if (!listGate.isCompleted) listGate.complete();
          await Future.wait([first, second]);
          await cache.close();
        }

        expect(operations.listCount, 1);
        expect(_canonicalFiles(temp), hasLength(1));
        expect(await _totalBytes(temp), lessThanOrEqualTo(5));
      },
    );

    test(
      'refresh promoted during a paused scan survives stale eviction metadata',
      () async {
        final scanSnapshot = Completer<void>();
        final releaseScan = Completer<void>();
        final operations = _FaultInjectingFileOperations(
          afterListGate: releaseScan.future,
          afterListGateOnCount: 2,
          onListSnapshot: (_) => scanSnapshot.complete(),
        );
        final responses = Queue<http.StreamedResponse>.of([
          _response(
            chunks: [
              Uint8List.fromList([1, 1, 1, 1]),
            ],
          ),
          _response(
            chunks: [
              Uint8List.fromList([2, 2, 2, 2]),
            ],
          ),
        ]);
        final cache = MediaCacheService(
          root: temp,
          httpClient: _FixtureClient((_) => responses.removeFirst()),
          fileOperations: operations,
          maxCacheBytes: 4,
          maxAge: Duration.zero,
        );
        final uri = Uri.parse('http://host/view?filename=target.png');
        final target = await cache.cache(uri);
        await cache.close();
        await target!.setLastModified(DateTime(1990));
        final pressure = File('${temp.path}${Platform.pathSeparator}pressure');
        await pressure.writeAsBytes([3, 3, 3, 3]);
        await pressure.setLastModified(DateTime(2000));

        final maintenance = cache.drainMaintenance();
        try {
          await scanSnapshot.future;
          final refreshed = await cache.cache(uri);
          expect(await refreshed!.readAsBytes(), [2, 2, 2, 2]);
        } finally {
          if (!releaseScan.isCompleted) releaseScan.complete();
        }
        await maintenance;
        await cache.close();

        expect(await target.exists(), isTrue);
        expect(await target.readAsBytes(), [2, 2, 2, 2]);
        expect(await pressure.exists(), isFalse);
      },
    );

    test(
      'two cache instances coordinate injected same-metadata promotion',
      () async {
        final scanSnapshot = Completer<void>();
        final releaseScan = Completer<void>();
        final operations = _FaultInjectingFileOperations(
          afterListGate: releaseScan.future,
          afterListGateOnCount: 2,
          onListSnapshot: (_) => scanSnapshot.complete(),
        );
        final cache1 = MediaCacheService(
          root: temp,
          httpClient: _FixtureClient(
            (_) => _response(
              chunks: [
                Uint8List.fromList([1, 1, 1, 1]),
              ],
            ),
          ),
          fileOperations: operations,
          maxCacheBytes: 4,
          maxAge: Duration.zero,
        );
        final cache2 = MediaCacheService(
          root: temp,
          downloadService: _InjectedDownloadService(
            bytes: const [2, 2, 2, 2],
            modified: DateTime(1990),
          ),
          fileOperations: operations,
          maxCacheBytes: 512 * 1024 * 1024,
          maxAge: Duration.zero,
        );
        final uri = Uri.parse('http://host/view?filename=target.png');
        final target = await cache1.cache(uri);
        await cache1.drainMaintenance();
        await target!.setLastModified(DateTime(1990));
        final pressure = File('${temp.path}${Platform.pathSeparator}pressure');
        await pressure.writeAsBytes([3, 3, 3, 3]);
        await pressure.setLastModified(DateTime(2000));

        final maintenance = cache1.drainMaintenance();
        try {
          await scanSnapshot.future;
          final refreshed = await cache2.cache(uri);
          expect(await refreshed!.readAsBytes(), [2, 2, 2, 2]);
          expect(await refreshed.lastModified(), DateTime(1990));
        } finally {
          if (!releaseScan.isCompleted) releaseScan.complete();
        }
        await maintenance;
        await Future.wait([
          cache1.drainMaintenance(),
          cache2.drainMaintenance(),
        ]);

        expect(await target.exists(), isTrue);
        expect(await target.readAsBytes(), [2, 2, 2, 2]);
        expect(await pressure.exists(), isFalse);
      },
    );

    test(
      'repeated complete cache hits do not schedule maintenance scans',
      () async {
        final operations = _FaultInjectingFileOperations();
        final cache = MediaCacheService(
          root: temp,
          httpClient: _FixtureClient(
            (_) => _response(
              chunks: [
                Uint8List.fromList([1, 2, 3, 4]),
              ],
            ),
          ),
          fileOperations: operations,
        );
        final uri = Uri.parse('http://host/view?filename=hit.png');
        await cache.cache(uri);
        await cache.close();
        final listCount = operations.listCount;

        await cache.cache(uri);
        await cache.cache(uri);
        await cache.cache(uri);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(operations.listCount, listCount);
        await cache.close();
      },
    );
  });

  group('MediaExportService remote downloads', () {
    test(
      'accepts unknown size before chunks and shares the counted file',
      () async {
        var chunksRead = 0;
        var confirmations = 0;
        List<int>? sharedBytes;
        final client = _FixtureClient(
          (_) => _response(
            chunks: [
              Uint8List.fromList([1, 2]),
              Uint8List.fromList([3]),
            ],
            headers: const {'content-type': 'video/mp4'},
            onChunk: () => chunksRead++,
          ),
        );
        final service = MediaExportService(
          root: temp,
          downloadService: DefaultMediaDownloadService(httpClient: client),
          shareFile: (file) async => sharedBytes = await file.readAsBytes(),
        );

        await service.shareRemote(
          Uri.parse('http://host/view?filename=clip.mp4'),
          confirmAfterHeaders: (info) async {
            confirmations++;
            expect(info.declaredBytes, isNull);
            expect(info.contentType, 'video/mp4');
            expect(chunksRead, 0);
            return true;
          },
        );

        expect(confirmations, 1);
        expect(sharedBytes, [1, 2, 3]);
        expect(_files(temp), isEmpty);
      },
    );

    test(
      'close retries a failed partial cleanup from an export download',
      () async {
        var failedOnce = false;
        final operations = _FaultInjectingFileOperations(
          failDelete: (file) {
            if (!failedOnce && file.path.endsWith('.part')) {
              failedOnce = true;
              return true;
            }
            return false;
          },
        );
        final client = _FixtureClient(
          (_) => http.StreamedResponse(
            Stream<List<int>>.multi((controller) {
              controller.add([1, 2]);
              controller.addError(StateError('stream failed'));
              controller.close();
            }),
            200,
          ),
        );
        final service = MediaExportService(
          root: temp,
          downloadService: DefaultMediaDownloadService(
            httpClient: client,
            fileOperations: operations,
          ),
          shareFile: (_) async {},
        );

        await expectLater(
          service.shareRemote(
            Uri.parse('http://host/view?filename=broken.png'),
            confirmAfterHeaders: (_) async => true,
          ),
          throwsA(isA<StateError>()),
        );
        expect(_partFiles(temp), hasLength(1));

        await service.close();

        expect(
          operations.deleteAttempts
              .where((path) => path.endsWith('.part'))
              .length,
          2,
        );
        expect(_files(temp), isEmpty);
      },
    );

    test(
      'close waits for active failure before draining late partial cleanup',
      () async {
        final release = Completer<void>();
        var failedOnce = false;
        final operations = _FaultInjectingFileOperations(
          failDelete: (file) {
            if (!failedOnce && file.path.endsWith('.part')) {
              failedOnce = true;
              return true;
            }
            return false;
          },
        );
        final client = _FixtureClient(
          (_) => http.StreamedResponse(
            (() async* {
              await release.future;
              yield [1, 2];
              throw StateError('stream failed');
            })(),
            200,
          ),
        );
        final service = MediaExportService(
          root: temp,
          downloadService: DefaultMediaDownloadService(
            httpClient: client,
            fileOperations: operations,
          ),
          shareFile: (_) async {},
        );
        final export = service.shareRemote(
          Uri.parse('http://host/view?filename=broken.png'),
          confirmAfterHeaders: (_) async => true,
        );
        await _waitUntil(() => client.sendCount == 1);
        final exportExpectation = expectLater(
          export,
          throwsA(isA<StateError>()),
        );
        var closeFinished = false;
        final close = service.close().whenComplete(() => closeFinished = true);

        await Future<void>.delayed(Duration.zero);
        final finishedBeforeFailure = closeFinished;
        release.complete();
        await exportExpectation;
        await close;

        expect(finishedBeforeFailure, isFalse);
        expect(
          operations.deleteAttempts
              .where((path) => path.endsWith('.part'))
              .length,
          2,
        );
        expect(_partFiles(temp), isEmpty);
      },
    );

    test('close rejects exports started after shutdown begins', () async {
      final release = Completer<void>();
      final firstUri = Uri.parse('http://host/view?filename=first.png');
      final client = _FixtureClient(
        (request) => _response(
          chunks: [
            Uint8List.fromList([1, 2]),
          ],
          beforeChunks: request.url == firstUri ? release.future : null,
        ),
      );
      final service = MediaExportService(
        root: temp,
        downloadService: DefaultMediaDownloadService(httpClient: client),
        shareFile: (_) async {},
      );
      final first = service.shareRemote(
        firstUri,
        confirmAfterHeaders: (_) async => true,
      );
      await _waitUntil(() => client.sendCount == 1);
      final close = service.close();

      try {
        await expectLater(
          service.shareRemote(
            Uri.parse('http://host/view?filename=second.png'),
            confirmAfterHeaders: (_) async => true,
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await first;
        await close;
      }

      expect(client.sendCount, 1);
    });

    test('declines an unknown-size save before reading chunks', () async {
      final body = _CancellableResponseBody([
        Uint8List.fromList([1, 2, 3]),
      ]);
      var saved = false;
      final client = _FixtureClient((_) => http.StreamedResponse(body, 200));
      final service = MediaExportService(
        root: temp,
        downloadService: DefaultMediaDownloadService(httpClient: client),
        saveFile: (file, {required isVideo}) async {
          saved = true;
          return null;
        },
      );

      await expectLater(
        service.saveRemote(
          Uri.parse('http://host/view?filename=image.png'),
          isVideo: false,
          confirmAfterHeaders: (_) async => false,
        ),
        throwsA(isA<MediaDownloadDeclinedException>()),
      );

      expect(body.listenCount, 1);
      expect(body.cancelCount, 1);
      expect(body.acceptedChunks, isEmpty);
      expect(body.deliveredChunks, isEmpty);
      expect(saved, isFalse);
      expect(_files(temp), isEmpty);
    });

    test(
      'asks for declared sizes over 512 MiB but not small known files',
      () async {
        final responses = Queue<http.StreamedResponse>.of([
          _response(declaredLength: 3, chunks: [Uint8List(3)]),
          _response(
            declaredLength: MediaExportService.confirmationBytes + 1,
            chunks: [Uint8List(1)],
          ),
        ]);
        final client = _FixtureClient((_) => responses.removeFirst());
        final service = MediaExportService(
          root: temp,
          downloadService: DefaultMediaDownloadService(httpClient: client),
          shareFile: (_) async {},
        );
        var confirmations = 0;

        await service.shareRemote(
          Uri.parse('http://host/view?filename=small.png'),
          confirmAfterHeaders: (_) async {
            confirmations++;
            return true;
          },
        );
        await service.shareRemote(
          Uri.parse('http://host/view?filename=large.mp4'),
          confirmAfterHeaders: (info) async {
            confirmations++;
            expect(
              info.declaredBytes,
              MediaExportService.confirmationBytes + 1,
            );
            return true;
          },
        );

        expect(confirmations, 1);
        expect(client.sendCount, 2);
      },
    );

    test(
      'accepted unknown-size exports still enforce the counted hard limit',
      () async {
        final client = _FixtureClient(
          (_) => _response(chunks: [Uint8List(4), Uint8List(4)]),
        );
        final service = MediaExportService(
          root: temp,
          downloadService: DefaultMediaDownloadService(httpClient: client),
          maxDownloadBytes: 6,
          shareFile: (_) async {},
        );

        await expectLater(
          service.shareRemote(
            Uri.parse('http://host/view?filename=lying.mp4'),
            confirmAfterHeaders: (_) async => true,
          ),
          throwsA(isA<MediaDownloadLimitException>()),
        );

        expect(_files(temp), isEmpty);
      },
    );

    test('defaults the public export hard cap to exactly 2 GiB', () {
      expect(
        MediaExportService.defaultMaxDownloadBytes,
        2 * 1024 * 1024 * 1024,
      );
    });

    test(
      'default hard cap rejects a declared cap plus one before share',
      () async {
        var shared = false;
        final body = _CancellableResponseBody([Uint8List(1)]);
        final client = _FixtureClient(
          (_) => http.StreamedResponse(
            body,
            200,
            contentLength: MediaExportService.defaultMaxDownloadBytes + 1,
          ),
        );
        final service = MediaExportService(
          root: temp,
          downloadService: DefaultMediaDownloadService(httpClient: client),
          shareFile: (_) async => shared = true,
        );

        await expectLater(
          service.shareRemote(Uri.parse('http://host/view?filename=huge.png')),
          throwsA(isA<MediaDownloadLimitException>()),
        );

        expect(body.listenCount, 1);
        expect(body.cancelCount, 1);
        expect(body.acceptedChunks, isEmpty);
        expect(body.deliveredChunks, isEmpty);
        expect(shared, isFalse);
        expect(_files(temp), isEmpty);
      },
    );

    test(
      'default hard cap rejects an undeclared huge chunk before share',
      () async {
        var shared = false;
        final client = _FixtureClient(
          (_) => _response(
            chunks: [
              _HugeChunk(MediaExportService.defaultMaxDownloadBytes + 1),
            ],
          ),
        );
        final service = MediaExportService(
          root: temp,
          downloadService: DefaultMediaDownloadService(httpClient: client),
          shareFile: (_) async => shared = true,
        );

        await expectLater(
          service.shareRemote(
            Uri.parse('http://host/view?filename=undeclared.png'),
            confirmAfterHeaders: (_) async => true,
          ),
          throwsA(isA<MediaDownloadLimitException>()),
        );

        expect(shared, isFalse);
        expect(_files(temp), isEmpty);
      },
    );

    test('default hard cap rejects a lying huge chunk before save', () async {
      var saved = false;
      final client = _FixtureClient(
        (_) => _response(
          declaredLength: 1,
          chunks: [_HugeChunk(MediaExportService.defaultMaxDownloadBytes + 1)],
        ),
      );
      final service = MediaExportService(
        root: temp,
        downloadService: DefaultMediaDownloadService(httpClient: client),
        saveFile: (_, {required isVideo}) async {
          saved = true;
          return null;
        },
      );

      await expectLater(
        service.saveRemote(
          Uri.parse('http://host/view?filename=lying.png'),
          isVideo: false,
        ),
        throwsA(isA<MediaDownloadLimitException>()),
      );

      expect(saved, isFalse);
      expect(_files(temp), isEmpty);
    });
  });
}

final class _FixtureClient extends http.BaseClient {
  _FixtureClient(this._send);

  final FutureOr<http.StreamedResponse> Function(http.BaseRequest request)
  _send;
  final List<http.BaseRequest> requests = [];

  int get sendCount => requests.length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return _send(request);
  }
}

final class _CancellableResponseBody extends Stream<List<int>> {
  _CancellableResponseBody(this.chunks);

  final List<List<int>> chunks;
  final List<List<int>> acceptedChunks = [];
  final List<List<int>> deliveredChunks = [];
  int listenCount = 0;
  int cancelCount = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCount++;
    var cancelled = false;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        scheduleMicrotask(() {
          if (cancelled) return;
          for (final chunk in chunks) {
            acceptedChunks.add(chunk);
            controller.add(chunk);
          }
          controller.close();
        });
      },
      onCancel: () {
        cancelled = true;
        cancelCount++;
      },
    );
    return controller.stream.listen(
      (chunk) {
        deliveredChunks.add(chunk);
        onData?.call(chunk);
      },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

final class _HugeChunk extends ListBase<int> {
  _HugeChunk(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('fixed fake chunk');

  @override
  int operator [](int index) => 0;

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('read-only fake chunk');
}

final class _InjectedDownloadService implements MediaDownloadPort {
  const _InjectedDownloadService({required this.bytes, required this.modified});

  final List<int> bytes;
  final DateTime modified;

  @override
  Future<File> download(
    Uri uri, {
    required File destination,
    required int maxBytes,
    Map<String, String> headers = const {},
    Future<bool> Function(MediaDownloadInfo)? confirmAfterHeaders,
  }) async {
    if (bytes.length > maxBytes) throw MediaDownloadLimitException(maxBytes);
    final confirm = confirmAfterHeaders;
    if (confirm != null &&
        !await confirm(
          MediaDownloadInfo(
            statusCode: 200,
            contentType: 'image/png',
            declaredBytes: bytes.length,
          ),
        )) {
      throw const MediaDownloadDeclinedException();
    }
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes);
    await destination.setLastModified(modified);
    return destination;
  }
}

final class _FaultInjectingFileOperations implements MediaFileOperations {
  _FaultInjectingFileOperations({
    this.failDelete,
    this.failRename,
    this.listGate,
    this.afterListGate,
    this.afterListGateOnCount,
    this.onListSnapshot,
  });

  final bool Function(File file)? failDelete;
  final bool Function(File file, String newPath)? failRename;
  final Future<void>? listGate;
  final Future<void>? afterListGate;
  final int? afterListGateOnCount;
  final void Function(List<FileSystemEntity> snapshot)? onListSnapshot;
  final List<String> deleteAttempts = [];
  int listCount = 0;

  @override
  Future<void> delete(File file) async {
    deleteAttempts.add(file.path);
    if (failDelete?.call(file) ?? false) {
      throw StateError('injected delete failure: ${file.path}');
    }
    await file.delete();
  }

  @override
  Future<File> rename(File file, String newPath) async {
    if (failRename?.call(file, newPath) ?? false) {
      throw StateError('injected rename failure: ${file.path}');
    }
    return file.rename(newPath);
  }

  @override
  Stream<FileSystemEntity> list(Directory directory) async* {
    listCount++;
    final currentListCount = listCount;
    final gate = listGate;
    if (gate != null) await gate;
    final snapshot = await directory.list().toList();
    for (final entity in snapshot) {
      yield entity;
    }
    if (currentListCount == afterListGateOnCount) {
      onListSnapshot?.call(snapshot);
      final afterGate = afterListGate;
      if (afterGate != null) await afterGate;
    }
  }
}

http.StreamedResponse _response({
  int statusCode = 200,
  required List<List<int>> chunks,
  int? declaredLength,
  Map<String, String> headers = const {},
  Future<void>? beforeChunks,
  void Function()? onChunk,
}) {
  Stream<List<int>> body() async* {
    if (beforeChunks != null) await beforeChunks;
    for (final chunk in chunks) {
      onChunk?.call();
      yield chunk;
    }
  }

  return http.StreamedResponse(
    body(),
    statusCode,
    contentLength: declaredLength,
    headers: headers,
  );
}

List<File> _files(Directory root) =>
    root.listSync(recursive: true).whereType<File>().toList(growable: false);

List<File> _partFiles(Directory root) => _files(
  root,
).where((file) => file.path.endsWith('.part')).toList(growable: false);

List<File> _oldFiles(Directory root) => _files(
  root,
).where((file) => file.path.endsWith('.old')).toList(growable: false);

List<File> _canonicalFiles(Directory root) => _files(root)
    .where(
      (file) => !file.path.endsWith('.part') && !file.path.endsWith('.old'),
    )
    .toList(growable: false);

Future<int> _totalBytes(Directory root) async {
  var total = 0;
  for (final file in _files(root)) {
    total += await file.length();
  }
  return total;
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Condition was not reached');
}
