import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/features/common/section_collapse.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('CollapsedSections provider', () {
    test('provider starts empty', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(collapsedSectionsProvider);
      expect(state, isEmpty);
    });

    test('toggle adds a section', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(collapsedSectionsProvider.notifier);
      expect(notifier.isCollapsed('branches.local'), isFalse);

      await notifier.toggle('branches.local');

      expect(container.read(collapsedSectionsProvider), {'branches.local'});
      expect(notifier.isCollapsed('branches.local'), isTrue);
    });

    test('toggle removes a section that was already collapsed', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(collapsedSectionsProvider.notifier);
      await notifier.toggle('branches.local');
      await notifier.toggle('branches.local');

      expect(container.read(collapsedSectionsProvider), isEmpty);
      expect(notifier.isCollapsed('branches.local'), isFalse);
    });

    test('toggle persists to SharedPreferences', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(collapsedSectionsProvider.notifier).toggle('issues');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('collapsedSections'), contains('issues'));
    });

    test('toggle multiple distinct sections', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(collapsedSectionsProvider.notifier);
      await notifier.toggle('branches.local');
      await notifier.toggle('issues');

      expect(container.read(collapsedSectionsProvider), {
        'branches.local',
        'issues',
      });
    });
  });

  group('CollapseChevron', () {
    testWidgets('shows right chevron when collapsed', (tester) async {
      await tester.pumpWidget(const MacosApp(home: CollapseChevron(true)));

      expect(find.byType(MacosIcon), findsOneWidget);
    });

    testWidgets('shows down chevron when not collapsed', (tester) async {
      await tester.pumpWidget(const MacosApp(home: CollapseChevron(false)));

      expect(find.byType(MacosIcon), findsOneWidget);
    });
  });

  group('CollapsibleSectionHeader', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(
        const MacosApp(home: CollapsibleSectionHeader('Branches')),
      );

      expect(find.text('Branches'), findsOneWidget);
    });

    testWidgets('shows count when provided', (tester) async {
      await tester.pumpWidget(
        const MacosApp(home: CollapsibleSectionHeader('Branches', count: '12')),
      );

      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('shows trailing widgets', (tester) async {
      await tester.pumpWidget(
        const MacosApp(
          home: CollapsibleSectionHeader(
            'Branches',
            trailing: [Text('action')],
          ),
        ),
      );

      expect(find.text('action'), findsOneWidget);
    });

    testWidgets('shows caption alongside count', (tester) async {
      await tester.pumpWidget(
        const MacosApp(
          home: CollapsibleSectionHeader(
            'Labels',
            count: '12',
            caption: 'view only',
          ),
        ),
      );

      // Deliberately separate slots: folding the note into `count` would make
      // every count assertion in the forge tests brittle.
      expect(find.text('12'), findsOneWidget);
      expect(find.text('view only'), findsOneWidget);
    });

    testWidgets(
      'pins trailing actions to the right margin at any title length',
      (tester) async {
        const paneWidth = 400.0;
        // The default padding's right inset, where every cluster must end.
        const rightEdge = paneWidth - 8;
        const headers = [
          ('Issues', null, null),
          ('Pull Requests', '12', null),
          ('Labels', '30 of 974', 'view only'),
          ('Workflow Runs', null, null),
        ];
        await tester.pumpWidget(
          MacosApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: paneWidth,
                child: Column(
                  children: [
                    for (final (title, count, caption) in headers)
                      CollapsibleSectionHeader(
                        title,
                        count: count,
                        caption: caption,
                        collapsed: false,
                        onToggle: () {},
                        trailing: [
                          SizedBox(key: ValueKey(title), width: 20, height: 20),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );

        for (final (title, _, _) in headers) {
          expect(
            tester.getRect(find.byKey(ValueKey(title))).right,
            rightEdge,
            reason: '"$title" header actions drifted off the right margin',
          );
        }
      },
    );
  });
}
