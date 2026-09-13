// The shared chip strip: cap the chips, collapse the rest into `+N`, and adapt
// to the row it is in.
//
// History arrived at this shape first (`RefChipStrip`), and the worktree rows
// needed the same rule, so the arithmetic was extracted rather than copied
// (MADR 0049, plan deviation (a)). Both shapes are guarded here because
// getting the wrong one is how each surface breaks: intrinsic chips squeeze a
// flexible name, and flexible chips in a min-sized strip collapse to nothing.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/common/chip_strip.dart';
import 'package:remote_magic_git/features/common/label_chip.dart';

ChipEntry _entry(String label) => (
  chip: LabelChip(label, color: MacosColors.systemBlueColor),
  tooltip: 'the full $label',
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MacosApp(
    debugShowCheckedModeBanner: false,
    home: MacosWindow(child: Center(child: child)),
  ),
);

Widget _strip(
  List<String> labels, {
  int maxVisible = 2,
  bool chipsMayShrink = false,
}) => ChipStrip(
  maxVisible: maxVisible,
  chipsMayShrink: chipsMayShrink,
  entries: [for (final l in labels) _entry(l)],
  overflowChipBuilder: (hidden, hiddenTooltip) => LabelChip(
    '+$hidden',
    color: MacosColors.systemGrayColor,
    tooltip: hiddenTooltip,
  ),
);

void main() {
  testWidgets('within the cap, every chip is shown and there is no +N', (
    tester,
  ) async {
    await _pump(tester, _strip(['one', 'two']));

    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('beyond the cap, the rest collapse into +N', (tester) async {
    await _pump(tester, _strip(['one', 'two', 'three', 'four']));

    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(find.text('three'), findsNothing);
    expect(find.text('+2'), findsOneWidget);
  });

  testWidgets('the hidden chips are named in the +N tooltip', (tester) async {
    await _pump(tester, _strip(['one', 'two', 'three', 'four']));

    // The +N chip carries the message itself — ChipStrip hands it to the
    // builder rather than wrapping the result, so a self-tooltipping chip
    // (LabelChip) does not end up with two.
    final messages = tester
        .widgetList<MacosTooltip>(
          find.ancestor(
            of: find.text('+2'),
            matching: find.byType(MacosTooltip),
          ),
        )
        .map((t) => t.message)
        .toList();
    expect(
      messages,
      hasLength(1),
      reason: 'the +N chip has $messages tooltips; nested tooltips fight',
    );
    expect(messages.single, contains('the full three'));
    expect(
      messages.single,
      contains('the full four'),
      reason: 'a chip that is hidden must still be readable somewhere',
    );
  });

  testWidgets('an empty strip draws nothing', (tester) async {
    await _pump(tester, _strip(const []));
    expect(find.byType(LabelChip), findsNothing);
  });

  testWidgets('by default the chips keep their own width', (tester) async {
    // History's shape. Asserted structurally, because constraints cannot tell
    // the two shapes apart: a min-sized row inside a sized parent still
    // reports bounded constraints, so an inference here would silently switch
    // History's chips to flexible — the collapse-to-zero its own comment
    // warns about.
    await _pump(tester, _strip(['branch', 'tag']));

    expect(
      find.ancestor(
        of: find.byType(LabelChip).first,
        matching: find.byType(Flexible),
      ),
      findsNothing,
      reason: 'a flex child of a min-sized strip can collapse to zero width',
    );
  });

  testWidgets('a strip that opts in lets its chips give way', (tester) async {
    await _pump(tester, _strip(['branch', 'tag'], chipsMayShrink: true));

    expect(
      find.ancestor(
        of: find.byType(LabelChip).first,
        matching: find.byType(Flexible),
      ),
      findsWidgets,
    );
  });

  testWidgets('opted in, the chips ellipsize instead of overflowing a row', (
    tester,
  ) async {
    // The worktree shape: a name that flexes beside the strip, in 240 pt.
    await _pump(
      tester,
      SizedBox(
        width: 240,
        child: Row(
          children: [
            const Flexible(
              flex: 2,
              child: Text(
                'a-very-long-worktree-name-that-wants-the-room',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Flexible(
              child: _strip([
                'a-long-branch-name-here',
                'locked',
              ], chipsMayShrink: true),
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
