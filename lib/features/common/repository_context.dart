import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Optional context that another panel has already loaded for its own screen.
///
/// The repository bar never starts a command for these fields. Publishers may
/// replace individual values as their own provider data lands.
@immutable
class RepositoryContextSupplement {
  final String? worktreeLabel;
  final String? recentCommitLabel;
  final String? forgeLabel;
  final String? branchLabel;
  final String? baseLabel;
  final String? revisionLabel;
  final String? selectionLabel;
  final String? commitPolicyBranch;
  final String? commitPolicyLabel;

  const RepositoryContextSupplement({
    this.worktreeLabel,
    this.recentCommitLabel,
    this.forgeLabel,
    this.branchLabel,
    this.baseLabel,
    this.revisionLabel,
    this.selectionLabel,
    this.commitPolicyBranch,
    this.commitPolicyLabel,
  });

  RepositoryContextSupplement merge(RepositoryContextSupplement next) =>
      RepositoryContextSupplement(
        worktreeLabel: next.worktreeLabel ?? worktreeLabel,
        recentCommitLabel: next.recentCommitLabel ?? recentCommitLabel,
        forgeLabel: next.forgeLabel ?? forgeLabel,
        branchLabel: next.branchLabel ?? branchLabel,
        baseLabel: next.baseLabel ?? baseLabel,
        revisionLabel: next.revisionLabel ?? revisionLabel,
        selectionLabel: next.selectionLabel ?? selectionLabel,
        commitPolicyBranch: next.commitPolicyBranch ?? commitPolicyBranch,
        commitPolicyLabel: next.commitPolicyLabel ?? commitPolicyLabel,
      );

  bool contentEquals(RepositoryContextSupplement other) =>
      worktreeLabel == other.worktreeLabel &&
      recentCommitLabel == other.recentCommitLabel &&
      forgeLabel == other.forgeLabel &&
      branchLabel == other.branchLabel &&
      baseLabel == other.baseLabel &&
      revisionLabel == other.revisionLabel &&
      selectionLabel == other.selectionLabel &&
      commitPolicyBranch == other.commitPolicyBranch &&
      commitPolicyLabel == other.commitPolicyLabel;
}

/// A cache address contains both stable repository identity and connection
/// generation. Even durable identities must not leak old landed values into a
/// newly connected session.
@immutable
class RepositoryContextSupplementKey {
  final String repositoryIdentity;
  final int sessionEpoch;

  const RepositoryContextSupplementKey({
    required this.repositoryIdentity,
    required this.sessionEpoch,
  }) : assert(repositoryIdentity != ''),
       assert(sessionEpoch > 0);

  @override
  bool operator ==(Object other) =>
      other is RepositoryContextSupplementKey &&
      other.repositoryIdentity == repositoryIdentity &&
      other.sessionEpoch == sessionEpoch;

  @override
  int get hashCode => Object.hash(repositoryIdentity, sessionEpoch);
}

class RepositoryContextSupplementCache
    extends
        Notifier<
          Map<RepositoryContextSupplementKey, RepositoryContextSupplement>
        > {
  @override
  Map<RepositoryContextSupplementKey, RepositoryContextSupplement> build() =>
      const {};

  void publish(
    RepositoryContextSupplementKey key,
    RepositoryContextSupplement supplement,
  ) {
    final previous = state[key];
    final next = previous?.merge(supplement) ?? supplement;
    if (previous?.contentEquals(next) ?? false) return;
    state = {...state, key: next};
  }

  void clear() => state = const {};

  void clearSession(int sessionEpoch) {
    final next =
        Map<RepositoryContextSupplementKey, RepositoryContextSupplement>.of(
          state,
        )..removeWhere((key, _) => key.sessionEpoch == sessionEpoch);
    state = Map.unmodifiable(next);
  }
}

String repositoryContextIdentityKey({
  required String backend,
  required String? connectionId,
  required String repositoryPath,
}) =>
    '${connectionId == null ? 'adhoc:$backend' : '$backend:$connectionId'}'
    '\u0000$repositoryPath';

final repositoryContextSupplementCacheProvider =
    NotifierProvider<
      RepositoryContextSupplementCache,
      Map<RepositoryContextSupplementKey, RepositoryContextSupplement>
    >(RepositoryContextSupplementCache.new);

/// How live the repository's change detection currently is.
enum RepositoryWatchHealth {
  /// A real file-system watcher is streaming events.
  live,

  /// Falling back to polling because the watcher is unavailable.
  degraded,

  /// Nothing is watching.
  stopped,
}

/// A short caption about the repository as a whole, shown beside its identity.
enum RepositoryNoticeTone { info, warning }

/// Immutable, render-ready repository context derived from already-landed
/// connection/status/ref/remote state.
@immutable
class RepositoryContextSnapshot {
  final String repositoryPath;
  final String repositoryName;
  final String? connectionLabel;
  final String? hostLabel;
  final String branchLabel;
  final String? upstreamLabel;
  final int ahead;
  final int behind;

  /// Working-tree counts, or null when this screen does not know them.
  ///
  /// Null is not zero: a screen that never reads `git status` (History,
  /// Branches, Stashes, Forge, Worktrees) used to pass 0 and so had the bar
  /// announce "Clean" — a claim about the working tree nobody had checked.
  /// Absence is now representable, and the summary stays silent for it.
  final int? changedCount;
  final int? conflictCount;
  final bool hasPendingOperation;
  final bool hasUpstream;
  final bool hasConfiguredRemote;
  final bool connected;
  final bool busy;
  final bool incomplete;
  final int refCount;

  /// Change-detection health and the sentence explaining it. Rendered as the
  /// small dot beside the repository name — it used to live in the second
  /// toolbar band, which is exactly the kind of ambient state that belongs
  /// with the identity it describes.
  final RepositoryWatchHealth? watchHealth;
  final String? watchHint;

  /// A caption about the repository itself ("No remote detected", "No branches
  /// yet — repository is empty"), with the tone it should be read in.
  final String? notice;
  final RepositoryNoticeTone noticeTone;

  final RepositoryContextSupplement? supplement;

  const RepositoryContextSnapshot({
    required this.repositoryPath,
    required this.repositoryName,
    this.connectionLabel,
    this.hostLabel,
    required this.branchLabel,
    this.upstreamLabel,
    this.ahead = 0,
    this.behind = 0,
    this.changedCount,
    this.conflictCount,
    this.hasPendingOperation = false,
    this.hasUpstream = false,
    this.hasConfiguredRemote = false,
    this.connected = true,
    this.busy = false,
    this.incomplete = false,
    this.refCount = 0,
    this.watchHealth,
    this.watchHint,
    this.notice,
    this.noticeTone = RepositoryNoticeTone.info,
    this.supplement,
  });

  /// Whether this screen knows the working tree's state at all.
  bool get hasWorkingTreeStatus => changedCount != null;

  bool get isDirty => (changedCount ?? 0) > 0;
}

/// What a screen's primary button actually does.
///
/// The kind is the identity of the command, not decoration: it is what
/// `onPrimaryAction` receives, and what a caller switches on. Screens whose
/// primary verb is not a sync operation name it here rather than borrowing
/// [fetch] — four screens used to claim `fetch` while performing a stash, a
/// worktree add, a refresh and a fetch-and-prune, which made the shared
/// contract unreadable and any future dispatch on the kind wrong.
enum RepositoryPrimaryActionKind {
  resolve,
  continueOperation,
  sync,
  pull,
  push,
  publish,
  fetch,
  fetchAndPrune,
  stash,
  addWorktree,
  refresh,
  createRequest,
}

/// The sync verbs the grouped control offers.
///
/// The first four are always present as buttons with fixed meanings; the rest
/// are variants carried by the group's overflow. A button never changes what
/// it does with repository state — only which one is *emphasized* does, which
/// is the whole point of the group: the recommendation is advice, not a
/// moving target under the pointer.
enum RepositorySyncCommand {
  fetch,
  pull,
  push,
  sync,
  pullRebase,
  pullMerge,
  pushSetUpstream,
  pushTags,
  forcePushWithLease,
  forcePush,
}

/// A screen's sync capability, handed to the context bar in place of a lone
/// primary button.
@immutable
class RepositorySyncGroup {
  final ValueChanged<RepositorySyncCommand> onInvoke;

  /// Commands that cannot run right now, mapped to the reason. A command
  /// listed here dims and keeps its tooltip — it never disappears, so the
  /// group's shape is stable and learnable.
  final Map<RepositorySyncCommand, String> unavailable;

  const RepositorySyncGroup({
    required this.onInvoke,
    this.unavailable = const {},
  });

  String? reasonFor(RepositorySyncCommand command) => unavailable[command];
}

@immutable
class RepositoryPrimaryAction {
  final RepositoryPrimaryActionKind kind;
  final String label;
  final String? disabledReason;

  const RepositoryPrimaryAction({
    required this.kind,
    required this.label,
    this.disabledReason,
  });

  bool get enabled => disabledReason == null;
}

/// Chooses one high-confidence next action without performing any work.
RepositoryPrimaryAction resolvePrimaryRepositoryAction(
  RepositoryContextSnapshot snapshot,
) {
  final conflicts = snapshot.conflictCount ?? 0;
  final (kind, label) = snapshot.hasPendingOperation
      ? conflicts > 0
            ? (RepositoryPrimaryActionKind.resolve, 'Resolve')
            : (RepositoryPrimaryActionKind.continueOperation, 'Continue')
      : conflicts > 0
      ? (RepositoryPrimaryActionKind.resolve, 'Resolve')
      : snapshot.ahead > 0 && snapshot.behind > 0
      ? (RepositoryPrimaryActionKind.sync, 'Sync')
      : snapshot.behind > 0
      ? (RepositoryPrimaryActionKind.pull, 'Pull')
      : snapshot.ahead > 0 && snapshot.hasUpstream
      ? (RepositoryPrimaryActionKind.push, 'Push')
      : !snapshot.hasUpstream && snapshot.hasConfiguredRemote
      ? (RepositoryPrimaryActionKind.publish, 'Publish')
      : (RepositoryPrimaryActionKind.fetch, 'Fetch');

  final disabledReason = !snapshot.connected
      ? 'Repository is disconnected'
      : snapshot.incomplete
      ? 'Repository context is still loading'
      : snapshot.busy
      ? 'Another repository operation is running'
      : null;
  return RepositoryPrimaryAction(
    kind: kind,
    label: label,
    disabledReason: disabledReason,
  );
}
