import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/hover_pop.dart';
import 'package:remote_magic_git/features/common/inline_action_button.dart';
import 'package:remote_magic_git/features/common/repository_workspace_models.dart';
import 'package:remote_magic_git/features/common/repository_workspace_scaffold.dart';
import 'package:remote_magic_git/features/common/workspace_appearance.dart';
import 'package:remote_magic_git/features/common/workspace_focus_order.dart';

class _AccessibleCompactSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    workspaceDensity: WorkspaceDensity.compact,
    workspaceHighContrast: true,
  );
}

Widget _region(String label) =>
    Center(child: FocusableActionDetector(child: Text(label)));

Widget _workspace({bool disableAnimations = false}) => MacosApp(
  debugShowCheckedModeBanner: false,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: SizedBox(
      width: 1600,
      height: 1000,
      child: RepositoryWorkspaceScaffold(
        repositoryContext: WorkspaceFocusRegion(
          role: WorkspacePaneRole.activity,
          child: _region('context and activity'),
        ),
        navigator: _region('navigator content'),
        canvas: _region('canvas content'),
        inspector: _region('inspector content'),
        taskDock: _region('task dock content'),
        inspectorVisible: true,
        taskDockFocused: true,
        // The dock is opted into explicitly: the default record now carries the
        // Review preset's `taskDockCollapsed: true`, and this harness is about
        // every pane region being reachable, not about that default.
        preferences: const RepositoryWorkspacePrefs(
          inspectorPinned: true,
          taskDockCollapsed: false,
        ),
      ),
    ),
  ),
);

void main() {
  test('workspace roles have one stable focus order', () {
    expect(
      WorkspacePaneRole.values.map(workspacePaneFocusOrder),
      orderedEquals([1, 2, 4, 5, 6, 7]),
    );
  });

  test('direct pane-focus keymap actions are discoverable and unbound', () {
    const ids = {
      'global.focusNavigator',
      'global.focusCanvas',
      'global.focusInspector',
      'global.focusTaskDock',
      'global.focusActivity',
    };
    final actions = kKeymapActions.where((action) => ids.contains(action.id));
    expect(actions.map((action) => action.id).toSet(), ids);
    expect(actions.every((action) => action.defaultBindings.isEmpty), isTrue);
  });

  testWidgets('workspace exposes named semantic regions and direct focus', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_workspace());

    for (final role in WorkspacePaneRole.values) {
      expect(
        find.bySemanticsLabel(workspacePaneSemanticsLabel(role)),
        findsOneWidget,
      );
    }

    expect(
      WorkspacePaneFocusRegistry.instance.request(WorkspacePaneRole.canvas),
      isTrue,
    );
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Repository canvas');
    expect(
      WorkspacePaneFocusRegistry.instance.request(WorkspacePaneRole.inspector),
      isTrue,
    );
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'Repository inspector',
    );
    semantics.dispose();
  });

  testWidgets('inline actions honor target and reduced-motion tokens', (
    tester,
  ) async {
    await tester.pumpWidget(
      MacosApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Center(
            child: InlineActionButton(
              label: 'Retry',
              icon: CupertinoIcons.refresh,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    expect(
      tester
          .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
          .any((box) => box.constraints.minHeight == 28),
      isTrue,
    );
    expect(
      tester
          .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
          .any((container) => container.duration == Duration.zero),
      isTrue,
    );
  });

  testWidgets(
    'prominent hover effects become zero-duration under Reduce Motion',
    (tester) async {
      await tester.pumpWidget(
        const MacosApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Center(
              child: HoverPop(child: SizedBox(width: 80, height: 30)),
            ),
          ),
        ),
      );

      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .duration,
        Duration.zero,
      );
    },
  );

  testWidgets(
    'shared boundary applies compact, high-contrast, and reduced-motion state',
    (tester) async {
      WorkspaceAppearanceData? appearance;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(_AccessibleCompactSettings.new),
          ],
          child: MacosApp(
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: SizedBox(
                width: 1000,
                height: 600,
                child: RepositoryWorkspaceScaffold(
                  repositoryContext: const SizedBox.shrink(),
                  canvas: Builder(
                    builder: (context) {
                      appearance = WorkspaceAppearanceScope.maybeOf(context);
                      return const Text('canvas');
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(appearance, isNotNull);
      expect(appearance!.density, WorkspaceDensity.compact);
      expect(appearance!.highContrast, isTrue);
      expect(appearance!.reduceMotion, isTrue);
      expect(
        appearance!.tokens.palette.border,
        isNot(MacosColors.separatorColor),
      );

      expect(
        WorkspacePaneFocusRegistry.instance.request(WorkspacePaneRole.canvas),
        isTrue,
      );
      await tester.pump();
      expect(
        tester
            .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
            .any((container) {
              final decoration = container.foregroundDecoration;
              return decoration is BoxDecoration &&
                  decoration.border?.top.color ==
                      appearance!.tokens.palette.focus;
            }),
        isTrue,
      );
    },
  );
}
