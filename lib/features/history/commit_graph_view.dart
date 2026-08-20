import 'package:flutter/material.dart';
import '../../core/git/commit_graph.dart';
import '../../core/theme/app_theme.dart';

/// Lane palette — distinct, reused cyclically by lane index.
const _laneColors = <Color>[
  Color(0xFF4C8DFF), // blue
  Color(0xFF34C759), // green
  Color(0xFFFF9F0A), // orange
  Color(0xFFAF52DE), // purple
  Color(0xFFFF453A), // red
  Color(0xFF64D2FF), // teal
  Color(0xFFFFD60A), // yellow
  Color(0xFFFF375F), // pink
];

Color laneColor(int lane) => _laneColors[lane % _laneColors.length];

const double kLaneWidth = 16;
const double kGraphRowHeight = 52;
const double _dotRadius = 4.5;

double _laneX(int column, double laneWidth) =>
    laneWidth / 2 + column * laneWidth;

/// Paints the lane lines and node for a single [GraphRow].
///
/// [laneWidth] defaults to [kLaneWidth] but callers laying out a row whose
/// graph has more concurrent lanes than comfortably fit the allotted band
/// (e.g. many long-lived branches active at once) pass a narrower value so
/// every lane is compressed to fit — an ugly-but-visible rendering beats
/// silently clipping the overflow lanes away.
class CommitRowPainter extends CustomPainter {
  final GraphRow row;
  final double laneWidth;

  /// The History zoom factor — scales the node dot and stroke weight so the
  /// graph reads at the same visual weight at every density (lane spacing
  /// and row height are scaled by the caller through [laneWidth] and the
  /// painted size).
  final double scale;

  const CommitRowPainter(
    this.row, {
    this.laneWidth = kLaneWidth,
    this.scale = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const topY = 0.0;
    final midY = size.height / 2;
    final botY = size.height;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * scale
      ..strokeCap = StrokeCap.round;

    for (final edge in row.edges) {
      final baseColor = laneColor(edge.colorLane);
      stroke.color = edge.isMergeEdge
          ? baseColor.withValues(alpha: 0.85)
          : baseColor;
      stroke.strokeWidth = edge.isMergeEdge ? 1.4 * scale : 1.8 * scale;
      final (Offset a, Offset b) = switch (edge.kind) {
        GraphEdgeKind.pass => (
          Offset(_laneX(edge.fromColumn, laneWidth), topY),
          Offset(_laneX(edge.toColumn, laneWidth), botY),
        ),
        GraphEdgeKind.toNode => (
          Offset(_laneX(edge.fromColumn, laneWidth), topY),
          Offset(_laneX(edge.toColumn, laneWidth), midY),
        ),
        GraphEdgeKind.fromNode => (
          Offset(_laneX(edge.fromColumn, laneWidth), midY),
          Offset(_laneX(edge.toColumn, laneWidth), botY),
        ),
      };
      _drawSegment(canvas, stroke, a, b);
    }

    // Node.
    final center = Offset(_laneX(row.column, laneWidth), midY);
    canvas.drawCircle(
      center,
      _dotRadius * scale,
      Paint()..color = laneColor(row.column),
    );
    canvas.drawCircle(
      center,
      _dotRadius * scale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * scale
        ..color = AppTheme.terminalBackground,
    );
  }

  void _drawSegment(Canvas canvas, Paint paint, Offset a, Offset b) {
    if (a.dx == b.dx) {
      canvas.drawLine(a, b, paint);
      return;
    }
    // Smooth S-curve for diagonal transitions between lanes.
    final midY = (a.dy + b.dy) / 2;
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(a.dx, midY, b.dx, midY, b.dx, b.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CommitRowPainter oldDelegate) =>
      oldDelegate.row != row ||
      oldDelegate.laneWidth != laneWidth ||
      oldDelegate.scale != scale;
}
