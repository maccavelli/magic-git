import 'package:flutter/widgets.dart';

/// One chip and the text that describes it in full.
///
/// The tooltip is what the strip shows for chips it hides, so it must stand on
/// its own — "Locked: cutting the release", not "locked".
typedef ChipEntry = ({Widget chip, String tooltip});

/// A row of status chips that never grows past what it was given: at most
/// [maxVisible] chips, with the remainder collapsed into one `+N` chip whose
/// tooltip lists what it swallowed.
///
/// Extracted from History's ref-chip strip, which arrived at this shape the
/// hard way, and which carries the two rules that make it work:
///
/// * **The chips are intrinsic; they do not flex.** This is a min-sized row,
///   and a flex child of a min-sized row can collapse to zero width — History's
///   pop-out once rendered subjects with no badges at all for exactly that
///   reason. Each chip bounds *itself* (see `LabelChip.maxWidth`) and
///   ellipsizes inside that bound.
/// * **The row's subject flexes instead.** The strip sits beside a name or a
///   commit subject that takes the remaining space, so capping the chips is
///   what keeps the subject legible.
///
/// Without the cap, a row with five states and a long branch name is wider than
/// any pane it can be dragged to — and a `Flex` paints its overflow *outside*
/// its bounds, over whatever is next to it (MADR 0049).
class ChipStrip extends StatelessWidget {
  const ChipStrip({
    super.key,
    required this.entries,
    required this.overflowChipBuilder,
    this.maxVisible = 2,
    this.chipsMayShrink = false,
  }) : assert(maxVisible > 0, 'a strip that shows nothing is a hidden row');

  /// Chips in priority order: the ones that matter most survive the cap.
  final List<ChipEntry> entries;

  /// Builds the `+N` chip from the number hidden and the text naming them.
  ///
  /// The strip hands the message over rather than wrapping the result in a
  /// tooltip of its own: chips explain themselves now (see `LabelChip.tooltip`),
  /// and a wrapper here would nest two tooltips on the same chip.
  final Widget Function(int hidden, String hiddenTooltip) overflowChipBuilder;

  /// Beyond this, chips collapse. Two is what leaves a readable subject in a
  /// narrow pane; a caller with more room may raise it.
  final int maxVisible;

  /// Whether the chips may give way to a subject sharing their row.
  ///
  /// **Off by default, deliberately.** History's strip is min-sized and
  /// right-aligned: a flex child there can collapse to zero width, which once
  /// rendered commit subjects with no badges at all. Only a strip that shares a
  /// *bounded* row with a flexible subject — a worktree row's name — turns this
  /// on, and it is stated by the caller rather than inferred from constraints,
  /// because the two shapes are not distinguishable that way: a min-sized row
  /// inside a sized parent still reports bounded constraints.
  final bool chipsMayShrink;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();

    final shown = entries.take(maxVisible).toList();
    final hidden = entries.sublist(shown.length);

    // Which of the two shapes this strip is in decides whether its chips may
    // shrink, and getting it backwards is how each one breaks:
    //
    // * **A min-sized or right-aligned strip** (History's): a flex child can
    //   collapse to zero width, so chips stay intrinsic and rely on their own
    //   cap. This is the default.
    // * **A strip sharing a bounded row with a flexible subject** (a worktree
    //   row's name): intrinsic chips hold a fixed slice and squeeze the name —
    //   measured at 46 pt of name in a 240 pt pane, against 97 pt when the
    //   chips give way. Such callers pass [chipsMayShrink].
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in shown)
          if (chipsMayShrink) Flexible(child: entry.chip) else entry.chip,
        // Never flexible: it is a handful of pixels and the only sign that
        // anything was hidden.
        if (hidden.isNotEmpty)
          overflowChipBuilder(
            hidden.length,
            hidden.map((e) => e.tooltip).join('\n'),
          ),
      ],
    );
  }
}
