// Scrolling an arbitrary row of a lazily-built list into view.
//
// ListView.builder only builds what is near the viewport, so a row far from
// the current position has no BuildContext and cannot be handed to
// Scrollable.ensureVisible. And because chat bubbles vary enormously in height
// — a one-word reply next to a wall of narration — there is no extent
// arithmetic that lands on the right offset in one go.
//
// So: jump to a proportional estimate, let a frame build, and look again. Once
// the row exists, ensureVisible finishes the job exactly and with animation.
// The estimate improves each pass because jumping nearer builds rows nearer
// the target; a handful of passes is plenty in practice, and running out just
// means a slightly-off resting position rather than a failure.
import 'package:flutter/material.dart';

/// Animates to the end of the list, then corrects to a fixed point.
///
/// `maxScrollExtent` is only an estimate while rows below the viewport are
/// unbuilt — the sliver extrapolates from the average height of what it has
/// built. When the rows at the tail are taller than that average (a chat whose
/// newest turns are long replies), the estimate runs low and animating to it
/// stops well short of the real bottom.
///
/// Correcting once is not enough: jumping to the corrected extent builds more
/// of those tall rows, which grows the extent again. So this re-jumps until
/// the extent stops moving, bounded by [maxCorrections] so a list that somehow
/// never converges cannot spin forever.
Future<void> scrollToEnd(
  ScrollController controller, {
  Duration duration = const Duration(milliseconds: 300),
  Curve curve = Curves.easeOut,
  bool Function()? isMounted,
  Future<void> Function()? waitForFrame,
  int maxCorrections = 10,
}) async {
  if (!controller.hasClients) return;
  final wait = waitForFrame ?? () => WidgetsBinding.instance.endOfFrame;

  await controller.animateTo(
    controller.position.maxScrollExtent,
    duration: duration,
    curve: curve,
  );

  for (var i = 0; i < maxCorrections; i++) {
    // The wait comes FIRST. At the instant animateTo completes the sliver has
    // not rebuilt yet, so maxScrollExtent still reads the stale pre-scroll
    // estimate and the check below would see "already at the bottom" and
    // return without correcting anything.
    await wait();
    if (isMounted != null && !isMounted()) return;
    if (!controller.hasClients) return;
    final end = controller.position.maxScrollExtent;
    // Within half a pixel is the bottom; anything else is a short landing.
    if (controller.position.pixels >= end - 0.5) return;
    controller.jumpTo(end);
  }
}

/// Whether the view is close enough to the bottom that a "jump to latest"
/// affordance would be pointless. The slack absorbs the last bubble's padding
/// and small overscroll wobbles.
bool isNearBottom(ScrollController controller, {double slack = 200}) {
  if (!controller.hasClients) return true;
  return controller.position.pixels >=
      controller.position.maxScrollExtent - slack;
}

/// Scrolls [index] into view, then returns.
///
/// [rowCount] and [anchorContext] are read fresh on each pass rather than
/// captured, because the list rebuilds between frames. [anchorContext] should
/// return the BuildContext of the target row when it happens to be built, and
/// null otherwise.
///
/// Returns true if the row was located and revealed, false if the passes ran
/// out (the list still ends up scrolled close to it).
Future<bool> revealRow({
  required ScrollController controller,
  required int index,
  required int Function() rowCount,
  required BuildContext? Function() anchorContext,
  required bool Function() isMounted,
  Future<void> Function()? waitForFrame,
  int maxAttempts = 6,
  Duration duration = const Duration(milliseconds: 300),
  Curve curve = Curves.easeOut,
  double alignment = 0.15,
}) async {
  final wait =
      waitForFrame ?? () => WidgetsBinding.instance.endOfFrame;

  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    await wait();
    if (!isMounted() || !controller.hasClients) return false;

    final anchor = anchorContext();
    if (anchor != null && anchor.mounted) {
      await Scrollable.ensureVisible(
        anchor,
        duration: duration,
        curve: curve,
        alignment: alignment,
      );
      return true;
    }

    final count = rowCount();
    if (count <= 0) return false;
    final position = controller.position;
    final estimate = (index / count) * position.maxScrollExtent;
    controller.jumpTo(
      estimate.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }
  return false;
}
