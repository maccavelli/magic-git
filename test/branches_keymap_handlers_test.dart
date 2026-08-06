// Ensures every branches-category keymap action has a known handler id so
// remappable orphan actions cannot land again (audit H2 / Phase 2).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';

/// Handler ids implemented by [BranchNavigator] PanelShortcuts map.
const kBranchNavigatorHandlerIds = {
  'branches.newBranch',
  'branches.createTag',
  'branches.merge',
  'branches.delete',
  'branches.publish',
  'branches.createRequest',
  'branches.openCi',
  'branches.compare',
};

void main() {
  test('every KeymapCategory.branches action has a navigator handler id', () {
    final branchActions = kKeymapActions
        .where((a) => a.category == KeymapCategory.branches)
        .map((a) => a.id)
        .toSet();
    expect(branchActions, isNotEmpty);
    for (final id in branchActions) {
      expect(
        kBranchNavigatorHandlerIds,
        contains(id),
        reason: 'keymap action $id has no BranchNavigator handler',
      );
    }
  });

  test('navigator handler set has no stray ids outside the keymap', () {
    final branchActions = kKeymapActions
        .where((a) => a.category == KeymapCategory.branches)
        .map((a) => a.id)
        .toSet();
    for (final id in kBranchNavigatorHandlerIds) {
      expect(
        branchActions,
        contains(id),
        reason: 'handler id $id is not in kKeymapActions',
      );
    }
  });
}
