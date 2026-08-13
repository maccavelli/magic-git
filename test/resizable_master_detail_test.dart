// ResizableMasterDetail: the draggable, persisted master/detail split. Pins
// the interaction contract — drag is local until drag END persists exactly
// once; display-clamping never writes; double-click resets; degenerate
// layouts render without overflow.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/settings/app_settings.dart';
import 'package:remote_magic_git/core/settings/pane_layout.dart';
import 'package:remote_magic_git/features/common/resizable_master_detail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _master = Key('master');
const _detail = Key('detail');

// historyList spec: default 420, min 360, max 800.
const _spec = PaneSpec(defaultWidth: 420, min: 360, max: 800);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  double width = 1100,
  double detailFloor = 280,
  Map<String, Object> prefs = const {},
  bool resetPrefs = true,
}) async {
  // The default 800x600 surface would silently constrain any wider SizedBox —
  // the layout-ceiling tests need the window to actually BE this wide.
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  if (resetPrefs) {
    SharedPreferences.setMockInitialValues(prefs);
  }
  final container = ProviderContainer();
  addTearDown(container.dispose);
  // Let the notifier's async load fold stored prefs in before first layout.
  await container.read(appSettingsProvider.notifier).reloadFromDisk();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox(
          width: width,
          height: 720,
          child: ResizableMasterDetail(
            paneId: PaneId.historyList,
            detailFloor: detailFloor,
            master: Container(key: _master),
            detail: Container(key: _detail),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

double _masterWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(_master)).width;

/// The divider strip's center: the master's right edge is the 1px line's left.
Offset _handleCenter(WidgetTester tester) {
  final master = tester.getRect(find.byKey(_master));
  return Offset(master.right + 0.5, master.top + 300);
}

Future<void> _dragHandle(WidgetTester tester, Offset delta) async {
  final gesture = await tester.startGesture(
    _handleCenter(tester),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the master at the spec default when nothing is stored',
      (tester) async {
    await _pump(tester);
    expect(_masterWidth(tester), _spec.defaultWidth);
  });

  testWidgets('drag resizes live and persists exactly once, on drag end',
      (tester) async {
    await _pump(tester);

    final gesture = await tester.startGesture(
      _handleCenter(tester),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();

    expect(_masterWidth(tester), _spec.defaultWidth + 80, reason: 'live');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getDouble('paneWidth_historyList'),
      isNull,
      reason: 'nothing persisted mid-drag',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_masterWidth(tester), _spec.defaultWidth + 80, reason: 'no snap-back');
    expect(prefs.getDouble('paneWidth_historyList'), _spec.defaultWidth + 80);
  });

  testWidgets('drag past the bounds pins at spec.min and the layout ceiling',
      (tester) async {
    await _pump(tester); // 1100 wide, detailFloor 280

    await _dragHandle(tester, const Offset(-5000, 0));
    expect(_masterWidth(tester), _spec.min);

    await _dragHandle(tester, const Offset(5000, 0));
    // Ceiling = min(spec.max 800, 1100 - 280 - 1 = 819) = 800; the detail
    // keeps at least its floor.
    expect(_masterWidth(tester), _spec.max);
    expect(
      tester.getSize(find.byKey(_detail)).width,
      greaterThanOrEqualTo(280),
    );
  });

  testWidgets('the layout ceiling beats spec.max in a narrower window',
      (tester) async {
    await _pump(tester, width: 900); // ceiling = 900 - 280 - 1 = 619
    await _dragHandle(tester, const Offset(5000, 0));
    expect(_masterWidth(tester), 619);
  });

  testWidgets(
      'an over-wide stored width is display-clamped without being rewritten',
      (tester) async {
    await _pump(
      tester,
      width: 900, // ceiling 619
      prefs: {'paneWidth_historyList': 780.0}, // legal (≤ spec.max), too wide here
    );

    expect(_masterWidth(tester), 619, reason: 'display-clamped');
    await tester.pump(const Duration(seconds: 1));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getDouble('paneWidth_historyList'),
      780.0,
      reason: 'rendering must never write back',
    );
  });

  testWidgets(
      'a temporary narrow window preserves the stored width for a later wide '
      'window', (tester) async {
    const storedWidth = 780.0;
    await _pump(
      tester,
      width: 900,
      prefs: {'paneWidth_historyList': storedWidth},
    );
    expect(_masterWidth(tester), 619, reason: 'narrow display clamp');

    await _pump(tester, width: 1100, resetPrefs: false);
    expect(_masterWidth(tester), storedWidth, reason: 'stored width restored');
  });

  testWidgets('double-click on the divider resets to the spec default and '
      'persists it', (tester) async {
    await _pump(tester, prefs: {'paneWidth_historyList': 500.0});
    expect(_masterWidth(tester), 500);

    final where = _handleCenter(tester);
    await tester.tapAt(where);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(where);
    await tester.pumpAndSettle();

    expect(_masterWidth(tester), _spec.defaultWidth);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('paneWidth_historyList'), _spec.defaultWidth);
  });

  testWidgets('a dragged width survives a simulated restart', (tester) async {
    await _pump(tester);
    await _dragHandle(tester, const Offset(60, 0));
    expect(_masterWidth(tester), _spec.defaultWidth + 60);

    // Fresh container over the same (mock) disk = app relaunch.
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    await fresh.read(appSettingsProvider.notifier).reloadFromDisk();
    expect(
      fresh.read(appSettingsProvider).paneWidth(PaneId.historyList),
      _spec.defaultWidth + 60,
    );
  });

  testWidgets('a degenerate narrow layout renders without overflow',
      (tester) async {
    // 500 < spec.min 360 + floor 280: the ceiling pre-guard must pin at
    // spec.min instead of handing clamp() an inverted range (which throws).
    await _pump(tester, width: 500);
    expect(tester.takeException(), isNull);
    expect(_masterWidth(tester), _spec.min);
  });
}
