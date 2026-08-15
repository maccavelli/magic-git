import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../common/diff_view.dart';
import '../common/inline_action_button.dart';
import 'conflict_view.dart';
import 'repo_change_model.dart';
import 'repo_review_state.dart';

class MultiFileReviewView extends ConsumerStatefulWidget {
  final String repoPath;
  final RepoReviewController controller;
  final VoidCallback onClose;
  final Future<void> Function(List<String>)? onStage;
  final Future<void> Function(List<String>)? onUnstage;
  final Future<void> Function(List<String>)? onDiscard;
  final Future<void> Function(List<String>)? onDelete;
  final Future<void> Function(List<String>)? onIgnore;
  final Future<void> Function(List<String>)? onResolveOurs;
  final Future<void> Function(List<String>)? onResolveTheirs;

  const MultiFileReviewView({
    super.key,
    required this.repoPath,
    required this.controller,
    required this.onClose,
    this.onStage,
    this.onUnstage,
    this.onDiscard,
    this.onDelete,
    this.onIgnore,
    this.onResolveOurs,
    this.onResolveTheirs,
  });

  @override
  ConsumerState<MultiFileReviewView> createState() =>
      _MultiFileReviewViewState();
}

class _MultiFileReviewViewState extends ConsumerState<MultiFileReviewView> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetchNext();
    });
  }

  @override
  void didUpdateWidget(MultiFileReviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _prefetchNext();
  }

  void _prefetchNext() {
    final state = widget.controller.value;
    for (var offset = 1; offset <= 2; offset++) {
      final index = state.activeIndex + offset;
      if (index >= state.items.length) break;
      final item = state.items[index];
      _diffFuture(item).ignore();
    }
  }

  Future<String> _diffFuture(ReviewItemId item) => switch (item.section) {
    // A conflict shows the marker-annotated working file, not a diff —
    // the same source _conflictPanel renders (0009 H9).
    RepoChangeSection.conflict => ref.read(
      conflictFileProvider((widget.repoPath, item.path)).future,
    ),
    RepoChangeSection.untracked => ref.read(
      untrackedDiffProvider((widget.repoPath, item.path)).future,
    ),
    _ => ref.read(
      fileDiffProvider((
        widget.repoPath,
        item.path,
        item.section == RepoChangeSection.staged,
        false,
        3,
      )).future,
    ),
  };

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.value;
    final active = state.active;
    if (active == null) return const Center(child: Text('No files to review'));
    final paths = state.items.map((item) => item.path).toList(growable: false);
    final conflict = active.section == RepoChangeSection.conflict;
    final diff = conflict
        ? ref.watch(conflictFileProvider((widget.repoPath, active.path)))
        : active.section == RepoChangeSection.untracked
        ? ref.watch(untrackedDiffProvider((widget.repoPath, active.path)))
        : ref.watch(
            fileDiffProvider((
              widget.repoPath,
              active.path,
              active.section == RepoChangeSection.staged,
              false,
              3,
            )),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Text(
                '${state.activeIndex + 1} of ${state.items.length}',
                style: MacosTheme.of(context).typography.caption1,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  active.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _badge(active.section),
              InlineActionButton(
                label: state.reviewed.contains(active)
                    ? 'Reviewed'
                    : 'Mark Reviewed',
                icon: CupertinoIcons.check_mark_circled,
                onPressed: () => widget.controller.toggleReviewed(active),
              ),
              InlineActionButton(
                label: 'Previous',
                icon: CupertinoIcons.chevron_up,
                onPressed: state.activeIndex == 0
                    ? null
                    : () => widget.controller.move(-1),
              ),
              InlineActionButton(
                label: 'Next',
                icon: CupertinoIcons.chevron_down,
                onPressed: state.activeIndex == state.items.length - 1
                    ? null
                    : () => widget.controller.move(1),
              ),
              InlineActionButton(
                label: 'Close',
                icon: CupertinoIcons.xmark,
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        _bulkActions(active.section, paths),
        Container(height: 1, color: MacosColors.separatorColor),
        SizedBox(
          height: 34,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: state.items.length,
            itemBuilder: (context, index) {
              final item = state.items[index];
              return InlineActionButton(
                icon: state.reviewed.contains(item)
                    ? CupertinoIcons.check_mark_circled_solid
                    : CupertinoIcons.doc_text,
                label:
                    '${state.reviewed.contains(item) ? '✓ ' : ''}${item.path}',
                onPressed: () => widget.controller.select(index),
              );
            },
          ),
        ),
        Expanded(
          child: diff.when(
            loading: () => const Center(child: ProgressCircle()),
            error: (error, _) =>
                Center(child: Text('Could not load ${active.path}: $error')),
            data: (data) =>
                conflict ? ConflictView(content: data) : DiffView(diff: data),
          ),
        ),
      ],
    );
  }

  Widget _badge(RepoChangeSection section) => Container(
    margin: const EdgeInsets.only(right: 6),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: MacosColors.systemGrayColor.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(section.name),
  );

  Widget _bulkActions(RepoChangeSection section, List<String> paths) {
    // Only a conflict section needs the pending-op-honest side labels; keep
    // the provider untouched otherwise so plain reviews never start it.
    final sides = section == RepoChangeSection.conflict
        ? conflictSideLabels(ref.watch(pendingOpProvider(widget.repoPath)).value)
        : null;
    final callbacks = switch (section) {
      RepoChangeSection.staged => [('Unstage', widget.onUnstage)],
      RepoChangeSection.unstaged => [
        ('Stage', widget.onStage),
        ('Discard', widget.onDiscard),
      ],
      RepoChangeSection.untracked => [
        ('Stage', widget.onStage),
        ('Delete', widget.onDelete),
        ('Ignore', widget.onIgnore),
      ],
      // Mark Resolved is `git add` — the same primitive as Stage, offered
      // under the honest name for a hand-edited conflict (0009 H9 / H6).
      RepoChangeSection.conflict => [
        ('Use ${sides!.ours}', widget.onResolveOurs),
        ('Use ${sides.theirs}', widget.onResolveTheirs),
        ('Mark Resolved', widget.onStage),
      ],
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Wrap(
        spacing: 6,
        children: [
          for (final (label, callback) in callbacks)
            InlineActionButton(
              icon: CupertinoIcons.command,
              label: '$label ${paths.length}',
              onPressed: callback == null ? null : () => callback(paths),
            ),
        ],
      ),
    );
  }
}
