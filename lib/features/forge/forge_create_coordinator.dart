/// Single entry point for "Create PR/MR from branch" — used by DnD drop on
/// Forge and by the Branches detail Create action (Phase 5).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_urls.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/display_error.dart';
import '../common/actions.dart';
import '../dnd/drop_registry.dart';
import '../tabs/tab_ui_providers.dart';
import 'forge_prefs.dart';

/// Resolves forge for the **main shell** mount path, seeds the create form,
/// and navigates to the Forge page (index 4).
///
/// [baseRefName] is optional workspace base full-ref or short name; it is
/// normalized via [forgeBranchNameForCreateSeed] (omit when null).
Future<void> openCreateChangeRequest({
  required BuildContext context,
  required WidgetRef ref,
  required String branchShortName,
  String? baseRefName,

  /// When true, use DropZone selectPage (DnD). When false, pageIndex + visit.
  bool fromDrop = false,
}) async {
  final connection = ref.read(connectionProvider);
  final forgeMountRepoPath = connection.repoPath;
  if (forgeMountRepoPath == null || forgeMountRepoPath.isEmpty) {
    if (context.mounted) {
      await showErrorDialog(context, 'No repository is connected.');
    }
    return;
  }

  final Forge forge;
  try {
    forge = await ref.read(forgeProvider(forgeMountRepoPath).future);
  } catch (e) {
    if (context.mounted) {
      await showErrorDialog(context, displayError(e));
    }
    return;
  }
  if (!context.mounted) return;

  switch (forge) {
    case Forge.github:
    case Forge.gitlab:
      final base = forgeBranchNameForCreateSeed(baseRefName);
      ref
          .read(forgeCreateSeedProvider.notifier)
          .set(forgeMountRepoPath, branchShortName, baseRef: base);
      if (fromDrop) {
        // Caller is expected to have DropContext.selectPage available; fall
        // through to index selection which works for both paths.
      }
      ref.read(pageIndexProvider.notifier).select(DropZoneId.forge.pageIndex);
      ref.read(visitedPagesProvider.notifier).visit(DropZoneId.forge.pageIndex);
    case Forge.none:
    case Forge.unknown:
      await showErrorDialog(
        context,
        'No GitHub or GitLab remote detected for this repository.',
      );
  }
}
