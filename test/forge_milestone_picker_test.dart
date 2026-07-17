// The milestone picker keys its popup items on the milestone id. A missing id
// now parses to null (not a fabricated 0), and the picker must skip null-id
// entries — otherwise two id-less milestones would share one popup key and trip
// MacosPopupButton's duplicate-value assertion, and an unkeyable milestone
// would be un-selectable anyway.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/forge/forge_dashboard.dart';
import 'package:remote_magic_git/features/forge/forge_create_sheet_widgets.dart';

Future<void> _pump(
  WidgetTester tester,
  List<ForgeMilestone> milestones, {
  int? value,
}) async {
  await tester.pumpWidget(
    MacosApp(
      debugShowCheckedModeBanner: false,
      home: MacosWindow(
        child: MacosScaffold(
          children: [
            ContentArea(
              builder: (_, _) => Center(
                child: ForgeMilestonePicker(
                  milestones,
                  value: value,
                  onChanged: (_) {},
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('two id-less milestones do not crash the popup', (tester) async {
    await _pump(tester, const [
      ForgeMilestone(id: null, title: 'Ghost A', state: 'active'),
      ForgeMilestone(id: null, title: 'Ghost B', state: 'active'),
    ]);
    // The old fabricated-0 ids gave both items value 0 → duplicate-value
    // assertion during build. Filtering null ids leaves only "None".
    expect(tester.takeException(), isNull);
    expect(find.text('None'), findsOneWidget);
  });

  testWidgets('an id-less milestone is not offered; a real one is', (
    tester,
  ) async {
    await _pump(tester, const [
      ForgeMilestone(id: null, title: 'Ghost', state: 'active'),
      ForgeMilestone(id: 7, title: 'Real', state: 'active'),
    ]);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('None')); // open the menu
    await tester.pumpAndSettle();
    expect(find.text('Real'), findsOneWidget);
    expect(find.text('Ghost'), findsNothing);
  });
}
