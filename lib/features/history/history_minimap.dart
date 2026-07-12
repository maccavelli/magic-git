import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/commit_graph.dart';
import '../../core/git/git_service.dart';

/// An annotated scroll track beside the commit list: a viewport band you can
/// click or scrub, plus per-commit markers for HEAD / branches / tags and
/// the current selection. The GitLens-research verdict distilled — the
/// markers-and-jump half of a minimap carries nearly all the utility; the
/// activity histogram half is decoration, deliberately omitted.
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

  const HistoryMinimap({
    super.key,
    required this.controller,
    required this.metricsTick,
    required this.graph,
    required this.decorations,
    required this.selected,
  });

  static const double width = 14;

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

  _MinimapPainter({
    required this.controller,
    required Listenable metricsTick,
    required this.graph,
    required this.decorations,
    required this.selected,
  }) : super(repaint: Listenable.merge([controller, metricsTick]));

  @override
  void paint(Canvas canvas, Size size) {
    final rows = graph.rows;
    if (rows.isEmpty || size.height <= 0) return;

    // Track background.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0x10FFFFFF),
    );

    double yFor(int index) => (index + 0.5) / rows.length * size.height;

    // Ref markers (left-inset ticks) and selection markers (right-inset), so
    // a selected, decorated row shows both side by side.
    final tick = Paint();
    for (var i = 0; i < rows.length; i++) {
      final hash = rows[i].commit.hash;
      final color = _refColor(decorations[hash]);
      final y = yFor(i);
      if (color != null) {
        tick.color = color;
        canvas.drawRect(Rect.fromLTRB(1.5, y - 1, size.width * 0.6, y + 1), tick);
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
        canvas.drawRRect(band, Paint()..color = const Color(0x22FFFFFF));
        canvas.drawRRect(
          band,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0x66FFFFFF),
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
      oldDelegate.selected != selected;
}
