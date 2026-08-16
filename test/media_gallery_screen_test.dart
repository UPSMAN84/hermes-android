// The gallery doubles as an index into the conversation: long-pressing a tile
// pops back with the message that produced that image, which the chat screen
// then scrolls to. These cover what it collects and what it hands back.
//
// CachedMediaThumbnail's disk-cache lookup fails in a test (no path_provider),
// which is fine — it renders its broken-image state and the tile is still
// there to press.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/media_gallery_screen.dart';

const _base = 'http://comfy:8188';

Map<String, dynamic> _tool(String content) =>
    {'role': 'tool', 'content': content};

Map<String, dynamic> _userWithImage(String dataUrl) => {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'look at this'},
        {
          'type': 'image_url',
          'image_url': {'url': dataUrl},
        },
      ],
    };

Future<Map<String, dynamic>?> _openAndLongPress(
  WidgetTester tester,
  List<Map<String, dynamic>> messages, {
  String? longPressUrl,
}) async {
  Map<String, dynamic>? popped;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async {
          popped = await Navigator.push<Map<String, dynamic>>(
            context,
            MaterialPageRoute(
              builder: (_) => MediaGalleryScreen(
                messages: messages,
                comfyBaseUrl: _base,
              ),
            ),
          );
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  // Bounded pumps rather than pumpAndSettle: the thumbnails sit on a
  // CircularProgressIndicator (their disk-cache lookup never resolves without
  // path_provider), and an indeterminate spinner never settles.
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  if (longPressUrl == null) return null;
  final tile = find.byKey(ValueKey(longPressUrl));
  if (tile.evaluate().isEmpty) return null;
  await tester.longPress(tile);
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return popped;
}

void main() {
  testWidgets('counts each generated image once, however often it is named',
      (tester) async {
    // A filename can resurface in later tool output (a post-render directory
    // listing, say) without being a second picture.
    await _openAndLongPress(tester, [
      _tool(r'rendered: C:\out\TG_00084_.png'),
      _tool(r'verified C:\out\TG_00084_.png exists'),
      _tool(r'rendered: C:\out\TG_00085_.png'),
    ]);
    // Two distinct images, not three mentions.
    expect(find.text('Images (2)'), findsOneWidget);
  });

  testWidgets('leaves videos out of the image gallery', (tester) async {
    await _openAndLongPress(tester, [
      _tool(r'rendered: C:\out\clip_0001.mp4'),
      _tool(r'rendered: C:\out\still_0001.png'),
    ]);
    expect(find.text('Images (1)'), findsOneWidget);
  });

  testWidgets('includes images the user attached', (tester) async {
    await _openAndLongPress(tester, [
      _userWithImage('data:image/png;base64,iVBORw0KGgo='),
      _tool(r'rendered: C:\out\TG_1.png'),
    ]);
    expect(find.text('Images (2)'), findsOneWidget);
  });

  testWidgets('long-pressing a tile pops the message that produced it',
      (tester) async {
    final first = _tool(r'rendered: C:\out\TG_1.png');
    final second = _tool(r'rendered: C:\out\TG_2.png');

    final popped = await _openAndLongPress(
      tester,
      [first, second],
      longPressUrl: '$_base/view?filename=TG_2.png&type=output',
    );

    // Identity, not a copy — the chat screen matches on it to find the row.
    expect(popped, isNotNull);
    expect(identical(popped, second), isTrue);
  });

  testWidgets('an empty gallery says so and offers nothing to press',
      (tester) async {
    await _openAndLongPress(tester, [
      {'role': 'assistant', 'content': 'no pictures here'},
    ]);
    expect(find.text('Images (0)'), findsOneWidget);
    expect(find.text('No images yet'), findsOneWidget);
  });
}
