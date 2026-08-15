import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/common/workspace_focus.dart';
import 'package:remote_magic_git/features/common/workspace_navigation.dart';

const _key = WorkspaceSessionKey('/repo', 4);

WorkspaceFocus _location(String id, {int panel = 0}) => WorkspaceFocus(
  repositoryPath: _key.repositoryPath,
  sessionEpoch: _key.sessionEpoch,
  kind: WorkspaceFocusKind.path,
  identity: id,
  panelIndex: panel,
);

void main() {
  test('coalesces equal visits and restores without adding entries', () {
    final container = ProviderContainer.test();
    final history = container.read(workspaceNavigationProvider(_key).notifier);
    history.visit(_location('a'));
    history.visit(_location('a'));
    history.visit(_location('b', panel: 1));
    expect(
      container.read(workspaceNavigationProvider(_key)).locations,
      hasLength(2),
    );

    expect(history.back(), _location('a'));
    expect(
      container.read(workspaceNavigationProvider(_key)).locations,
      hasLength(2),
    );
    expect(history.takePendingForPanel(0), _location('a'));
    expect(history.forward(), _location('b', panel: 1));
  });

  test(
    'bounds history to 50 and drops the forward branch after a new visit',
    () {
      final container = ProviderContainer.test();
      final history = container.read(
        workspaceNavigationProvider(_key).notifier,
      );
      for (var i = 0; i < 55; i++) {
        history.visit(_location('$i'));
      }
      expect(
        container.read(workspaceNavigationProvider(_key)).locations,
        hasLength(50),
      );
      history.back();
      history.visit(_location('replacement'));
      expect(
        container.read(workspaceNavigationProvider(_key)).canForward,
        isFalse,
      );
    },
  );

  test('isolates repository sessions and exposes unavailable identity', () {
    final container = ProviderContainer.test();
    final history = container.read(workspaceNavigationProvider(_key).notifier);
    const foreign = WorkspaceFocus(
      repositoryPath: '/other',
      sessionEpoch: 4,
      kind: WorkspaceFocusKind.path,
      identity: 'foreign',
      panelIndex: 0,
    );
    history.visit(foreign);
    expect(
      container.read(workspaceNavigationProvider(_key)).locations,
      isEmpty,
    );

    final stale = _location('deleted');
    history.visit(stale);
    history.markUnavailable(stale);
    expect(
      container.read(workspaceNavigationProvider(_key)).unavailable,
      stale,
    );
  });

  // 0009 H3: reveal records the location AND marks it pending, so the owning
  // panel's adapter selects the object; plain visit never sets pending (the
  // sidebar's panel flips must not become selections).
  test('reveal sets pending; visit does not', () {
    final container = ProviderContainer.test();
    final history = container.read(workspaceNavigationProvider(_key).notifier);

    history.visit(_location('a'));
    expect(container.read(workspaceNavigationProvider(_key)).pending, isNull);

    history.reveal(_location('b', panel: 1));
    final state = container.read(workspaceNavigationProvider(_key));
    expect(state.current, _location('b', panel: 1));
    expect(state.pending, _location('b', panel: 1));
    expect(history.takePendingForPanel(1), _location('b', panel: 1));
    expect(container.read(workspaceNavigationProvider(_key)).pending, isNull);
  });

  // The destination screen re-reports its pre-restore selection from a
  // post-frame callback scheduled with build-time values. Recording that
  // echo would truncate the forward stack and undo the Back — only the
  // exact echo is suppressed; a genuinely new visit records normally.
  test('a restore ignores the stale echo but not a new visit', () {
    final container = ProviderContainer.test();
    final history = container.read(workspaceNavigationProvider(_key).notifier);
    history.visit(_location('a'));
    history.visit(_location('b'));

    expect(history.back(), _location('a'));
    // The screen (still showing b) echoes b — must not re-advance history.
    history.visit(_location('b'));
    var state = container.read(workspaceNavigationProvider(_key));
    expect(state.current, _location('a'));
    expect(state.canForward, isTrue);

    // The adapter applied the restore; the screen now visits a — a no-op.
    history.visit(_location('a'));
    state = container.read(workspaceNavigationProvider(_key));
    expect(state.current, _location('a'));
    expect(state.canForward, isTrue, reason: 'b is still ahead');

    // A genuinely new selection truncates forward, exactly as before.
    history.visit(_location('c'));
    state = container.read(workspaceNavigationProvider(_key));
    expect(state.current, _location('c'));
    expect(state.canForward, isFalse);
  });
}
