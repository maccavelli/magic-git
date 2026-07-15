import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/commit_graph.dart';
import '../../core/git/git_service.dart';

/// Cool indigo → blue → cyan ramp for day-volume on the dark canvas.
///
/// Avoids green (HEAD) and orange (tags) so heat stays a background signal
/// under system-colored ref ticks. Alphas are baked into the stops so markers
/// and the viewport band remain legible on top.
const List<(double, Color)> kMinimapVolumeStops = [
  (0.0, Color(0x733A3A4A)), // quiet slate
  (0.3, Color(0x8C5E5CE6)), // system indigo
  (0.6, Color(0xB30A84FF)), // system blue
  (1.0, Color(0xE664D2FF)), // system teal / cyan peak
];

/// Maps day-busyness `t` in 0..1 to a volume heat color. Values outside the
/// unit interval are clamped. Public so unit tests can pin the ramp without
/// pumping the full History panel.
Color minimapVolumeColor(double t) {
  final x = t.clamp(0.0, 1.0);
  const stops = kMinimapVolumeStops;
  if (x <= stops.first.$1) return stops.first.$2;
  if (x >= stops.last.$1) return stops.last.$2;
  for (var i = 1; i < stops.length; i++) {
    final (t0, c0) = stops[i - 1];
    final (t1, c1) = stops[i];
    if (x <= t1) {
      final local = (x - t0) / (t1 - t0);
      return Color.lerp(c0, c1, local)!;
    }
  }
  return stops.last.$2;
}

/// Quantize density into discrete heat levels so adjacent equal-volume rows
/// can be merged into one rect (keeps long histories cheap to paint).
const int _volumeBuckets = 12;

/// Minimum bar width (logical px) when density > 0 so quiet days still show a
/// color fleck on the 18px track.
const double _minBarWidth = 2.5;

/// An annotated scroll track beside the commit list: an activity silhouette
/// (how busy each commit's day was), per-commit markers for HEAD / branches /
/// tags and the current selection, and a viewport band you can click or scrub.
///
/// Geometry is exact because the list has a fixed item extent: row i maps to
/// `(i + 0.5) / rowCount` of the track, no layout information needed.
class HistoryMinimap extends StatelessWidget {
  final ScrollController controller;

  /// Bumped by the owner on every ScrollMetricsNotification from the list.
  /// The controller alone only notifies on scroll — first layout, content
  /// changes, and window resizes would never flip the fits/overflows gate.
  final Listenable metricsTick;

  final CommitGraph graph;
  final Map<String, List<GitRef>> decorations;
  final Set<String> selected;

  /// Per-row activity in 0..1, parallel to `graph.rows` — the share of the
  /// busiest day's commit count that this row's day carried. Memoized by the
  /// owner (this widget rebuilds on every scroll tick; the silhouette must
  /// not be recomputed at that rate).
  final List<double> density;

  const HistoryMinimap({
    super.key,
    required this.controller,
    required this.metricsTick,
    required this.graph,
    required this.decorations,
    required this.selected,
    required this.density,
  });

  static const double width = 18;

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder so a window resize re-evaluates the fits/overflows
    // gating below even when nothing else rebuilds; ListenableBuilder (on
    // both the controller and the metrics tick) so first layout and content
    // changes do too. The painter itself repaints on every scroll tick via
    // `repaint:`.
    return LayoutBuilder(
      builder: (context, constraints) => ListenableBuilder(
        listenable: Listenable.merge([controller, metricsTick]),
        builder: (context, _) {
          // hasContentDimensions: a freshly-attached position throws on
          // maxScrollExtent until its first layout pass has run.
          if (!controller.hasClients ||
              !controller.position.hasContentDimensions ||
              controller.position.maxScrollExtent <= 0) {
            // Everything fits the viewport — a full-height band is noise.
            return const SizedBox.shrink();
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _scrollToDy(context, d.localPosition.dy),
            onVerticalDragUpdate: (d) =>
                _scrollToDy(context, d.localPosition.dy),
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size(width, constraints.maxHeight),
                painter: _MinimapPainter(
                  controller: controller,
                  metricsTick: metricsTick,
                  graph: graph,
                  decorations: decorations,
                  selected: selected,
                  density: density,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Centers the viewport on the track position under the pointer — tap to
  /// jump, drag to scrub (both funnel here; jumpTo keeps scrubbing lag-free).
  void _scrollToDy(BuildContext context, double dy) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !controller.hasClients || box.size.height <= 0) return;
    final position = controller.position;
    final total = position.maxScrollExtent + position.viewportDimension;
    final target =
        (dy / box.size.height) * total - position.viewportDimension / 2;
    controller.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }
}

class _MinimapPainter extends CustomPainter {
  final ScrollController controller;
  final CommitGraph graph;
  final Map<String, List<GitRef>> decorations;
  final Set<String> selected;
  final List<double> density;

  _MinimapPainter({
    required this.controller,
    required Listenable metricsTick,
    required this.graph,
    required this.decorations,
    required this.selected,
    required this.density,
  }) : super(repaint: Listenable.merge([controller, metricsTick]));

  @override
  void paint(Canvas canvas, Size size) {
    final rows = graph.rows;
    if (rows.isEmpty || size.height <= 0) return;

    // Track background — soft lift off the terminal canvas.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x12FFFFFF),
    );

    // Quiet spine: a 1px indigo rail so empty stretches still read as a
    // scroll track rather than a void beside the list.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, 1, size.height),
      Paint()..color = const Color(0x405E5CE6),
    );

    double yFor(int index) => (index + 0.5) / rows.length * size.height;

    // Activity heat: width encodes relative day-busyness; color follows the
    // indigo→blue→cyan ramp. Adjacent rows that quantize to the same bucket
    // and bar width are merged into one rect so long histories stay cheap
    // (unlike translucent whites, solid-ish heat colors do not compound when
    // rows share edges — merging is purely a draw-call optimization).
    if (density.length == rows.length) {
      final rowHeight = size.height / rows.length;
      final paint = Paint();
      // Sentinel-free run state: start < 0 means no open run.
      var runStart = -1;
      var runBucket = -1;
      var runWidth = 0.0;

      void flush(int endExclusive) {
        if (runStart < 0) return;
        final t = (runBucket + 0.5) / _volumeBuckets;
        paint.color = minimapVolumeColor(t);
        canvas.drawRect(
          Rect.fromLTWH(
            0,
            runStart * rowHeight,
            runWidth,
            (endExclusive - runStart) * rowHeight,
          ),
          paint,
        );
        runStart = -1;
      }

      for (var i = 0; i < rows.length; i++) {
        final d = density[i];
        if (d <= 0) {
          flush(i);
          continue;
        }
        final bucket = math.min(
          _volumeBuckets - 1,
          (d.clamp(0.0, 1.0) * _volumeBuckets).floor(),
        );
        final barW = math.max(_minBarWidth, size.width * d);
        // Snap width slightly so near-equal days share a run more often.
        final snappedW = (barW * 2).roundToDouble() / 2;
        if (runStart >= 0 &&
            runBucket == bucket &&
            (runWidth - snappedW).abs() < 0.01) {
          continue;
        }
        flush(i);
        runStart = i;
        runBucket = bucket;
        runWidth = snappedW;
      }
      flush(rows.length);
    }

    // Ref markers (left-inset ticks) and selection markers (right-inset), so
    // a selected, decorated row shows both side by side.
    final tick = Paint();
    for (var i = 0; i < rows.length; i++) {
      final hash = rows[i].commit.hash;
      final color = _refColor(decorations[hash]);
      final y = yFor(i);
      if (color != null) {
        tick.color = color;
        canvas.drawRect(
          Rect.fromLTRB(1.5, y - 1, size.width * 0.6, y + 1),
          tick,
        );
      }
      if (selected.contains(hash)) {
        tick.color = const Color(0xCCFFFFFF);
        canvas.drawRect(
          Rect.fromLTRB(size.width * 0.6, y - 1, size.width - 1.5, y + 1),
          tick,
        );
      }
    }

    // Viewport band — filled with a visible border, since a fill alone
    // vanishes against markers (the recurring GitLens theme-contrast
    // complaint). Stroke is a touch stronger so the band still reads over
    // cyan peak heat.
    if (controller.hasClients && controller.position.hasContentDimensions) {
      final position = controller.position;
      final total = position.maxScrollExtent + position.viewportDimension;
      if (total > 0) {
        final top = position.pixels / total * size.height;
        final height = position.viewportDimension / total * size.height;
        final band = RRect.fromRectAndRadius(
          Rect.fromLTWH(0.5, top, size.width - 1, height),
          const Radius.circular(3),
        );
        canvas.drawRRect(band, Paint()..color = const Color(0x28FFFFFF));
        canvas.drawRRect(
          band,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0x88FFFFFF),
        );
      }
    }
  }

  /// Marker color by the row's most significant decoration — the same
  /// palette as RefChip: HEAD green beats local-branch blue beats tag orange
  /// beats remote gray.
  Color? _refColor(List<GitRef>? refs) {
    if (refs == null || refs.isEmpty) return null;
    Color? best;
    var bestRank = -1;
    for (final ref in refs) {
      final (rank, color) = switch (ref) {
        _ when ref.isHead => (3, MacosColors.systemGreenColor),
        _ when ref.isLocalBranch => (2, MacosColors.systemBlueColor),
        _ when ref.isTag => (1, MacosColors.systemOrangeColor),
        _ => (0, MacosColors.systemGrayColor),
      };
      if (rank > bestRank) {
        bestRank = rank;
        best = color;
      }
    }
    return best;
  }

  @override
  bool shouldRepaint(covariant _MinimapPainter oldDelegate) =>
      oldDelegate.graph != graph ||
      oldDelegate.decorations != decorations ||
      oldDelegate.selected != selected ||
      oldDelegate.density != density;
}
