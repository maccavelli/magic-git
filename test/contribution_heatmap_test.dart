import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/features/dashboard/contribution_heatmap.dart';

void main() {
  testWidgets('renders a total-contributions caption', (tester) async {
    final today = DateTime(2024, 1, 17);
    final days = [
      DateTime(2024, 1, 17),
      DateTime(2024, 1, 17),
      DateTime(2024, 1, 10),
    ];

    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) =>
                ContributionHeatmap(commitDays: days, today: today),
          ),
        ),
      ),
    );

    expect(find.text('3 contributions in the last year'), findsOneWidget);
  });

  testWidgets('empty history renders without error', (tester) async {
    await tester.pumpWidget(
      MacosApp(
        home: MacosWindow(
          child: ContentArea(
            builder: (_, _) => ContributionHeatmap(
              commitDays: const [],
              today: DateTime(2024, 1, 17),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ContributionHeatmap), findsOneWidget);
    expect(find.text('0 contributions in the last year'), findsOneWidget);
  });
}
