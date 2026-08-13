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
      await tester.pumpWidget(
        const MacosApp(
          home: CollapseChevron(true),
        ),
      );

      expect(find.byType(MacosIcon), findsOneWidget);
    });

    testWidgets('shows down chevron when not collapsed', (tester) async {
      await tester.pumpWidget(
        const MacosApp(
          home: CollapseChevron(false),
        ),
      );

      expect(find.byType(MacosIcon), findsOneWidget);
    });
  });

  group('CollapsibleSectionHeader', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(
        const MacosApp(
          home: CollapsibleSectionHeader('Branches'),
        ),
      );

      expect(find.text('Branches'), findsOneWidget);
    });

    testWidgets('shows count when provided', (tester) async {
      await tester.pumpWidget(
        const MacosApp(
          home: CollapsibleSectionHeader('Branches', count: '12'),
        ),
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
  });
}
