// C1 drag-to-stage: the in-panel banner appears only during a file drag, is
// directional (Stage for an unstaged source, Unstage for a staged one), and
// dispatches the dropped paths to the panel's bulk stage/unstage callbacks.

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/staging_drop_banner.dart';

Future<void> _dragOnto(WidgetTester tester, Finder source, Finder target) async {
  final from = tester.getCenter(source);
  final to = tester.getCenter(target);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 100));
  await gesture.moveBy(const Offset(0, -20)); // exceed touch slop
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester, {
  required DragFiles item,
  required void Function(List<String>) onStage,
  required void Function(List<String>) onUnstage,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MacosApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          children: [
            DragItemDraggable(
              item: item,
              immediate: true,
              child: const SizedBox(
                width: 120,
                height: 44,
                child: Center(child: Text('SOURCE')),
              ),
            ),
            // A fixed slot so the drop point is stable even though the banner
            // itself is zero-size until the drag begins.
            SizedBox(
              key: const Key('banner-slot'),
              width: 320,
              height: 60,
              child: StagingDropBanner(onStage: onStage, onUnstage: onUnstage),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the banner is hidden until a file drag starts', (tester) async {
    await _pump(
      tester,
      item: const DragFiles(['lib/a.dart']),
      onStage: (_) {},
      onUnstage: (_) {},
    );
    // Idle: no banner text is shown.
    expect(find.text('Stage 1 file'), findsNothing);
  });

  testWidgets('dragging an unstaged file onto the banner stages it', (
    tester,
  ) async {
    List<String>? staged;
    List<String>? unstaged;
    await _pump(
      tester,
      item: const DragFiles(['lib/a.dart', 'lib/b.dart']),
      onStage: (p) => staged = p,
      onUnstage: (p) => unstaged = p,
    );
    await _dragOnto(
      tester,
      find.text('SOURCE'),
      find.byKey(const Key('banner-slot')),
    );

    expect(staged, ['lib/a.dart', 'lib/b.dart']);
    expect(unstaged, isNull);
  });

  testWidgets('dragging a staged file onto the banner unstages it', (
    tester,
  ) async {
    List<String>? staged;
    List<String>? unstaged;
    await _pump(
      tester,
      item: const DragFiles(['lib/a.dart'], fromStaged: true),
      onStage: (p) => staged = p,
      onUnstage: (p) => unstaged = p,
    );
    await _dragOnto(
      tester,
      find.text('SOURCE'),
      find.byKey(const Key('banner-slot')),
    );

    expect(unstaged, ['lib/a.dart']);
    expect(staged, isNull);
  });
}
