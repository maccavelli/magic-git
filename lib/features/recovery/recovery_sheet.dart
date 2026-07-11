import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../common/actions.dart';
import '../common/diff_view.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';
import '../common/tool_icon_button.dart';
import '../history/ref_chip.dart';

/// The Recovery sheet — a browser over HEAD's reflog plus the app's own
/// pre-destroy snapshots (`refs/magic-git/snapshots/`), for digging out any
/// state ⌘Z can no longer reach. Reflog entries restore via the existing
/// service primitives (checkout / reset / branch-from), so everything done
/// from here is itself undoable where those ops are.
///
/// Opened from "View → Recovery View" (checkable), the command palette, and
/// the History panel; visibility routes through [recoveryVisibleProvider]
/// exactly like the Dashboard, so the menu checkmark and the sheet can never
/// disagree.
class RecoverySheet extends ConsumerStatefulWidget {
  const RecoverySheet({super.key});

  @override
  ConsumerState<RecoverySheet> createState() => _RecoverySheetState();
}

class _RecoverySheetState extends ConsumerState<RecoverySheet> {
  bool _busy = false;

  /// Exactly one of these is non-null when something is selected.
  String? _selectedHash;
  SnapshotRef? _selectedSnapshot;

  void _close() => Navigator.of(context).pop();

  /// The standard post-mutation refresh, plus this sheet's own two providers.
  void _refreshRepo(String repoPath) {
    ref.read(ownMutationTrackerProvider).mark(repoPath);
    noteWorktreeEdit(repoPath);
    ref.invalidate(statusProvider(repoPath));
    ref.invalidate(logProvider(repoPath));
    ref.invalidate(refsProvider(repoPath));
    ref.invalidate(stashesProvider(repoPath));
    ref.invalidate(reflogProvider(repoPath));
    ref.invalidate(magicSnapshotsProvider(repoPath));
  }

  Future<void> _run(String repoPath, Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runAction(context, op);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refreshRepo(repoPath);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final connection = ref.watch(connectionProvider);
    final repoPath = connection.isConnected ? connection.repoPath : null;

    return SizedSheet(
      // Wide like the Dashboard's exemption class: a diff pane needs room.
      width: 780,
      height: (MediaQuery.sizeOf(context).height - 60).clamp(460.0, 760.0),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const MacosIcon(
                  CupertinoIcons.arrow_counterclockwise_circle,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text('Recovery', style: typography.title2),
                const Spacer(),
                ToolIconButton(
                  icon: CupertinoIcons.xmark,
                  tooltip: 'Close',
                  onPressed: _close,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Every place HEAD has pointed, and the snapshots Magic Git '
              'took before destructive operations. Select an entry to '
              'inspect and restore it.',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: repoPath == null
                  ? Center(
                      child: Text('Not connected', style: typography.body),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 330, child: _entryList(repoPath)),
                        Container(width: 1, color: MacosColors.separatorColor),
                        Expanded(child: _detailPane(repoPath)),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Left: reflog + snapshot lists ---------------------------------------

  Widget _entryList(String repoPath) {
    final typography = MacosTheme.of(context).typography;
    final reflogAsync = ref.watch(reflogProvider(repoPath));
    final snapshotsAsync = ref.watch(magicSnapshotsProvider(repoPath));
    final decorations = refsByCommit(
      ref.watch(refsProvider(repoPath)).value ?? const [],
    );

    return reflogAsync.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => _errorText('$err'),
      data: (entries) {
        final snapshots = snapshotsAsync.value ?? const <SnapshotRef>[];
        return ListView(
          children: [
            _sectionHeader('Reflog', typography),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'No reflog entries yet.',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ),
            for (final entry in entries)
              _reflogRow(entry, decorations, typography),
            _sectionHeader('Snapshots', typography),
            if (snapshots.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'No snapshots. One is taken automatically before each '
                  'discard or delete, and kept for '
                  '${GitService.snapshotExpiry.inDays} days.',
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ),
            for (final snapshot in snapshots) _snapshotRow(snapshot, typography),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(String title, MacosTypography typography) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
    child: Text(
      title.toUpperCase(),
      style: typography.caption2.copyWith(
        color: MacosColors.systemGrayColor,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _reflogRow(
    ReflogEntry entry,
    Map<String, List<GitRef>> decorations,
    MacosTypography typography,
  ) {
    final selected = _selectedHash == entry.hash && _selectedSnapshot == null;
    final refs = decorations[entry.hash] ?? const <GitRef>[];
    return _selectableRow(
      selected: selected,
      onTap: () => setState(() {
        _selectedHash = entry.hash;
        _selectedSnapshot = null;
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (entry.action.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: MacosColors.systemBlueColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    entry.action,
                    style: typography.caption2.copyWith(
                      color: MacosColors.systemBlueColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  entry.detail.isNotEmpty ? entry.detail : entry.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.body,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              for (final r in refs.take(3)) RefChip(gitRef: r),
              Expanded(
                child: Text(
                  '${entry.shortHash} · ${entry.selector}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.caption1.copyWith(
                    color: MacosColors.systemGrayColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _snapshotRow(SnapshotRef snapshot, MacosTypography typography) {
    final selected = _selectedSnapshot?.refName == snapshot.refName;
    return _selectableRow(
      selected: selected,
      onTap: () => setState(() {
        _selectedSnapshot = snapshot;
        _selectedHash = null;
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            snapshot.isUntrackedSnapshot
                ? 'Deleted untracked files'
                : snapshot.subject,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typography.body,
          ),
          const SizedBox(height: 2),
          Text(
            snapshot.relativeDate,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectableRow({
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
  }) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: selected
            ? MacosColors.systemBlueColor.withValues(alpha: 0.15)
            : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    ),
  );

  // ---- Right: preview + restore actions ------------------------------------

  Widget _detailPane(String repoPath) {
    final typography = MacosTheme.of(context).typography;
    final snapshot = _selectedSnapshot;
    final hash = snapshot?.oid ?? _selectedHash;
    if (hash == null) {
      return Center(
        child: Text(
          'Select a reflog entry or snapshot',
          style: typography.body.copyWith(color: MacosColors.systemGrayColor),
        ),
      );
    }
    final diffAsync = ref.watch(commitDiffProvider((repoPath, hash)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 0, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  snapshot != null
                      ? (snapshot.isUntrackedSnapshot
                            ? 'Snapshot of deleted untracked files'
                            : snapshot.subject)
                      : hash.substring(0, 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typography.headline,
                ),
              ),
              const SizedBox(width: 8),
              snapshot != null
                  ? _snapshotActions(repoPath, snapshot)
                  : _reflogActions(repoPath, hash),
            ],
          ),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (err, _) => _errorText('$err'),
            data: (diff) => DiffView(diff: diff),
          ),
        ),
      ],
    );
  }

  Widget _reflogActions(String repoPath, String hash) {
    return MacosPulldownButton(
      title: 'Restore…',
      items: [
        MacosPulldownMenuItem(
          title: const Text('Checkout this state'),
          onTap: _busy ? null : () => _actCheckout(repoPath, hash),
        ),
        MacosPulldownMenuItem(
          title: const Text('Create branch here…'),
          onTap: _busy ? null : () => _actBranchFrom(repoPath, hash),
        ),
        MacosPulldownMenuItem(
          title: const Text('Reset current branch here (soft)'),
          onTap: _busy
              ? null
              : () => _actReset(repoPath, hash, ResetMode.soft),
        ),
        MacosPulldownMenuItem(
          title: const Text('Reset current branch here (hard)'),
          onTap: _busy
              ? null
              : () => _actReset(repoPath, hash, ResetMode.hard),
        ),
        MacosPulldownMenuItem(
          title: const Text('Copy hash'),
          onTap: () => Clipboard.setData(ClipboardData(text: hash)),
        ),
      ],
    );
  }

  Widget _snapshotActions(String repoPath, SnapshotRef snapshot) {
    return MacosPulldownButton(
      title: 'Actions',
      items: [
        MacosPulldownMenuItem(
          title: const Text('Restore files'),
          onTap: _busy ? null : () => _actRestoreSnapshot(repoPath, snapshot),
        ),
        MacosPulldownMenuItem(
          title: const Text('Delete snapshot'),
          onTap: _busy ? null : () => _actDeleteSnapshot(repoPath, snapshot),
        ),
        MacosPulldownMenuItem(
          title: const Text('Copy hash'),
          onTap: () => Clipboard.setData(ClipboardData(text: snapshot.oid)),
        ),
      ],
    );
  }

  /// The local branch HEAD is on, or null when detached — for honest copy in
  /// the checkout/reset confirmations.
  String? _currentBranch(String repoPath) {
    final refs = ref.read(refsProvider(repoPath)).value ?? const <GitRef>[];
    for (final r in refs) {
      if (r.isHead && r.isLocalBranch) return r.shortName;
    }
    return null;
  }

  Future<void> _actCheckout(String repoPath, String hash) async {
    // If a local branch points at this state, check the branch out — no
    // detached HEAD needed.
    final refs = ref.read(refsProvider(repoPath)).value ?? const <GitRef>[];
    final branch = refs
        .where((r) => r.isLocalBranch && r.oid == hash)
        .map((r) => r.shortName)
        .firstOrNull;
    final short = hash.substring(0, 10);
    final ok = await confirmAction(
      context,
      title: 'Checkout',
      message: branch != null
          ? 'Checks out branch $branch (at $short).'
          : 'Checks out commit $short directly. HEAD will be detached — '
                'create a branch from here if you want to keep work based '
                'on this state.',
      confirmLabel: 'Checkout',
    );
    if (!ok || !mounted) return;
    final git = ref.read(gitServiceProvider);
    await _run(repoPath, () => git.checkout(repoPath, branch ?? hash));
  }

  Future<void> _actBranchFrom(String repoPath, String hash) async {
    final name = await _promptBranchName();
    if (name == null || !mounted) return;
    final git = ref.read(gitServiceProvider);
    await _run(repoPath, () => git.branchFrom(repoPath, name, hash));
  }

  Future<void> _actReset(
    String repoPath,
    String hash,
    ResetMode mode,
  ) async {
    final branch = _currentBranch(repoPath);
    if (branch == null) {
      await showErrorDialog(
        context,
        'HEAD is detached — there is no current branch to reset. Use '
        '"Checkout this state" or "Create branch here…" instead.',
      );
      return;
    }
    final short = hash.substring(0, 10);
    final ok = await confirmAction(
      context,
      title: mode == ResetMode.hard ? 'Hard Reset' : 'Soft Reset',
      message: mode == ResetMode.hard
          ? 'Moves $branch to $short and overwrites the working tree and '
                'index to match. Uncommitted changes are snapshotted first, '
                'but this is still a destructive operation.'
          : 'Moves $branch to $short, leaving the working tree and index '
                'as they are.',
      confirmLabel: 'Reset',
      destructive: mode == ResetMode.hard,
    );
    if (!ok || !mounted) return;
    final git = ref.read(gitServiceProvider);
    await _run(repoPath, () => git.reset(repoPath, hash, mode: mode));
  }

  Future<void> _actRestoreSnapshot(
    String repoPath,
    SnapshotRef snapshot,
  ) async {
    final ok = await confirmAction(
      context,
      title: 'Restore Files',
      message: snapshot.isUntrackedSnapshot
          ? 'Writes the snapshotted files back into the working tree (they '
                'come back untracked). Existing files with the same names '
                'are overwritten.'
          : 'Applies the snapshotted changes back onto the working tree, '
                'like applying a stash. Conflicting local changes will '
                'surface as merge conflicts.',
      confirmLabel: 'Restore',
    );
    if (!ok || !mounted) return;
    final git = ref.read(gitServiceProvider);
    await _run(repoPath, () => git.restoreSnapshot(repoPath, snapshot));
  }

  Future<void> _actDeleteSnapshot(
    String repoPath,
    SnapshotRef snapshot,
  ) async {
    final ok = await confirmAction(
      context,
      title: 'Delete Snapshot',
      message:
          'Removes this snapshot. Whatever it preserved is no longer '
          'recoverable once git prunes the objects.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final git = ref.read(gitServiceProvider);
    setState(() => _selectedSnapshot = null);
    await _run(repoPath, () => git.deleteSnapshot(repoPath, snapshot));
  }

  Future<String?> _promptBranchName() {
    final controller = TextEditingController();
    return showMacosSheet<String>(
      context: context,
      builder: (sheetContext) => EscapeDismissible(
        child: SizedSheet(
          width: kSheetWidth,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'New branch from this state',
                  style: MacosTheme.of(sheetContext).typography.title3,
                ),
                const SheetDescription(
                  'Creates a branch starting at the selected reflog entry '
                  'and checks it out.',
                ),
                const SizedBox(height: 14),
                MacosTextField(
                  controller: controller,
                  placeholder: 'branch name',
                  autofocus: true,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  onSubmitted: (v) => Navigator.of(
                    sheetContext,
                  ).pop(v.trim().isEmpty ? null : v.trim()),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PushButton(
                      controlSize: ControlSize.large,
                      secondary: true,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    PushButton(
                      controlSize: ControlSize.large,
                      onPressed: () {
                        final v = controller.text.trim();
                        Navigator.of(sheetContext).pop(v.isEmpty ? null : v);
                      },
                      child: const Text('Create'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorText(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: MacosTheme.of(context).typography.caption1.copyWith(
          color: MacosColors.systemRedColor,
        ),
      ),
    ),
  );
}
