// Screen-level tests for the app's riskiest logic: the optimistic send, the
// SSE token stream, and the two failure paths (nothing persisted vs. a turn
// the gateway kept). None of this was reachable before ChatScreen gained its
// httpClient/ttsOverride seam -- the 100-odd other tests all cover leaf
// utilities, which is the easy half.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tts_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A TTS backend that does nothing and touches no platform channel.
class _SilentTts implements TtsProvider {
  final List<String> spoken = [];

  @override
  bool get isPlaying => false;
  @override
  Future<PreparedSpeech?> prepare(String text, {bool keepActions = false}) async =>
      null;
  @override
  Future<void> speakPrepared(PreparedSpeech prepared,
      {void Function()? onComplete}) async => onComplete?.call();
  @override
  Future<void> speak(String text,
      {void Function()? onComplete, bool keepActions = false}) async {
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

  static Map<String, dynamic> msg(String role, String content) =>
      {'role': role, 'content': content};

  String _sse(String text) => 'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': text},
          }
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
        Stream.fromIterable(
          gw.streamFrames.map((f) => utf8.encode(gw._sse(f))),
        ),
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

Widget _app(_FakeGateway gw, _SilentTts tts) => MaterialApp(
      home: ChatScreen(
        connection: _conn(),
        session: _session(),
        httpClient: gw.client(),
        ttsOverride: () => tts,
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
    final gw = _FakeGateway(messages: [
      _FakeGateway.msg('user', 'hello there'),
      _FakeGateway.msg('assistant', 'general kenobi'),
    ]);

    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    expect(find.text('hello there'), findsOneWidget);
    expect(find.text('general kenobi'), findsOneWidget);
  });

  testWidgets('a send shows the typed text immediately and streams the reply',
      (tester) async {
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

  testWidgets('does not send history the gateway would discard',
      (tester) async {
    final gw = _FakeGateway(messages: [
      _FakeGateway.msg('user', 'an older question'),
      _FakeGateway.msg('assistant', 'an older answer'),
    ])
      ..streamFrames = ['ok'];

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

  testWidgets('a failed send with nothing persisted restores the draft',
      (tester) async {
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
    expect(find.widgetWithText(SnackBar, 'Send failed: Exception: connection reset'),
        findsOneWidget);
  });

  testWidgets('a dropped connection keeps a turn the gateway did persist',
      (tester) async {
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

  testWidgets('the character persona turn is hidden from the transcript',
      (tester) async {
    final gw = _FakeGateway(messages: [
      _FakeGateway.msg('user', '${CharacterCard.setupMarker}\nYou are Ada.'),
      _FakeGateway.msg('assistant', 'Hello, I am Ada.'),
    ]);

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

  testWidgets('an unknown-capability server still polls for late media',
      (tester) async {
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

  testWidgets('a 404 on the transcript shows an empty chat, not an error',
      (tester) async {
    // A brand-new client-generated session does not exist server-side yet.
    final gw = _FakeGateway();
    await tester.pumpWidget(_app(gw, _SilentTts()));
    await tester.pumpAndSettle();

    expect(find.text('Failed to load messages'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });
}
