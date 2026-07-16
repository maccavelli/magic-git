import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/contribution_stats.dart';

/// A GitHub-style contribution heatmap: one cell per day, [ContributionStats.weeks]
/// columns of 7 days (Sun→Sat), shaded by **relative** daily commit volume so the
/// busiest day is the darkest. Streaks are intentionally not shown, and nothing
/// here frames activity as a productivity measure — it's a calendar of when the
/// repo saw work, no more.
///
/// Purely additive and self-contained: it takes commit author dates and paints.
/// Aggregation is [computeContributionStats] (pure, tested); this widget only
/// lays the grid out and handles hover.
class ContributionHeatmap extends StatefulWidget {
  /// Commit author dates (any `DateTime`; only the calendar day is used).
  final List<DateTime> commitDays;

  /// Reference "today" — the grid ends on the week containing it. Defaults to
  /// the current date; injectable for deterministic tests/screenshots.
  final DateTime? today;

  /// Number of week columns (default ≈ one year).
  final int weeks;

  const ContributionHeatmap({
    super.key,
    required this.commitDays,
    this.today,
    this.weeks = 53,
  });

  @override
  State<ContributionHeatmap> createState() => _ContributionHeatmapState();
}

// Layout geometry, shared by the painter and hit-testing so they agree.
const double _cell = 11;
const double _gap = 2.5;
const double _step = _cell + _gap;
const double _monthLabelH = 15;

/// Empty and 1..4 intensity fills — a cool slate→indigo→teal ramp that matches
/// the history minimap's volume ramp and avoids green (HEAD) / orange (tags).
const Color _empty = Color(0x14FFFFFF);
const List<Color> _levelFills = [
  Color(0xFF1F3A4D), // 1 — dim slate-blue
  Color(0xFF255E7A), // 2
  Color(0xFF3E92B8), // 3
  Color(0xFF64D2FF), // 4 — app teal (busiest)
];

Color _fillForLevel(int level) => level <= 0 ? _empty : _levelFills[level - 1];

class _ContributionHeatmapState extends State<ContributionHeatmap> {
  int? _hovered; // flat day index under the pointer

  ContributionStats _stats() => computeContributionStats(
    widget.commitDays,
    today: widget.today ?? DateTime.now(),
    weeks: widget.weeks,
  );

  int? _hitTest(Offset local, ContributionStats stats) {
    final x = local.dx;
    final y = local.dy - _monthLabelH;
    if (y < 0) return null;
    final week = x ~/ _step;
    final weekday = y ~/ _step;
    if (week < 0 || week >= stats.weeks || weekday < 0 || weekday > 6) {
      return null;
    }
    // Ignore the gap gutters — only count a hit inside the cell body.
    if (x - week * _step > _cell || y - weekday * _step > _cell) return null;
    return week * 7 + weekday;
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats();
    final width = stats.weeks * _step;
    const height = _monthLabelH + 7 * _step;
    final typo = MacosTheme.of(context).typography;

    final caption = _caption(stats);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: MouseRegion(
            onHover: (e) {
              final idx = _hitTest(e.localPosition, stats);
              if (idx != _hovered) setState(() => _hovered = idx);
            },
            onExit: (_) {
              if (_hovered != null) setState(() => _hovered = null);
            },
            child: CustomPaint(
              size: Size(width, height),
              painter: _HeatmapPainter(
                stats: stats,
                hovered: _hovered,
                labelColor: MacosColors.systemGrayColor,
                labelStyle: typo.caption2.copyWith(
                  color: MacosColors.systemGrayColor,
                  fontSize: 9,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          caption,
          style: typo.caption1.copyWith(color: MacosColors.systemGrayColor),
        ),
      ],
    );
  }

  String _caption(ContributionStats stats) {
    final total = stats.countsByDay.fold<int>(0, (a, b) => a + b);
    final idx = _hovered;
    if (idx == null) {
      return '$total ${total == 1 ? 'contribution' : 'contributions'} in the last year';
    }
    final count = stats.countsByDay[idx];
    final day = stats.start.add(Duration(days: idx));
    final date = '${day.year}-${_two(day.month)}-${_two(day.day)}';
    if (count == 0) return 'No contributions on $date';
    return '$count ${count == 1 ? 'contribution' : 'contributions'} on $date';
  }
}

String _two(int n) => n < 10 ? '0$n' : '$n';

const List<String> _monthAbbr = [
  '',
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class _HeatmapPainter extends CustomPainter {
  final ContributionStats stats;
  final int? hovered;
  final Color labelColor;
  final TextStyle labelStyle;

  _HeatmapPainter({
    required this.stats,
    required this.hovered,
    required this.labelColor,
    required this.labelStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..style = PaintingStyle.fill;

    // Month labels above the columns: draw an abbreviation at the first column
    // whose Sunday falls in a new month.
    var lastMonth = -1;
    for (var w = 0; w < stats.weeks; w++) {
      final colDay = stats.start.add(Duration(days: w * 7));
      if (colDay.month != lastMonth && colDay.day <= 7) {
        lastMonth = colDay.month;
        final tp = TextPainter(
          text: TextSpan(text: _monthAbbr[colDay.month], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(w * _step, 0));
      }
    }

    for (var w = 0; w < stats.weeks; w++) {
      for (var d = 0; d < 7; d++) {
        final idx = w * 7 + d;
        final count = stats.countsByDay[idx];
        final level = stats.levelFor(count);
        fill.color = _fillForLevel(level);
        final rect = Rect.fromLTWH(
          w * _step,
          _monthLabelH + d * _step,
          _cell,
          _cell,
        );
        final rr = RRect.fromRectAndRadius(rect, const Radius.circular(2));
        canvas.drawRRect(rr, fill);
        if (idx == hovered) {
          canvas.drawRRect(
            rr,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..color = MacosColors.white.withValues(alpha: 0.8),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.stats != stats || old.hovered != hovered;
}
