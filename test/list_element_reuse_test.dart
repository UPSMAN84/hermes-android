// Pins the framework behaviour behind the stale-video-player bug.
//
// The chat transcript's row list is rebuilt from scratch on every refetch, and
// rows shift when a tool group or media row gets inserted between bubbles.
// Rows carry no keys, so Flutter matches children by index and *updates* the
// existing element instead of recreating it. For a stateless row that is fine
// and desirable. For a row that owns something expensive and source-specific
// — _VideoBubble owns an opened media_kit Player — it means the State survives
// with a new `url` it never looked at, so the old clip keeps playing in the
// new row.
//
// These tests demonstrate both halves of the fix: didUpdateWidget makes the
// widget self-correcting regardless of reuse, and a ValueKey on the source
// makes the element follow its content when siblings shift.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors _VideoBubble's shape: a stateful row that resolves `url` once.
class _SourceRow extends StatefulWidget {
  const _SourceRow({
    required this.url,
    required this.onOpen,
    this.watchForUpdates = false,
    super.key,
  });

  final String url;
  final void Function(String url) onOpen;

  /// When true the widget implements the didUpdateWidget re-resolve that
  /// _VideoBubble was missing.
  final bool watchForUpdates;

  @override
  State<_SourceRow> createState() => _SourceRowState();
}

class _SourceRowState extends State<_SourceRow> {
  /// What this row actually has open — the analogue of the Player's media.
  late String opened;

  @override
  void initState() {
    super.initState();
    opened = widget.url;
    widget.onOpen(widget.url);
  }

  @override
  void didUpdateWidget(_SourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.watchForUpdates && oldWidget.url != widget.url) {
      opened = widget.url;
      widget.onOpen(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) => Text(opened, textDirection: TextDirection.ltr);
}

Widget _list(
  List<String> urls, {
  required void Function(String) onOpen,
  bool watchForUpdates = false,
  bool keyed = false,
  bool locateMovedChildren = false,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ListView.builder(
      itemCount: urls.length,
      findChildIndexCallback: locateMovedChildren
          ? (Key key) {
              final index = urls.indexOf((key as ValueKey<String>).value);
              return index < 0 ? null : index;
            }
          : null,
      itemBuilder: (context, i) => _SourceRow(
        key: keyed ? ValueKey(urls[i]) : null,
        url: urls[i],
        onOpen: onOpen,
        watchForUpdates: watchForUpdates,
      ),
    ),
  );
}

void main() {
  testWidgets(
      'unkeyed row with no didUpdateWidget keeps the old source when rows shift',
      (tester) async {
    final opened = <String>[];

    await tester.pumpWidget(_list(['clip-a'], onOpen: opened.add));
    expect(opened, ['clip-a']);

    // A refetch inserts a row above the video.
    await tester.pumpWidget(_list(['inserted', 'clip-a'], onOpen: opened.add));

    // The element at index 0 was reused for 'inserted' and index 1 is a fresh
    // element, so the row that should show 'clip-a' opened it again while the
    // reused one is showing the WRONG source: it reports 'clip-a' even though
    // its widget now says 'inserted'.
    expect(find.text('inserted'), findsNothing);
    expect(find.text('clip-a'), findsNWidgets(2));
  });

  testWidgets('didUpdateWidget makes the row self-correcting under reuse',
      (tester) async {
    final opened = <String>[];

    await tester.pumpWidget(
      _list(['clip-a'], onOpen: opened.add, watchForUpdates: true),
    );
    await tester.pumpWidget(
      _list(['inserted', 'clip-a'], onOpen: opened.add, watchForUpdates: true),
    );

    expect(find.text('inserted'), findsOneWidget);
    expect(find.text('clip-a'), findsOneWidget);
  });

  testWidgets('a ValueKey alone does NOT preserve the element across a shift',
      (tester) async {
    final opened = <String>[];

    await tester.pumpWidget(_list(['clip-a'], onOpen: opened.add, keyed: true));
    expect(opened, ['clip-a']);

    await tester.pumpWidget(
      _list(['inserted', 'clip-a'], onOpen: opened.add, keyed: true),
    );

    // Keys DO stop the wrong-source reuse — the display is correct — but in a
    // lazily-built ListView the sliver cannot locate a keyed child that moved
    // to a different index without findChildIndexCallback, so it discards and
    // rebuilds it. 'clip-a' was opened a second time.
    //
    // This is why keys are not the fix for the stale-player bug on their own:
    // they trade a wrong clip for a torn-down and re-opened one.
    expect(opened, ['clip-a', 'inserted', 'clip-a']);
    expect(find.text('inserted'), findsOneWidget);
    expect(find.text('clip-a'), findsOneWidget);
  });

  testWidgets(
      'keys plus findChildIndexCallback do preserve the element across a shift',
      (tester) async {
    final opened = <String>[];

    await tester.pumpWidget(
      _list(['clip-a'],
          onOpen: opened.add, keyed: true, locateMovedChildren: true),
    );
    await tester.pumpWidget(
      _list(['inserted', 'clip-a'],
          onOpen: opened.add, keyed: true, locateMovedChildren: true),
    );

    // Now 'clip-a' keeps its element and is never re-opened — only the
    // genuinely new row is built.
    expect(opened, ['clip-a', 'inserted']);
    expect(find.text('inserted'), findsOneWidget);
    expect(find.text('clip-a'), findsOneWidget);
  });
}
