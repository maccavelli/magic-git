import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/commit_graph.dart';
import '../../core/git/git_service.dart';

/// Cool indigo → blue → soft teal ramp for day-volume on the dark canvas.
///
/// Avoids green (HEAD) and orange (tags) so heat stays a background signal
/// under system-colored ref ticks. Peak teal is deliberately muted — a bright
/// cyan competed with the viewport band and felt harsh on `#1E1E1E`.
const List<(double, Color)> kMinimapVolumeStops = [
  (0.0, Color(0x55383C48)), // quiet cool slate
  (0.35, Color(0x665E5CE6)), // system indigo
  (0.65, Color(0x780A84FF)), // system blue
  (1.0, Color(0x7048A0C0)), // soft muted teal peak (not electric cyan)
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

/// Minimum bar width (logical px) when smoothed density > 0 so quiet days
/// still show a color fleck on the 18px track.
const double _minBarWidth = 2.0;

/// Vertical blur radius for the volume layer — softens day-boundary steps
/// into a continuous fade without washing out the silhouette.
const double _volumeBlurSigma = 1.15;

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

  // Paint runs on EVERY scroll tick (the repaint listenable), but rows,
  // decorations and selection only change with a widget rebuild — which
  // constructs a fresh painter. So everything derivable from the constructor
  // inputs is computed once per painter and reused across scroll frames;
  // without this, a deep paged-in history re-smoothed the whole density
  // series and re-ranked every row's decorations on every scrolled pixel.
  List<double>? _smoothedCache;
  List<(int, Color)>? _refMarksCache;
  List<int>? _selectedRowsCache;

  List<(int, Color)> get _refMarks => _refMarksCache ??= [
    for (var i = 0; i < graph.rows.length; i++)
      if (_refColor(decorations[graph.rows[i].commit.hash]) case final c?)
        (i, c),
  ];

  List<int> get _selectedRows => _selectedRowsCache ??= [
    if (selected.isNotEmpty)
      for (var i = 0; i < graph.rows.length; i++)
        if (selected.contains(graph.rows[i].commit.hash)) i,
  ];

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
      Paint()..color = const Color(0x355E5CE6),
    );

    double yFor(int index) => (index + 0.5) / rows.length * size.height;

    // Activity heat: continuous vertical sample of density, color-lerped
    // along the cool ramp, with a soft right-edge fade and a light blur so
    // day boundaries dissolve instead of reading as solid color blocks.
    if (density.length == rows.length) {
      _paintVolumeHeat(canvas, size, density);
    }

    // Ref markers (left-inset ticks) and selection markers (right-inset), so
    // a selected, decorated row shows both side by side.
    final tick = Paint();
    for (final (i, color) in _refMarks) {
      final y = yFor(i);
      tick.color = color;
      canvas.drawRect(
        Rect.fromLTRB(1.5, y - 1, size.width * 0.6, y + 1),
        tick,
      );
    }
    tick.color = const Color(0xCCFFFFFF);
    for (final i in _selectedRows) {
      final y = yFor(i);
      canvas.drawRect(
        Rect.fromLTRB(size.width * 0.6, y - 1, size.width - 1.5, y + 1),
        tick,
      );
    }

    // Viewport band — filled with a visible border, since a fill alone
    // vanishes against markers (the recurring GitLens theme-contrast
    // complaint).
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

  /// Draws the volume silhouette as a continuous, softly blurred field.
  ///
  /// Density is box-smoothed, then sampled at ~1 logical px vertically with
  /// linear interpolation between rows so color and width glide rather than
  /// step. Each strip fades on its right edge; the whole layer is blurred
  /// slightly so remaining steps melt together.
  void _paintVolumeHeat(Canvas canvas, Size size, List<double> raw) {
    final smoothed = _smoothedCache ??= _smoothDensity(raw);
    final n = smoothed.length;
    if (n == 0) return;

    // One strip per logical pixel keeps long histories cheap enough (track
    // height is a few hundred px) while short lists still interpolate finely.
    final strips = math.max(1, size.height.round());
    final stripH = size.height / strips;

    // Draw into a blurred offscreen layer so vertical density steps dissolve
    // into a continuous wash when composited back.
    canvas.saveLayer(
      Offset.zero & size,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: _volumeBlurSigma * 0.4,
          sigmaY: _volumeBlurSigma,
        ),
    );
    final paint = Paint()..style = PaintingStyle.fill;

    for (var s = 0; s < strips; s++) {
      // Sample at strip center in continuous row-index space.
      final rowPos = ((s + 0.5) / strips) * n - 0.5;
      final d = _sampleDensity(smoothed, rowPos);
      if (d <= 0.004) continue;

      final barW = math.max(_minBarWidth, size.width * d);
      final y = s * stripH;
      final color = minimapVolumeColor(d);

      // Soft horizontal falloff: solid for most of the bar, then ease out so
      // the silhouette edge is a fade, not a hard cut.
      paint.shader = ui.Gradient.linear(
        Offset(0, y),
        Offset(barW, y),
        [
          color,
          color,
          color.withValues(alpha: color.a * 0.35),
          color.withValues(alpha: 0),
        ],
        const [0.0, 0.55, 0.85, 1.0],
      );
      // Overlap strips by half a pixel so vertical seams never show a hairline.
      canvas.drawRect(
        Rect.fromLTWH(0, y - 0.25, barW, stripH + 0.5),
        paint,
      );
    }

    canvas.restore();
  }

  /// 5-tap [1,2,3,2,1] box blur along the density series so day jumps ease
  /// into neighboring commits instead of hard plateaus.
  List<double> _smoothDensity(List<double> raw) {
    final n = raw.length;
    if (n <= 2) return List<double>.from(raw);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final i0 = i > 1 ? i - 2 : 0;
      final i1 = i > 0 ? i - 1 : 0;
      final i3 = i < n - 1 ? i + 1 : n - 1;
      final i4 = i < n - 2 ? i + 2 : n - 1;
      out[i] =
          (raw[i0] + 2 * raw[i1] + 3 * raw[i] + 2 * raw[i3] + raw[i4]) / 9.0;
    }
    return out;
  }

  /// Linear sample of density at a continuous row index (may be fractional).
  double _sampleDensity(List<double> d, double rowPos) {
    if (d.isEmpty) return 0;
    if (d.length == 1) return d.first;
    final x = rowPos.clamp(0.0, (d.length - 1).toDouble());
    final i0 = x.floor();
    final i1 = math.min(d.length - 1, i0 + 1);
    final f = x - i0;
    return d[i0] * (1 - f) + d[i1] * f;
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
