// Exercises revealRow against a real lazily-built ListView with the kind of
// wildly uneven row heights a chat transcript actually has, since that is
// exactly what makes single-shot offset arithmetic wrong.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/reveal_row.dart';

/// Heights cycle 40 / 300 / 90 so the list is nothing like uniform — a
/// proportional estimate lands well off the mark and has to converge.
double _heightFor(int i) => const [40.0, 300.0, 90.0][i % 3];

/// Short rows everywhere except a tall tail. This is the shape that actually
/// breaks a single animateTo: while only short rows are built, the sliver
/// extrapolates a much smaller total than the truth, so animating to the
/// extent known up front stops well short of the real bottom. A chat hits this
/// whenever the newest turns are long.
double _tallTailHeightFor(int i, int count) => i >= count - 20 ? 400.0 : 40.0;

class _Harness extends StatefulWidget {
  const _Harness({
    required this.count,
    required this.anchorIndex,
    this.tallTail = false,
  });

  final int count;
  final int anchorIndex;
  final bool tallTail;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = ScrollController();
  final anchorKey = GlobalKey();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<bool> reveal() => revealRow(
        controller: controller,
        index: widget.anchorIndex,
        rowCount: () => widget.count,
        anchorContext: () => anchorKey.currentContext,
        isMounted: () => mounted,
        duration: Duration.zero,
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          controller: controller,
          itemCount: widget.count,
          itemBuilder: (context, i) => SizedBox(
            key: i == widget.anchorIndex ? anchorKey : ValueKey(i),
            height: widget.tallTail
                ? _tallTailHeightFor(i, widget.count)
                : _heightFor(i),
            child: Text('row $i'),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('reveals a row far below the viewport', (tester) async {
    await tester.pumpWidget(
      const _Harness(count: 400, anchorIndex: 350),
    );
    await tester.pumpAndSettle();

    final state = tester.state<_HarnessState>(find.byType(_Harness));
    expect(find.text('row 350'), findsNothing, reason: 'starts off screen');

    final future = state.reveal();
    await tester.pumpAndSettle();
    expect(await future, isTrue);

    expect(find.text('row 350'), findsOneWidget);
  });

  testWidgets('reveals a row above the current position', (tester) async {
    await tester.pumpWidget(
      const _Harness(count: 400, anchorIndex: 12),
    );
    await tester.pumpAndSettle();

    final state = tester.state<_HarnessState>(find.byType(_Harness));
    state.controller.jumpTo(state.controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('row 12'), findsNothing);

    final future = state.reveal();
    await tester.pumpAndSettle();
    expect(await future, isTrue);

    expect(find.text('row 12'), findsOneWidget);
  });

  testWidgets('a row already on screen is revealed without any jumping',
      (tester) async {
    await tester.pumpWidget(
      const _Harness(count: 400, anchorIndex: 1),
    );
    await tester.pumpAndSettle();

    final state = tester.state<_HarnessState>(find.byType(_Harness));
    final before = state.controller.position.pixels;

    final future = state.reveal();
    await tester.pumpAndSettle();
    expect(await future, isTrue);

    // alignment 0.15 still nudges it into place, but it must not have taken
    // the estimate path and flung the list somewhere far away.
    expect((state.controller.position.pixels - before).abs(), lessThan(200));
    expect(find.text('row 1'), findsOneWidget);
  });

  testWidgets('an empty list gives up instead of dividing by zero',
      (tester) async {
    await tester.pumpWidget(const _Harness(count: 0, anchorIndex: 0));
    await tester.pumpAndSettle();

    final state = tester.state<_HarnessState>(find.byType(_Harness));
    final future = state.reveal();
    await tester.pumpAndSettle();
    expect(await future, isFalse);
  });

  group('scrollToEnd', () {
    testWidgets('a single animateTo falls short when the tail is tall',
        (tester) async {
      // Establishes that the correction pass is load-bearing, not cosmetic.
      await tester.pumpWidget(
        const _Harness(count: 400, anchorIndex: 0, tallTail: true),
      );
      await tester.pumpAndSettle();
      final state = tester.state<_HarnessState>(find.byType(_Harness));

      // The naive version of scrollToEnd: animate to the extent known now.
      final naiveTarget = state.controller.position.maxScrollExtent;
      final future = state.controller.animateTo(
        naiveTarget,
        duration: const Duration(milliseconds: 1),
        curve: Curves.easeOut,
      );
      await tester.pumpAndSettle();
      await future;

      expect(
        state.controller.position.pixels,
        lessThan(state.controller.position.maxScrollExtent - 1000),
        reason: 'the real extent grew as the tall tail rows were built',
      );
      expect(find.text('row 399'), findsNothing);
    });

    testWidgets('lands on the true bottom when the tail is tall',
        (tester) async {
      await tester.pumpWidget(
        const _Harness(count: 400, anchorIndex: 0, tallTail: true),
      );
      await tester.pumpAndSettle();
      final state = tester.state<_HarnessState>(find.byType(_Harness));

      final future = scrollToEnd(
        state.controller,
        duration: const Duration(milliseconds: 1),
      );
      await tester.pumpAndSettle();
      await future;

      expect(
        state.controller.position.pixels,
        moreOrLessEquals(state.controller.position.maxScrollExtent, epsilon: 0.5),
      );
      expect(find.text('row 399'), findsOneWidget);
    });

    testWidgets('also lands on the bottom when the estimate ran high',
        (tester) async {
      // The opposite error: here the unbuilt rows are SHORTER than the built
      // average, so animateTo clamps and the correction is a no-op. Both
      // directions have to end at the bottom.
      await tester.pumpWidget(const _Harness(count: 400, anchorIndex: 0));
      await tester.pumpAndSettle();
      final state = tester.state<_HarnessState>(find.byType(_Harness));

      final future = scrollToEnd(
        state.controller,
        duration: const Duration(milliseconds: 1),
      );
      await tester.pumpAndSettle();
      await future;

      expect(
        state.controller.position.pixels,
        moreOrLessEquals(state.controller.position.maxScrollExtent, epsilon: 0.5),
      );
      expect(find.text('row 399'), findsOneWidget);
    });

    testWidgets('is a no-op without clients rather than throwing',
        (tester) async {
      final orphan = ScrollController();
      addTearDown(orphan.dispose);
      await scrollToEnd(orphan, duration: const Duration(milliseconds: 1));
    });
  });

  group('isNearBottom', () {
    testWidgets('is false when scrolled up, true at the bottom',
        (tester) async {
      await tester.pumpWidget(const _Harness(count: 400, anchorIndex: 0));
      await tester.pumpAndSettle();
      final state = tester.state<_HarnessState>(find.byType(_Harness));

      expect(isNearBottom(state.controller), isFalse);

      final future = scrollToEnd(state.controller, duration: const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      await future;

      expect(isNearBottom(state.controller), isTrue);
    });

    testWidgets('treats a controller with no clients as "nothing to jump to"',
        (tester) async {
      final orphan = ScrollController();
      addTearDown(orphan.dispose);
      expect(isNearBottom(orphan), isTrue);
    });

    testWidgets('the slack window still counts as near the bottom',
        (tester) async {
      await tester.pumpWidget(const _Harness(count: 400, anchorIndex: 0));
      await tester.pumpAndSettle();
      final state = tester.state<_HarnessState>(find.byType(_Harness));

      final future = scrollToEnd(state.controller, duration: const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      await future;

      // 100px up is inside the 200px slack, so the button stays hidden.
      state.controller.jumpTo(state.controller.position.pixels - 100);
      await tester.pumpAndSettle();
      expect(isNearBottom(state.controller), isTrue);

      // 300px up is outside it.
      state.controller.jumpTo(state.controller.position.pixels - 300);
      await tester.pumpAndSettle();
      expect(isNearBottom(state.controller), isFalse);
    });
  });
}
