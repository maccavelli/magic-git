// Hiding a branch has to be reversible and visible.
//
// The prefs round-tripped `hiddenBranchNames`/`showHidden` from the start and
// the Hide button wrote them, but NOTHING read them for display: hidden
// branches stayed on screen, and there was no un-hide affordance anywhere —
// so a hidden branch was unrecoverable from inside the app.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/git_service.dart';
import 'package:remote_magic_git/features/branches/branch_view_model.dart';
import 'package:remote_magic_git/features/branches/branch_workspace_prefs.dart';

GitRef _local(String short, {bool isHead = false}) => GitRef(
  name: 'refs/heads/$short',
  oid: short.padRight(40, '0').substring(0, 40),
  isHead: isHead,
  subject: 's',
);

BranchViewModel _vm(
  List<GitRef> refs, {
  Set<String> hidden = const {},
  bool showHidden = false,
  String filterLower = '',
}) => BranchViewModel.fromRefs(
  refs: refs,
  forge: const {},
  merged: const {},
  pinned: const {},
  collapsedSections: const {},
  filterLower: filterLower,
  showStale: true,
  hidden: hidden,
  showHidden: showHidden,
  showAllTags: true,
  showAllRemotes: true,
  grouped: false,
  collapsedFolderPrefixes: const {},
  remoteTags: null,
  remotesList: const ['origin'],
);

void main() {
  final refs = [_local('main', isHead: true), _local('feature'), _local('tmp')];

  test('hidden branches leave every derived list', () {
    final vm = _vm(refs, hidden: {'tmp'});

    // filteredLocals is the single seam; these all derive from it, so one
    // insertion point keeps the navigator and shift-range list in lockstep.
    expect(vm.filteredLocals.map((r) => r.shortName), ['main', 'feature']);
    expect(vm.localsOnScreen.map((r) => r.shortName), isNot(contains('tmp')));
    expect(vm.navigable.map((r) => r.shortName), isNot(contains('tmp')));
  });

  test('allLocalBranches stays complete — Hide, bulk delete, the conflict '
      'scan and the base selector all need the true set', () {
    final vm = _vm(refs, hidden: {'tmp'});

    expect(vm.allLocalBranches.map((r) => r.shortName), [
      'main',
      'feature',
      'tmp',
    ]);
    expect(vm.localBranchNames, contains('tmp'));
  });

  test('showHidden reveals them again', () {
    final vm = _vm(refs, hidden: {'tmp'}, showHidden: true);

    expect(vm.filteredLocals.map((r) => r.shortName), [
      'main',
      'feature',
      'tmp',
    ]);
    expect(
      vm.hiddenLocalCount,
      0,
      reason: 'nothing is being withheld while they are shown',
    );
  });

  test('hiddenLocalCount reports what is withheld, so the reveal affordance '
      'can appear', () {
    expect(_vm(refs, hidden: {'tmp', 'feature'}).hiddenLocalCount, 2);
    expect(_vm(refs).hiddenLocalCount, 0);
  });

  test('the section total counts showable branches, not hidden ones', () {
    // Otherwise "Local Branches (3)" would render two rows with no filter
    // applied and no explanation for the third.
    expect(_vm(refs, hidden: {'tmp'}).totalLocals, 2);
    expect(_vm(refs).totalLocals, 3);
  });

  test('the dashboard stops counting hidden branches too', () {
    expect(_vm(refs, hidden: {'tmp'}).dashboard.local, 2);
    expect(_vm(refs).dashboard.local, 3);
  });

  test('hiding composes with the name filter', () {
    final vm = _vm(refs, hidden: {'feature'}, filterLower: 'e');

    // 'feature' matches the filter but is hidden; 'tmp' does not match.
    expect(vm.filteredLocals.map((r) => r.shortName), isEmpty);
  });

  group('late prefs load', () {
    test('does not clobber a hide made this session', () {
      const current = BranchWorkspacePrefs(
        hiddenBranchNames: ['tmp'],
        showHidden: true,
      );
      const incoming = BranchWorkspacePrefs();

      final merged = mergeLateLoadedPrefs(
        current: current,
        incoming: incoming,
        touchedHidden: true,
      );

      expect(merged.hiddenBranchNames, ['tmp']);
      expect(merged.showHidden, isTrue);
    });

    test('still adopts stored hides when the session has not touched them', () {
      final merged = mergeLateLoadedPrefs(
        current: const BranchWorkspacePrefs(),
        incoming: const BranchWorkspacePrefs(hiddenBranchNames: ['old']),
      );

      expect(merged.hiddenBranchNames, ['old']);
    });
  });
}
