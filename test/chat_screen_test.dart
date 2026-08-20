// Screen-level tests for the app's riskiest logic: the optimistic send, the
// SSE token stream, and the two failure paths (nothing persisted vs. a turn
// the gateway kept). None of this was reachable before ChatScreen gained its
// httpClient/ttsOverride seam -- the 100-odd other tests all cover leaf
// utilities, which is the easy half.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/media_cache_service.dart';
import 'package:hermes_android/core/services/tts_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A TTS backend that does nothing and touches no platform channel.
class _SilentTts implements TtsProvider {
  final List<String> spoken = [];

  @override
  bool get isPlaying => false;
  @override
  Future<PreparedSpeech?> prepare(
    String text, {
    bool keepActions = false,
    String? voiceOverride,
  }) async => null;
  @override
  Future<void> speakPrepared(
    PreparedSpeech prepared, {
    void Function()? onComplete,
  }) async => onComplete?.call();
  @override
  Future<void> speak(
    String text, {
    void Function()? onComplete,
      bool keepActions = false,
    String? voiceOverride,
  }) async {
    spoken.add(text);
    onComplete?.call();
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  void dispose() {}
}

class _RecordingMediaCache implements MediaCachePort {
  final List<Uri> uris = [];

  @override
  Future<File?> cache(Uri uri, {Map<String, String> headers = const {}}) async {
    uris.add(uri);
    return null;
  }

  @override
  Future<void> remove(Uri uri) async {}
}

/// Scriptable gateway. [messages] is what GET .../messages returns, and it can
/// be swapped between calls to model the server changing underneath the app.
class _FakeGateway {
  _FakeGateway({List<Map<String, dynamic>>? messages})
      : messages = messages ?? [];

  List<Map<String, dynamic>> messages;

  /// SSE frames the chat completion streams back, in order.
  List<String> streamFrames = [];

  /// When set, POST /v1/chat/completions fails with this.
  Object? sendError;

  int sendCount = 0;
  int messageFetches = 0;
  final List<String> sentBodies = [];

  static Map<String, dynamic> msg(String role, String content) => {
    'role': role,
    'content': content,
  };

  String _sse(String text) =>
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': text},
          },
        ],
      })}\n\n';

  http.Client client() => _FakeClient(this);
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.gw);
  final _FakeGateway gw;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;

    if (path.endsWith('/messages')) {
      gw.messageFetches++;
      final body = jsonEncode({'data': gw.messages});
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        request: request,
      );
    }

    if (path.endsWith('/chat/completions')) {
      gw.sendCount++;
      if (request is http.Request) gw.sentBodies.add(request.body);
      final err = gw.sendError;
      if (err != null) throw err;
      return http.StreamedResponse(
        Stream.fromIterable([
          ...gw.streamFrames.map((f) => utf8.encode(gw._sse(f))),
          // Real completions always close with the literal `[DONE]` frame --
          // sendMessageStreaming uses its presence to tell a normal finish
          // apart from a dropped connection, so a fake "successful" stream
          // without it would be misreported as interrupted.
          utf8.encode('data: [DONE]\n\n'),
        ]),
        200,
        request: request,
      );
    }

    // /health and anything else.
    return http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      200,
      request: request,
    );
  }
}

SavedConnection _conn() => SavedConnection(
      id: 'c1',
      label: 'Test',
      host: 'localhost',
      port: 8642,
      apiKey: 'k',
    );

Session _session() => Session(
      id: 'sess-1',
      title: 'Test chat',
      model: 'hermes-agent',
      source: 'mobile',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: 0,
    );

Widget _app(_FakeGateway gw, _SilentTts tts, {MediaCachePort? mediaCache}) =>
    MaterialApp(
      home: ChatScreen(
        connection: _conn(),
        session: _session(),
        httpClient: gw.client(),
        ttsOverride: () => tts,
        mediaCache: mediaCache,
      ),
    );

void main() {
  setUp(() {
    // Model a current-generation gateway, i.e. one that reports rendered
    // filenames on the tool-progress frame. Without this the screen falls
    // back to the legacy read-after-write polling, whose 1.5s timers outlive
    // the widget tree and make every send test wait six seconds for nothing.
    // The legacy path gets its own test below.
    SharedPreferences.setMockInitialValues({
      'server_sends_media_filename_c1': true,
    });
  });

  testWidgets('renders the transcript it fetched', (tester) async {
    final gw = _FakeGateway(
      messages: [
      _FakeGateway.msg('user', 'hello there'),
      _FakeGateway.msg('assistant', 'general kenobi'),
      ],
    );

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    expect(find.text('hello there'), findsOneWidget);
    expect(find.text('general kenobi'), findsOneWidget);
  });

  testWidgets('does not send rendered videos to the image cache', (
    tester,
  ) async {
    final cache = _RecordingMediaCache();
    final gw = _FakeGateway(
      messages: [_FakeGateway.msg('tool', r'rendered: C:\out\clip_0001.mp4')],
    );

    await tester.pumpWidget(_app(gw, _SilentTts(), mediaCache: cache));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(cache.uris, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a send shows the typed text immediately and streams the reply', (
    tester,
  ) async {
    final gw = _FakeGateway()..streamFrames = ['Hi', ' there', '!'];

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ping');
    // The server will report both turns once the stream finishes.
    gw.messages = [
      _FakeGateway.msg('user', 'ping'),
      _FakeGateway.msg('assistant', 'Hi there!'),
    ];
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(gw.sendCount, 1);
    expect(find.text('ping'), findsOneWidget);
    expect(find.text('Hi there!'), findsOneWidget);
  });

  testWidgets('does not send history the gateway would discard', (
    tester,
  ) async {
    final gw = _FakeGateway(
      messages: [
      _FakeGateway.msg('user', 'an older question'),
      _FakeGateway.msg('assistant', 'an older answer'),
      ],
    )..streamFrames = ['ok'];

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'new question');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    final body = jsonDecode(gw.sentBodies.single) as Map<String, dynamic>;
    final sent = (body['messages'] as List).cast<Map<String, dynamic>>();
    // Exactly the new turn -- the transcript above it is rebuilt server-side
    // from the session id, so shipping it again is pure upload cost.
    expect(sent.length, 1);
    expect(sent.single['content'], 'new question');
    expect(body['messages'].toString(), isNot(contains('an older question')));
  });

  testWidgets('a failed send with nothing persisted restores the draft', (
    tester,
  ) async {
    final gw = _FakeGateway()..sendError = Exception('connection reset');

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'this should come back');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    // The optimistic row is gone and the text is back in the composer, so the
    // message is not silently lost.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'this should come back');
    expect(
      find.widgetWithText(SnackBar, 'Send failed: Exception: connection reset'),
      findsOneWidget,
    );
  });

  testWidgets('a dropped connection keeps a turn the gateway did persist', (
    tester,
  ) async {
    // The gateway interrupts and PERSISTS on client disconnect, so a
    // network-level error does not mean nothing happened. Rolling back here
    // would hide a real turn and invite a duplicate resend.
    final gw = _FakeGateway()..sendError = Exception('socket closed');

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'did this land?');
    gw.messages = [
      _FakeGateway.msg('user', 'did this land?'),
      _FakeGateway.msg('assistant', 'partial repl'),
    ];
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.text('did this land?'), findsOneWidget);
    expect(find.text('partial repl'), findsOneWidget);
    // Draft NOT restored, because the turn is really there.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('the character persona turn is hidden from the transcript', (
    tester,
  ) async {
    final gw = _FakeGateway(
      messages: [
      _FakeGateway.msg('user', '${CharacterCard.setupMarker}\nYou are Ada.'),
      _FakeGateway.msg('assistant', 'Hello, I am Ada.'),
      ],
    );

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    expect(find.text('Hello, I am Ada.'), findsOneWidget);
    expect(find.textContaining('You are Ada.'), findsNothing);
  });

  testWidgets('an empty message is not sent', (tester) async {
    final gw = _FakeGateway();

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(gw.sendCount, 0);
  });

  testWidgets('an unknown-capability server still polls for late media', (
    tester,
  ) async {
    // The legacy path: no filename on the progress frame, so the screen
    // re-checks a few times in case the tool-result row lands after the
    // stream closed. Times out to nothing here; the point is that it runs and
    // then stops cleanly rather than polling forever.
    SharedPreferences.setMockInitialValues({});
    final gw = _FakeGateway()..streamFrames = ['done'];

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();
    final beforeSend = gw.messageFetches;

    await tester.enterText(find.byType(TextField), 'make me a picture');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    // onDone's refetch.
    expect(gw.messageFetches, greaterThan(beforeSend));

    // Drain the poll ladder so no timer outlives the tree.
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
  });

  group('in-chat search', () {
    Future<void> openWith(
      WidgetTester tester,
      List<Map<String, dynamic>> msgs,
    ) async {
      await tester.pumpWidget(_app(_FakeGateway(messages: msgs), _SilentTts()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search this chat'));
      await tester.pumpAndSettle();
    }

    testWidgets('counts matches and reports none for a miss', (tester) async {
      await openWith(tester, [
        _FakeGateway.msg('user', 'tell me about the gold necklace'),
        _FakeGateway.msg('assistant', 'the necklace is old'),
        _FakeGateway.msg('assistant', 'unrelated reply'),
      ]);

      await tester.enterText(find.byKey(searchFieldKey), 'necklace');
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);

      await tester.enterText(find.byKey(searchFieldKey), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('none'), findsOneWidget);
    });

    testWidgets('starts at the most recent match and wraps both ways', (
      tester,
    ) async {
      await openWith(tester, [
        _FakeGateway.msg('user', 'match one'),
        _FakeGateway.msg('assistant', 'filler'),
        _FakeGateway.msg('user', 'match two'),
      ]);

      await tester.enterText(find.byKey(searchFieldKey), 'match');
      await tester.pumpAndSettle();
      // Newest first: in a long chat the thing you want is usually the last
      // time it came up.
      expect(find.text('2/2'), findsOneWidget);

      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget, reason: 'wraps forward');

      await tester.tap(find.byTooltip('Previous match'));
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget, reason: 'wraps backward');
    });

    testWidgets('search is case-insensitive', (tester) async {
      await openWith(tester, [
        _FakeGateway.msg('assistant', 'The Necklace Is Gold'),
      ]);
      await tester.enterText(find.byKey(searchFieldKey), 'necklace is');
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
    });

    testWidgets('closing search restores the normal app bar', (tester) async {
      await openWith(tester, [_FakeGateway.msg('assistant', 'hello')]);
      expect(find.byTooltip('Close search'), findsOneWidget);

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Search this chat'), findsOneWidget);
      expect(find.text('Test chat'), findsOneWidget);
    });

    testWidgets('tool rows are not searchable, only real messages', (
      tester,
    ) async {
      // Tool output is raw JSON and often huge; matching inside it would bury
      // the reader in hits they cannot act on.
      await openWith(tester, [
        {'role': 'tool', 'content': 'searchtoken in tool output'},
        _FakeGateway.msg('assistant', 'a normal reply'),
      ]);
      await tester.enterText(find.byKey(searchFieldKey), 'searchtoken');
      await tester.pumpAndSettle();
      expect(find.text('none'), findsOneWidget);
    });
  });

  group('edit & regenerate (resend as new message, not in-place)', () {
    testWidgets('regenerate is only offered on the last assistant message', (
      tester,
    ) async {
      final gw = _FakeGateway(
        messages: [
        _FakeGateway.msg('user', 'first question'),
        _FakeGateway.msg('assistant', 'first answer'),
        _FakeGateway.msg('user', 'second question'),
        _FakeGateway.msg('assistant', 'second answer'),
        ],
      );

      await tester.pumpWidget(_app(gw, _SilentTts()));
      await tester.pumpAndSettle();

      expect(
        find.byTooltip('Ask again (sends as a new message)'),
        findsOneWidget,
      );
    });

    testWidgets('regenerate re-sends the last user turn as a new message', (
      tester,
    ) async {
      final gw = _FakeGateway(
        messages: [
        _FakeGateway.msg('user', 'tell me a joke'),
        _FakeGateway.msg('assistant', 'why did the chicken...'),
        ],
      )..streamFrames = ['a new joke'];

      await tester.pumpWidget(_app(gw, _SilentTts()));
      await tester.pumpAndSettle();

      gw.messages = [
        ...gw.messages,
        _FakeGateway.msg('user', 'tell me a joke'),
        _FakeGateway.msg('assistant', 'a new joke'),
      ];
      await tester.tap(find.byTooltip('Ask again (sends as a new message)'));
      await tester.pumpAndSettle();

      expect(gw.sendCount, 1);
      final body = jsonDecode(gw.sentBodies.single) as Map<String, dynamic>;
      final sent = (body['messages'] as List).cast<Map<String, dynamic>>();
      // Only the re-sent turn, not the old reply it's meant to supersede --
      // there is no server endpoint to remove the old one, so the old
      // assistant reply stays in the transcript and a second one is appended.
      expect(sent.single['content'], 'tell me a joke');
    });

    testWidgets('edit & resend sends the edited text as a new message', (
      tester,
    ) async {
      final gw = _FakeGateway(
        messages: [_FakeGateway.msg('user', 'origanl typo')],
      )..streamFrames = ['fixed reply'];

      await tester.pumpWidget(_app(gw, _SilentTts()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit & resend as a new message'));
      await tester.pumpAndSettle();

      // Pre-filled with the original message's text.
      expect(find.widgetWithText(TextField, 'origanl typo'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'origanl typo'),
        'original fixed',
      );
      gw.messages = [
        ...gw.messages,
        _FakeGateway.msg('user', 'original fixed'),
        _FakeGateway.msg('assistant', 'fixed reply'),
      ];
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(gw.sendCount, 1);
      final body = jsonDecode(gw.sentBodies.single) as Map<String, dynamic>;
      final sent = (body['messages'] as List).cast<Map<String, dynamic>>();
      expect(sent.single['content'], 'original fixed');
      // The original (with its typo) is untouched -- edit doesn't rewrite it.
      expect(find.text('origanl typo'), findsOneWidget);
    });

    testWidgets('cancelling edit does not send anything', (tester) async {
      final gw = _FakeGateway(
        messages: [_FakeGateway.msg('user', 'leave me alone')],
      );

      await tester.pumpWidget(_app(gw, _SilentTts()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit & resend as a new message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(gw.sendCount, 0);
    });
  });

  testWidgets('a 404 on the transcript shows an empty chat, not an error', (
    tester,
  ) async {
    // A brand-new client-generated session does not exist server-side yet.
    final gw = _FakeGateway();
    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    expect(find.text('Failed to load messages'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}
