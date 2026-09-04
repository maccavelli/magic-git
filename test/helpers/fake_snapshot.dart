// Since 0025 Finding B, `statusProvider`, `refsProvider` and
// `pendingOpProvider` are views of one `repoSnapshotProvider` fetch rather than
// three independent ones — six refresh triggers were producing fifteen
// snapshot commands. That moved the fetch seam from `GitService.status()` to
// `GitService.snapshot()`.
//
// A fake that overrides `status()` or `refs()` gets a matching `snapshot()`
// from one of the mixins here, so it keeps intercepting. Pick the one that
// matches the seam the fake actually overrides:
//
// * overrides `status()`  -> [FakeSnapshot]     (refs come from `fakeRefs`)
// * overrides `refs()`    -> [FakeRefsSnapshot] (status comes from `fakeStatus`)
//
// Choosing the other one is the single mistake this pair allows, and it used to
// be silent: each mixin's `snapshot()` calls one virtual seam, and the base
// implementation of that seam resolves back through `snapshot()`. A fake that
// overrides neither therefore recurses forever — through `await`, which floods
// the microtask queue. Dart drains every microtask before any timer, so
// `flutter test`'s own `--timeout` timer never fires: the run hangs with no
// error, no stack, and no failing test name. [_guarded] converts that into a
// named `StateError` on the first re-entry.
library;

import 'dart:async';

import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/core/utils/git_porcelain_parser.dart';

/// Marks the dynamic extent of one fake `snapshot()` call so a re-entrant one
/// can be told apart from a merely concurrent one.
///
/// Zone-scoped rather than a field on the fake: zone values propagate down an
/// await chain but not across independent ones, so two genuinely concurrent
/// snapshots of the same repo — the case `GitService._snapshotInFlight` exists
/// to collapse — do not trip the guard.
const _owner = #fakeSnapshotOwner;

Future<RepoSnapshot> _guarded(
  GitService owner,
  String seam,
  String alternative,
  Future<RepoSnapshot> Function() body,
) {
  if (identical(Zone.current[_owner], owner)) {
    throw StateError(
      'snapshot() re-entered through $seam on ${owner.runtimeType}. That fake '
      'does not override $seam, so the base GitService.$seam resolved back '
      'through snapshot(). Override $seam on the fake, or mix in '
      '$alternative instead.',
    );
  }
  return runZoned(body, zoneValues: {_owner: owner});
}

/// For fakes that override `status()`.
///
/// Deliberately does not call `refs()` — see the library comment; fakes that
/// care about refs override [fakeRefs].
mixin FakeSnapshot on GitService {
  /// Refs this fake reports through the snapshot. Defaults to none.
  List<GitRef> get fakeRefs => const [];

  @override
  Future<RepoSnapshot> snapshot(String repoPath) =>
      _guarded(this, 'status()', 'FakeRefsSnapshot', () async {
        return RepoSnapshot(
          status: await status(repoPath),
          refs: fakeRefs,
          pendingOp: PendingOp.none,
        );
      });
}

/// Twin of [FakeSnapshot] for fakes that override `refs()` but not `status()`.
mixin FakeRefsSnapshot on GitService {
  /// Status this fake reports. Clean by default.
  GitStatus get fakeStatus =>
      GitStatus(branch: const GitBranchInfo(), files: const []);

  @override
  Future<RepoSnapshot> snapshot(String repoPath) =>
      _guarded(this, 'refs()', 'FakeSnapshot', () async {
        return RepoSnapshot(
          status: fakeStatus,
          refs: await refs(repoPath),
          pendingOp: PendingOp.none,
        );
      });
}
