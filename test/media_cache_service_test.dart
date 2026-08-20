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
      var chunksRead = 0;
      final client = _FixtureClient(
        (_) => _response(
          statusCode: 404,
          chunks: [
            Uint8List.fromList([1, 2, 3]),
          ],
          onChunk: () => chunksRead++,
        ),
      );
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

      expect(chunksRead, 0);
      expect(await destination.exists(), isFalse);
      expect(_partFiles(temp), isEmpty);
    });

    test('rejects a declared over-limit response before body chunks', () async {
      var chunksRead = 0;
      final client = _FixtureClient(
        (_) => _response(
          chunks: [Uint8List(1)],
          declaredLength: 7,
          onChunk: () => chunksRead++,
        ),
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

      expect(chunksRead, 0);
      expect(await destination.exists(), isFalse);
      expect(_partFiles(temp), isEmpty);
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
        var chunksRead = 0;
        final client = _FixtureClient(
          (_) => _response(
            chunks: [
              Uint8List.fromList([1, 2, 3]),
            ],
            onChunk: () => chunksRead++,
          ),
        );
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

        expect(chunksRead, 0);
        expect(await destination.exists(), isFalse);
        expect(_partFiles(temp), isEmpty);
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

    test('declines an unknown-size save before reading chunks', () async {
      var chunksRead = 0;
      var saved = false;
      final client = _FixtureClient(
        (_) => _response(
          chunks: [
            Uint8List.fromList([1, 2, 3]),
          ],
          onChunk: () => chunksRead++,
        ),
      );
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

      expect(chunksRead, 0);
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

http.StreamedResponse _response({
  int statusCode = 200,
  required List<Uint8List> chunks,
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

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Condition was not reached');
}
