import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import 'actions.dart';

/// Confirms disconnect / tab-close when the active repo has uncommitted work
/// or a mid-flight merge/rebase/cherry-pick/revert (audit H8).
///
/// Returns true when the caller should proceed with disconnect. Clean trees
/// proceed without a dialog. [container] is the session container that owns
/// [repoPath] (active tab for Logout, the closing tab for tab-close).
Future<bool> confirmSessionExit(
  BuildContext context,
  ProviderContainer container, {
  required String repoPath,
  required String title,
  // The confirm button's verb. The old title-derived fallback stays for the
  // two original callers; new titles (Quit…/Disconnect…) must name their own
  // verb or the button would read "Log Out" (0009 M5).
  String? confirmLabel,
}) async {
  var status = container.read(statusProvider(repoPath)).value;
  if (status == null) {
    final fetched = await runAction(context, () async {
      status = await container.read(statusProvider(repoPath).future);
    });
    if (!fetched || !context.mounted) return false;
  }

  final dirty = status != null && !status!.isClean;
  final pending =
      container.read(pendingOpProvider(repoPath)).value ?? PendingOp.none;
  final hasPending = pending != PendingOp.none;

  if (!dirty && !hasPending) return true;
  if (!context.mounted) return false;

  final parts = <String>[];
  if (dirty) {
    parts.add('You have uncommitted changes in this repository.');
  }
  if (hasPending) {
    parts.add(
      'A ${pending.name} is still in progress. Use Recovery or the '
      'Repository banner to continue or abort before leaving if you need to '
      'finish it.',
    );
  }
  parts.add(
    'Logging out or closing this tab does not delete files on the host, '
    'but you will leave this session.',
  );

  return confirmAction(
    context,
    title: title,
    message: parts.join('\n\n'),
    confirmLabel:
        confirmLabel ?? (title.contains('Close') ? 'Close Tab' : 'Log Out'),
    destructive: true,
  );
}

/// One session that still has work at stake when the whole app is about to
/// exit (0009 M5).
typedef SessionAtRisk = ({String repoPath, bool dirty, PendingOp pending});

/// The subset of [sessions] with uncommitted work or a mid-flight sequencer
/// operation. Reads only already-landed status/pendingOp values — quit and
/// window-close must never block on a per-tab network round-trip, so an
/// unknown status counts as clean (the same never-prompt-on-unknown rule the
/// reconnect overlay uses).
List<SessionAtRisk> sessionsAtRisk(
  Iterable<(ProviderContainer, String)> sessions,
) {
  final atRisk = <SessionAtRisk>[];
  for (final (container, repoPath) in sessions) {
    final status = container.read(statusProvider(repoPath)).value;
    final pending =
        container.read(pendingOpProvider(repoPath)).value ?? PendingOp.none;
    final dirty = status != null && !status.isClean;
    if (dirty || pending != PendingOp.none) {
      atRisk.add((repoPath: repoPath, dirty: dirty, pending: pending));
    }
  }
  return atRisk;
}

/// The quit / window-close summary: one line per at-risk session with its
/// reason, so multiple dirty tabs get ONE dialog rather than a chain.
String sessionExitSummaryMessage(List<SessionAtRisk> atRisk) {
  final lines = [
    for (final t in atRisk)
      '• ${t.repoPath} — ${[if (t.dirty) 'uncommitted changes', if (t.pending != PendingOp.none) '${t.pending.name} in progress'].join(', ')}',
  ];
  return '${lines.join('\n')}\n\n'
      'Nothing is deleted on the host, but these sessions will be left '
      'as-is.';
}
