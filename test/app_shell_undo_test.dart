// MADR 0030 T2.5. The undo/redo SHELL WIRING.
//
// The undo logic is well covered — `undo_journal.dart` 100 %, `undo_types.dart`
// 97 %, `undo_controller.dart` 88 %, seven test files. The gap was the join:
// 69 uncovered lines across `_undoGitOperation()` and `_redoGitOperation()`,
// over a feature that mutates a repository. Same shape as defect 3 — the logic
// tested, the wiring not.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:remote_magic_git/core/git/watch_event.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';
import 'package:remote_magic_git/core/undo/undo_controller.dart';
import 'package:remote_magic_git/features/app_shell.dart';

class _StubConnection extends ConnectionController {
  _StubConnection(this._state);
  final ConnectionState _state;
  @override
  ConnectionState build() => _state;
}

/// Counters live OUTSIDE the fake on purpose. Both behaviours under test end
/// with the shell never reading `undoControllerProvider` at all, so a counter
/// on the instance would be unreachable — the assertion would fail on a
/// LateError instead of on the thing it is asserting. (It did, first time.)
class _Calls {
  int undo = 0;
  int redo = 0;
  final forces = <bool>[];
}

// ignore: library_private_types_in_public_api
late _Calls calls;

/// Records what the shell asks of the controller, and answers with a scripted
/// attempt. The controller's own behaviour is already covered elsewhere; what
/// is under test is whether the shell calls it at all, and with what.
class _RecordingUndo extends UndoController {
  _RecordingUndo(
    super.ref, {
    this.attempt = const UndoAttempt(UndoStatus.done),
  });
  final UndoAttempt attempt;

  @override
  Future<UndoAttempt> undo(String repoPath, {bool force = false}) async {
    calls.undo++;
    calls.forces.add(force);
    return attempt;
  }

  @override
  Future<RedoAttempt> redo(String repoPath, {bool force = false}) async {
    calls.redo++;
    calls.forces.add(force);
    return const RedoAttempt(RedoStatus.done);
  }
}

Future<void> _pressUndo(WidgetTester tester, {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await tester.pump();
}

void main() {
  setUp(() => calls = _Calls());

  Future<void> pump(
    WidgetTester tester, {
    String? repoPath = '/srv/repo',
    UndoAttempt attempt = const UndoAttempt(UndoStatus.nothingToUndo),
    Widget? extra,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(
            () => _StubConnection(
              ConnectionState(
                phase: ConnectionPhase.connected,
                backend: ConnectionBackend.ssh,
                repoPath: repoPath,
              ),
            ),
          ),
          undoControllerProvider.overrideWith(
            (ref) => _RecordingUndo(ref, attempt: attempt),
          ),
          // Production would arm a real watcher and leave its restart timer
          // pending past teardown; the shell's undo wiring is what is under
          // test, not the watcher.
          if (repoPath != null)
            repoWatchProvider(
              repoPath,
            ).overrideWith((ref) => const Stream<RepoWatchEvent>.empty()),
        ],
        child: MacosApp(
          debugShowCheckedModeBanner: false,
          home: SizedBox.expand(
            child: extra == null
                ? const AppShell()
                : Stack(children: [const AppShell(), extra]),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('⌘Z with no active repo does nothing and does not crash', (
    tester,
  ) async {
    // Pins the user-facing property, and ONLY that. Verified by removing the
    // `repoPath == null` guard and watching this still pass: with no repo the
    // shell renders a different tree, so the keystroke never reaches the
    // handler and the guard is never consulted. The guard is a second line of
    // defence behind a UI that is not there.
    //
    // Said plainly because a test named after a guard it cannot reach is
    // worse than no test: it tells the next reader the guard is covered.
    await pump(tester, repoPath: null);
    await _pressUndo(tester);
    await tester.pump();
    expect(
      calls.undo,
      0,
      reason: 'nothing to undo against when no repository is open',
    );
  });

  testWidgets('⌘Z inside a text field stays TEXT undo', (tester) async {
    // What this pins is the USER-FACING property: a ⌘Z typed into a text
    // field does not become a git undo.
    //
    // What it does NOT exercise is the guard at app_shell.dart:522-531.
    // Verified by removing that guard and watching this test still pass — a
    // focused `EditableText` consumes the keystroke before it reaches the
    // shell's shortcuts, which is exactly what the guard's own comment says
    // ("this guard is the backstop for focus setups that don't"). Producing a
    // focus setup that does NOT consume it is what would exercise the
    // backstop, and this harness cannot make one.
    //
    // Recorded rather than implied, because a test that passes with the code
    // it appears to cover deleted is worth less than no test at all if a
    // reader believes otherwise.
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await pump(
      tester,
      extra: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          child: EditableText(
            controller: controller,
            focusNode: focus,
            style: const TextStyle(),
            cursorColor: const Color(0xFF000000),
            backgroundCursorColor: const Color(0xFF000000),
          ),
        ),
      ),
    );

    focus.requestFocus();
    await tester.pump();
    expect(
      focus.hasFocus,
      isTrue,
      reason: 'the field must actually be focused',
    );

    await _pressUndo(tester);
    await tester.pump();

    expect(
      calls.undo,
      0,
      reason:
          'a focused text field owns ⌘Z; the shell must not turn it into a git '
          'undo',
    );
  });

  testWidgets('CONTROL: ⌘Z with no field focused DOES reach the shell', (
    tester,
  ) async {
    // Without this control the in-field test above is vacuous: it would pass
    // whether or not the guard exists, because a keystroke that never reaches
    // the shell also produces zero undo calls. (It did. This control is what
    // caught it.)
    await pump(tester);
    await _pressUndo(tester);
    await tester.pump();
    expect(
      calls.undo,
      1,
      reason:
          'the shortcut must actually be wired for the guard test to mean '
          'anything',
    );
  });
}
