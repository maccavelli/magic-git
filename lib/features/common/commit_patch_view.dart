import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/unified_diff.dart';
import '../../core/providers/app_providers.dart';
import 'diff_view.dart';
import 'patch_model.dart';

/// A commit's patch with **inline context expanders**: the `⋯` rows between
/// hunks reveal the code git left out (it emits only three context lines, so a
/// hunk routinely ends mid-expression and reads as if the diff were cut off).
///
/// Structurally this mirrors [DiffView] — one fixed-height row per line, a
/// single shared horizontal scroll so every line's tail is reachable, one
/// [SelectionArea] over the lot — because that shape is already proven here.
/// What it adds is a typed row model, so a row can be an interactive expander
/// rather than only text.
///
/// Expansion reads the file as the commit left it ([blobLinesProvider]) and
/// splices those lines in as context — but only after
/// [verifyBlobMatchesHunks] confirms the blob really is the one the hunks were
/// computed against. If it isn't, this shows the patch unexpanded rather than
/// render lines it cannot vouch for.
class CommitPatchView extends ConsumerStatefulWidget {
  final String repoPath;

  /// The commit whose post-image the expanders read from.
  final String hash;

  /// The raw `git show` output.
  final String diff;

  final bool wrap;

  const CommitPatchView({
    super.key,
    required this.repoPath,
    required this.hash,
    required this.diff,
    this.wrap = false,
  });

  @override
  ConsumerState<CommitPatchView> createState() => _CommitPatchViewState();
}

class _CommitPatchViewState extends ConsumerState<CommitPatchView> {
  static const double _hPad = 12;

  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  /// How far each gap has been opened. Keyed by (file, gap) so it survives the
  /// rebuild an expansion itself triggers; cleared when the commit changes.
  Map<ExpandRequest, GapExpansion> _expansions = {};

  /// Files whose blob the user has actually asked for. Fetching every file's
  /// blob up front would be a command per file on every commit selection — so
  /// a file's blob is only fetched once its expander is clicked.
  Set<int> _wanted = {};

  late CommitPatch _patch = parseCommitPatch(widget.diff);

  @override
  void didUpdateWidget(CommitPatchView old) {
    super.didUpdateWidget(old);
    if (old.diff != widget.diff) {
      _patch = parseCommitPatch(widget.diff);
    }
    if (old.hash != widget.hash) {
      // A different commit: its gaps and blobs have nothing to do with the
      // previous one's.
      _expansions = {};
      _wanted = {};
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// The post-image lines for [fileIndex], or null when they aren't available:
  /// not requested, still loading, failed, or — the case that matters — a blob
  /// that doesn't match the hunks, which must never be spliced.
  List<String>? _blobFor(int fileIndex) {
    if (!_wanted.contains(fileIndex)) return null;
    final file = _patch.files[fileIndex];
    final path = file.newPath;
    if (!file.canExpand || path == null) return null;

    final async = ref.watch(
      blobLinesProvider((widget.repoPath, widget.hash, path)),
    );
    final lines = async.value;
    if (lines == null) return null;
    // The check that stops this lying: if the blob isn't the one these hunks
    // were computed against, splicing it would inject unrelated source lines
    // into the diff and present them as real.
    if (!verifyBlobMatchesHunks(file, lines)) return null;
    return lines;
  }

  void _expand(ExpandRequest request, ExpandDirection direction, int gapSize) {
    setState(() {
      _wanted = {..._wanted, request.fileIndex};
      final current = _expansions[request] ?? const GapExpansion();
      _expansions = {
        ..._expansions,
        request: current.plus(direction, gapSize),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.diff.trim().isEmpty) {
      return Center(
        child: Text('No changes', style: MacosTheme.of(context).typography.body),
      );
    }

    final blobs = <int, List<String>?>{
      for (var i = 0; i < _patch.files.length; i++) i: _blobFor(i),
    };
    final rows = buildPatchRows(
      _patch,
      expansions: _expansions,
      blobs: blobs,
    );

    final defaultColor =
        MacosTheme.of(context).typography.body.color ?? MacosColors.textColor;

    return widget.wrap
        ? _buildList(rows, defaultColor, null)
        : LayoutBuilder(
            builder: (context, constraints) {
              final lineWidth = _measureMaxWidth(rows) + _hPad * 2;
              final overflows = lineWidth > constraints.maxWidth;
              final contentWidth = math.max(constraints.maxWidth, lineWidth);
              return Scrollbar(
                controller: _vertical,
                notificationPredicate: (n) => n.depth == 1,
                child: Scrollbar(
                  controller: _horizontal,
                  thumbVisibility: overflows,
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: contentWidth,
                      height: constraints.maxHeight,
                      child: _buildList(rows, defaultColor, contentWidth),
                    ),
                  ),
                ),
              );
            },
          );
  }

  Widget _buildList(List<PatchRow> rows, Color defaultColor, double? width) {
    return SelectionArea(
      child: ListView.builder(
        controller: _vertical,
        padding: const EdgeInsets.symmetric(vertical: 12),
        // Fixed extent in the unwrapped case only — a wrapped line's height is
        // its own business. Every row (expanders included) is one line tall, so
        // the O(1) scroll math holds.
        itemExtent: widget.wrap ? null : kDiffLineExtent,
        itemCount: rows.length,
        itemBuilder: (context, index) =>
            _row(rows[index], defaultColor),
      ),
    );
  }

  Widget _row(PatchRow row, Color defaultColor) => switch (row) {
    ExpanderRow() => _expander(row),
    PreambleRow(:final text) ||
    FileHeaderRow(:final text) ||
    HunkHeaderRow(:final text) ||
    CodeRow(:final text) => _text(text, defaultColor, row),
  };

  Widget _text(String text, Color defaultColor, PatchRow row) {
    // An expanded line is unchanged code: color it as context, and tint its
    // background faintly so it reads as "revealed", not "part of the change".
    final expanded = row is CodeRow && row.fromExpansion;
    return Container(
      color: expanded ? const Color(0x0DFFFFFF) : null,
      padding: const EdgeInsets.symmetric(horizontal: _hPad),
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        maxLines: widget.wrap ? null : 1,
        softWrap: widget.wrap,
        style: kDiffMono.copyWith(color: diffLineColor(text, defaultColor)),
      ),
    );
  }

  /// The `⋯` row. Arrows walk the gap [kExpandStep] lines at a time; a gap
  /// small enough to swallow whole offers a single click instead.
  Widget _expander(ExpanderRow row) {
    final hidden = row.hiddenLines;
    final gapSize = hidden ?? kExpandStep;
    final label = hidden == null
        ? 'Show more'
        : (row.canAll && hidden <= kSmallGapThreshold
              ? 'Show $hidden ${hidden == 1 ? "line" : "lines"}'
              : '$hidden hidden lines');

    // The whole row is the target, not just the arrows — a 11px chevron is a
    // miserable thing to hit. Clicking the row does the obvious thing: swallow
    // a small gap whole, otherwise walk it from the nearest end.
    final rowAction = row.canAll && hidden != null
        ? ExpandDirection.all
        : (row.canDown ? ExpandDirection.down : ExpandDirection.up);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _expand(row.request, rowAction, gapSize),
        child: Container(
          color: const Color(0x14007AFF),
          padding: const EdgeInsets.symmetric(horizontal: _hPad),
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (row.canUp)
                _expandButton(
                  CupertinoIcons.chevron_up,
                  'Show $kExpandStep lines above',
                  () => _expand(row.request, ExpandDirection.up, gapSize),
                ),
              if (row.canDown)
                _expandButton(
                  CupertinoIcons.chevron_down,
                  'Show $kExpandStep lines below',
                  () => _expand(row.request, ExpandDirection.down, gapSize),
                ),
              const SizedBox(width: 6),
              Text(
                label,
                style: kDiffMono.copyWith(
                  color: MacosColors.systemBlueColor,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _expandButton(IconData icon, String tooltip, VoidCallback onTap) =>
      MacosTooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: MacosIcon(
                icon,
                size: 11,
                color: MacosColors.systemBlueColor,
              ),
            ),
          ),
        ),
      );

  /// Widest row, measured on the single longest line — same approach (and same
  /// monospace assumption) as [DiffView].
  double _measureMaxWidth(List<PatchRow> rows) {
    var longest = '';
    for (final row in rows) {
      final text = switch (row) {
        PreambleRow(:final text) ||
        FileHeaderRow(:final text) ||
        HunkHeaderRow(:final text) ||
        CodeRow(:final text) => text,
        ExpanderRow() => '',
      };
      if (text.length > longest.length) longest = text;
    }
    if (longest.isEmpty) return 0;
    return (TextPainter(
      text: TextSpan(text: longest, style: kDiffMono),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout()).width;
  }
}
