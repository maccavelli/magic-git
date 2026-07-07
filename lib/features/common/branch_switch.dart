import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/app_providers.dart';
import 'actions.dart';

/// How to treat uncommitted work when switching branches.
enum _SwitchChoice { stash, carry, cancel }

/// Runs [checkout] behind a data-loss guardrail — the "stash on branch switch"
/// prompt GitHub Desktop users repeatedly cite as why they trust the app.
///
/// When the working tree is clean the checkout runs immediately. When it's
/// dirty the user is asked how to handle the changes:
///  * **Stash & Switch** (recommended) — stashes first, so the changes are
///    parked safely and recoverable via the stash list;
///  * **Switch anyway** — a plain checkout that carries the changes to the
///    target branch (git aborts if they'd be overwritten, so this is safe);
///  * **Cancel**.
///
/// Returns true if the switch actually ran (so the caller can refresh). Any
/// git failure is surfaced via the standard error dialog.
Future<bool> guardedBranchSwitch(
  BuildContext context,
  WidgetRef ref,
  String repoPath,
  Future<void> Function() checkout,
) async {
  final git = ref.read(gitServiceProvider);
  var status = ref.read(statusProvider(repoPath)).value;
  if (status == null) {
    // No cached status yet (e.g. right after connecting or switching repos) —
    // await the same fetch statusProvider itself is already making (`.future`
    // reuses the in-flight/cached request, no redundant round trip) rather
    // than assuming clean. Treating "unknown" as "clean" would silently skip
    // the uncommitted-work guard at exactly the moment it's least safe to.
    final fetched = await runAction(context, () async {
      status = await ref.read(statusProvider(repoPath).future);
    });
    if (!fetched || !context.mounted) return false;
  }

  // Clean tree — nothing to protect, switch directly.
  if (status!.isClean) {
    return runAction(context, checkout);
  }

  final choice = await chooseAction<_SwitchChoice>(
    context,
    title: 'Uncommitted changes',
    message:
        'You have uncommitted changes. How should they be handled before '
        'switching branches?',
    primaryLabel: 'Stash & Switch',
    primaryValue: _SwitchChoice.stash,
    secondary: const [
      ('Switch anyway (bring changes)', _SwitchChoice.carry),
      ('Cancel', _SwitchChoice.cancel),
    ],
  );
  if (choice == null || choice == _SwitchChoice.cancel) return false;
  if (!context.mounted) return false;

  if (choice == _SwitchChoice.stash) {
    // Include untracked files: `GitStatus.isClean` counts untracked entries as
    // dirty, so the guard fires on an untracked-only tree — but a plain
    // `git stash push` ignores untracked files, which would then "succeed"
    // with an empty "No local changes to save" no-op, create no stash, and let
    // the checkout carry the changes across. `--include-untracked` makes the
    // stash actually hold everything the guard flagged.
    final stashed = await runAction(
      context,
      () => git.stashPush(
        repoPath,
        message: 'Auto-stash before branch switch',
        includeUntracked: true,
      ),
    );
    if (!stashed || !context.mounted) return false;
  }
  return runAction(context, checkout);
}
