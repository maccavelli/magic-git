import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/repository_workspace_prefs.dart';
import 'package:remote_magic_git/features/common/adaptive_workspace_layout.dart';
import 'package:remote_magic_git/features/common/resizable_master_detail.dart';

void main() {
  test('adaptive arrangement pins the documented defaults', () {
    const prefs = RepositoryWorkspacePrefs(inspectorPinned: true);
    final compact = resolveAdaptiveWorkspaceArrangement(
      width: 640,
      preferences: prefs,
      hasInspector: true,
      inspectorVisible: true,
      taskDockFocused: false,
    );
    final standard = resolveAdaptiveWorkspaceArrangement(
      width: 900,
      preferences: prefs,
      hasInspector: true,
      inspectorVisible: true,
      taskDockFocused: false,
    );
    final wide = resolveAdaptiveWorkspaceArrangement(
      width: 1300,
      preferences: prefs,
      hasInspector: true,
      inspectorVisible: true,
      taskDockFocused: false,
    );

    expect(compact.navigatorAndCanvas, isFalse);
    expect(compact.inspectorOverlay, isTrue);
    expect(compact.taskDock, WorkspaceTaskDockPresentation.hidden);
    expect(standard.navigatorAndCanvas, isTrue);
    expect(standard.inspectorOverlay, isTrue);
    expect(standard.pinnedInspector, isFalse);
    expect(standard.taskDock, WorkspaceTaskDockPresentation.compact);
    expect(wide.pinnedInspector, isTrue);
    expect(wide.taskDock, WorkspaceTaskDockPresentation.full);
  });

  test(
    'collapsed inspector remains absent even when requested by the screen',
    () {
      const prefs = RepositoryWorkspacePrefs(
        inspectorPinned: true,
        inspectorCollapsed: true,
      );
      final arrangement = resolveAdaptiveWorkspaceArrangement(
        width: 1400,
        preferences: prefs,
        hasInspector: true,
        inspectorVisible: true,
        taskDockFocused: false,
      );

      expect(arrangement.inspectorOverlay, isFalse);
      expect(arrangement.pinnedInspector, isFalse);
    },
  );

  testWidgets('minimal preset forces canvas in compact layout', (tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MacosApp(
        home: SizedBox(
          width: 640,
          height: 480,
          child: AdaptiveWorkspaceLayout(
            navigator: const SizedBox(key: Key('navigator')),
            canvas: const SizedBox(key: Key('canvas')),
            compactPage: CompactWorkspacePage.navigator,
            preferences: applyWorkspacePreset(
              const RepositoryWorkspacePrefs(),
              WorkspacePreset.minimal,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('navigator')), findsNothing);
    expect(find.byKey(const Key('canvas')), findsOneWidget);
  });

  testWidgets(
    'compact shows one primary pane and can switch without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MacosApp(
          home: SizedBox(
            width: 640,
            height: 480,
            child: AdaptiveWorkspaceLayout(
              navigator: Container(key: const Key('navigator')),
              canvas: Container(key: const Key('canvas')),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('navigator')), findsNothing);
      expect(find.byKey(const Key('canvas')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('divider keyboard adjustment commits 16 pixels', (tester) async {
    double? committed;
    await tester.pumpWidget(
      MacosApp(
        home: SizedBox(
          width: 900,
          height: 500,
          child: ResizablePanePair(
            leading: const SizedBox(key: Key('leading')),
            trailing: const SizedBox(key: Key('trailing')),
            extent: 320,
            minExtent: 240,
            maxExtent: 600,
            trailingFloor: 280,
            defaultExtent: 320,
            semanticLabel: 'Resize repository navigator',
            onCommit: (value) => committed = value,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(committed, 336);
    expect(tester.getSize(find.byKey(const Key('leading'))).width, 336);
  });

  testWidgets('collapse preserves the prior extent when reopened', (
    tester,
  ) async {
    final collapsed = ValueNotifier(false);
    addTearDown(collapsed.dispose);
    await tester.pumpWidget(
      MacosApp(
        home: SizedBox(
          width: 900,
          height: 500,
          child: ValueListenableBuilder<bool>(
            valueListenable: collapsed,
            builder: (context, value, _) => ResizablePanePair(
              leading: const SizedBox(key: Key('leading')),
              trailing: const SizedBox(),
              extent: 410,
              minExtent: 240,
              maxExtent: 600,
              trailingFloor: 280,
              defaultExtent: 320,
              collapsed: value,
              onCommit: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('leading'))).width, 410);
    collapsed.value = true;
    await tester.pump();
    expect(find.byKey(const Key('leading')), findsNothing);
    collapsed.value = false;
    await tester.pump();
    expect(tester.getSize(find.byKey(const Key('leading'))).width, 410);
  });
}
