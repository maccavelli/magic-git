// Deep-dive hardening pass over the DnD engine (July 2026, pass 2):
//  * ESC + release over an ELIGIBLE target still snap-backs (the target
//    "accepts" but its guard no-ops — the cell must fly home, not blink out);
//  * a multi-file drag carries the Finder-style count badge on the ghost;
//  * the staging banner's accept guard closes the one-frame ESC race
//    (release lands before the banner's unmount rebuild);
//  * ESC during a rebase-sheet row drag cancels the DRAG — the sheet stays
//    open (EscapeDismissible must not dismiss it mid-gesture) and the drop
//    is a no-op.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/common/escape_dismissible.dart';
import 'package:remote_magic_git/features/dnd/drag_cell.dart';
import 'package:remote_magic_git/features/dnd/drag_item.dart';
import 'package:remote_magic_git/features/dnd/staging_drop_banner.dart';
import 'package:remote_magic_git/features/history/rebase_sheet.dart';

GitCommit _c(String hash, String subject) => GitCommit(
  hash: hash,
  shortHash: hash.substring(0, 7),
  authorName: 'Dev',
  authorEmail: 'd@e',
  date: '2026-07-17T10:00',
  parents: const ['p000000000000'],
  subject: subject,
);

void main() {
  testWidgets('ESC then release over an eligible target still snaps back', (
    tester,
  ) async {
    final accepted = <DragItem>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Row(
            children: [
              DragItemDraggable(
                item: const DragCommit(
                  GitCommit(
                    hash: 'a1b2c3d4e5f6',
                    shortHash: 'a1b2c3d',
                    authorName: 'Dev',
                    authorEmail: 'd@e',
                    date: '2026-07-17T10:00',
                    parents: [],
                    subject: 's',
                  ),
                ),
                immediate: true,
                child: GestureDetector(
                  onTap: () {},
                  child: const SizedBox(
                    width: 120,
                    height: 40,
                    child: Text('ROW'),
                  ),
                ),
              ),
              const SizedBox(width: 100),
              DragTarget<DragItem>(
                onWillAcceptWithDetails: (_) => true,
                // Mirrors DropZone's runtime guard: ESC already nulled the
                // shared state, so a real zone would no-op exactly like this.
                onAcceptWithDetails: (d) => accepted.add(d.data),
                builder: (context, cand, rej) =>
                    const SizedBox(width: 90, height: 40, child: Text('T')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ROW')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveTo(tester.getCenter(find.text('T')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await gesture.up();
    await tester.pump();

    // The plain target still "accepted" (its entry-time decision) — but the
    // engine recognizes the ESC and flies the cell home anyway.
    expect(find.byType(SnapBackFlight), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(SnapBackFlight), findsNothing);
  });

  testWidgets('a multi-file drag ghost carries the count badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Align(
            alignment: Alignment.topLeft,
            child: DragItemDraggable(
              item: const DragFiles(['a.txt', 'b.txt', 'c.txt']),
              immediate: true,
              child: GestureDetector(
                onTap: () {},
                child: const SizedBox(
                  width: 140,
                  height: 40,
                  child: Text('FILES'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('FILES')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(60, 60));
    await tester.pump();

    expect(find.byType(LiftedDragCell), findsOneWidget);
    expect(
      find.descendant(of: find.byType(LiftedDragCell), matching: find.text('3')),
      findsOneWidget,
      reason: 'three files in hand -> Finder-style "3" badge on the cell',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('staging banner ignores a release in the ESC race frame', (
    tester,
  ) async {
    final staged = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Column(
            children: [
              DragItemDraggable(
                item: const DragFiles(['x.txt']),
                immediate: true,
                child: GestureDetector(
                  onTap: () {},
                  child: const SizedBox(
                    width: 140,
                    height: 40,
                    child: Text('FILE'),
                  ),
                ),
              ),
              const SizedBox(height: 60),
              StagingDropBanner(
                onStage: staged.addAll,
                onUnstage: (_) => fail('direction is stage for this drag'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('FILE')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump(); // banner mounts now that a DragFiles drag is live
    await gesture.moveTo(tester.getCenter(find.byType(StagingDropBanner)));
    await tester.pump();

    // ESC, then release BEFORE the next frame: the banner is still mounted
    // (its unmount rebuild hasn't run), so only the runtime guard stands
    // between the release and a stage the user just cancelled.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(staged, isEmpty);
  });

  testWidgets('ESC during a rebase row drag cancels the drag, not the sheet', (
    tester,
  ) async {
    final commits = [_c('a111111111111', 'first'), _c('b222222222222', 'second')];
    late BuildContext homeContext;
    await tester.pumpWidget(
      ProviderScope(
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) {
              homeContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    // A pushed route, exactly like showMacosSheet: EscapeDismissible can pop it.
    unawaited(
      Navigator.of(homeContext).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => EscapeDismissible(
            child: RebaseSheet(
              repoPath: '/srv/repo',
              onto: 'p000000000000',
              commits: commits,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RebaseSheet), findsOneWidget);

    // Drag the second row upward (a reorder), ESC mid-flight, release over
    // the sheet.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('second')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    // The sheet is still open — ESC was consumed by the drag, not the
    // dismissible.
    expect(find.byType(RebaseSheet), findsOneWidget);

    await gesture.moveTo(tester.getCenter(find.text('first')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // Still open, and the cancelled drop mutated nothing: 'first' still
    // renders above 'second'.
    expect(find.byType(RebaseSheet), findsOneWidget);
    final firstY = tester.getTopLeft(find.text('first')).dy;
    final secondY = tester.getTopLeft(find.text('second')).dy;
    expect(firstY, lessThan(secondY));

    // A fresh drag after the cancelled one still works (the cancel flag
    // resets on drag end): drop 'second' onto 'first' -> squash marks it.
    final again = await tester.startGesture(
      tester.getCenter(find.text('second')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await again.moveTo(tester.getCenter(find.text('first')));
    await tester.pump();
    await again.up();
    await tester.pumpAndSettle();
    expect(find.text('Squash'), findsWidgets);
  });
}
