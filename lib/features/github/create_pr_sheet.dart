import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../../core/utils/git_porcelain_parser.dart';
import '../common/actions.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/escape_dismissible.dart';
import '../common/label_picker_field.dart';
import '../common/sized_sheet.dart';
import '../forge/forge_create_sheet_widgets.dart';

class CreatePrSheet extends ConsumerStatefulWidget {
  final String repoPath;

  /// Pre-fills the PR head (source) branch, overriding the current-branch
  /// default — used when the sheet is opened by dropping a branch on the Forge
  /// tab. Null keeps the default "prefill from the checked-out branch".
  final String? initialHead;

  const CreatePrSheet({super.key, required this.repoPath, this.initialHead});

  @override
  ConsumerState<CreatePrSheet> createState() => _CreatePrSheetState();
}

class _CreatePrSheetState extends ConsumerState<CreatePrSheet> {
  final _head = TextEditingController();
  final _base = TextEditingController(text: 'main');
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _reviewers = TextEditingController();
  final _assignees = TextEditingController();

  bool _submitting = false;
  bool _headPrefilled = false;
  bool _draft = false;
  final Set<String> _labels = {};
  // Keyed by the milestone's id (GitHub `number`, unique), resolved back to
  // its title for `gh pr create --milestone` in [_submit].
  int? _milestoneNumber;

  @override
  void initState() {
    super.initState();
    // A dropped branch names the head explicitly — seed it and suppress the
    // checked-out-branch prefill so the drop's branch wins.
    final seeded = widget.initialHead;
    if (seeded != null && seeded.isNotEmpty) {
      _head.text = seeded;
      _headPrefilled = true;
    }
  }

  void _maybePrefillHead(GitStatus? status) {
    if (_headPrefilled || _head.text.trim().isNotEmpty) return;
    final head = status?.branch.head;
    if (head != null && head.isNotEmpty) {
      // Runs from a post-frame callback (never during build), so setState is
      // safe — and needed, so the diff preview and validation recompute against
      // the newly-filled head rather than staying on the empty value.
      setState(() {
        _head.text = head;
        _headPrefilled = true;
      });
    }
  }

  @override
  void dispose() {
    _head.dispose();
    _base.dispose();
    _title.dispose();
    _body.dispose();
    _reviewers.dispose();
    _assignees.dispose();
    super.dispose();
  }

  /// Whether head and base name the same branch — GitHub rejects that PR, so
  /// catch it here instead of round-tripping for a raw error.
  bool get _headEqualsBase {
    final head = _head.text.trim();
    final base = _base.text.trim();
    return head.isNotEmpty && head == base;
  }

  bool get _canSubmit =>
      _head.text.trim().isNotEmpty &&
      _base.text.trim().isNotEmpty &&
      _title.text.trim().isNotEmpty &&
      !_headEqualsBase &&
      !_submitting;

  // Rebuild hook for every form edit: validation and the diff preview both
  // react to the current field texts.
  void _formChanged() => setState(() {});

  Future<void> _submit() async {
    // Entry guard: the disabled-button state is a rebuild behind, so a rapid
    // double-activation would otherwise push and create the PR twice.
    if (_submitting) return;
    setState(() => _submitting = true);
    // The create is now in flight: the sheet must not be dismissable, or a
    // cancel/Escape would orphan a PR that still gets created on the remote
    // (the `!mounted` tail would skip the list refresh) and invite a duplicate
    // re-submit. Swallow Escape here; the Cancel button is disabled via the
    // `submitting` flag passed to [SheetSubmitRow].
    final releaseEsc = EscapeInterceptor.of(context, () => true);
    try {
      final gh = ref.read(ghServiceProvider);
      final git = ref.read(gitServiceProvider);
      final head = _head.text.trim();
      final base = _base.text.trim();
      final milestones =
          ref
              .read(githubProjectDashboardProvider(widget.repoPath))
              .value
              ?.milestones ??
          const [];
      String? milestoneTitle;
      for (final m in milestones) {
        if (m.id == _milestoneNumber) {
          milestoneTitle = m.title;
          break;
        }
      }
      final ok = await runAction(context, () async {
        // `gh pr create --head` assumes the branch already exists on the
        // remote. So push it first (`-u` sets upstream); an already-pushed
        // branch is a no-op ("Everything up-to-date"), and a non-fast-forward
        // push surfaces its own error rather than a confusing "No commits
        // between…" from the API. The MR sheet mirrors this.
        await git.push(
          widget.repoPath,
          remote: 'origin',
          branch: head,
          setUpstream: true,
        );
        await gh.createPullRequest(
          widget.repoPath,
          head: head,
          base: base,
          title: _title.text.trim(),
          body: _body.text.trim(),
          draft: _draft,
          reviewers: csvUsernames(_reviewers.text),
          assignees: csvUsernames(_assignees.text),
          labels: _labels.toList(),
          milestone: milestoneTitle,
        );
      }, dock: true);
      if (!mounted) return;
      setState(() => _submitting = false);
      if (ok) {
        ref.invalidate(pullRequestsProvider(widget.repoPath));
        // Creating the PR (and pushing the branch) commonly triggers a new
        // workflow run — refresh the CI list so it appears without a manual tap.
        ref.invalidate(workflowRunsProvider(widget.repoPath));
        // The push set upstream / advanced the remote branch — refresh the repo
        // views so ahead/behind and refs reflect it (the shared helper, like
        // every other mutation).
        refreshAfterMutation(ref, widget.repoPath);
        if (context.mounted) Navigator.of(context).pop();
      }
    } finally {
      releaseEsc?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Prefill the head branch from the checked-out branch once status is
    // available — scheduled after this frame, never applied synchronously in
    // build, so setting the field's controller text can't rebuild it mid-build
    // (a "setState() called during build" crash on a cold-cached status).
    final status = ref.watch(statusProvider(widget.repoPath));
    if (!_headPrefilled) {
      status.whenData((s) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybePrefillHead(s);
        });
      });
    }
    final dashboard = ref
        .watch(githubProjectDashboardProvider(widget.repoPath))
        .value;
    final labels = dashboard?.labels ?? const [];
    final milestones = dashboard?.milestones ?? const [];
    // Carried on the fetch result — reading the service's mutable
    // lastGraphqlWarning at build time raced against other GraphQL calls.
    final dashboardWarning = dashboard?.warning;
    final typography = MacosTheme.of(context).typography;

    return SizedSheet(
      width: kSheetWidth,
      child: SizedBox(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New Pull Request', style: typography.title2),
              const SheetDescription(
                'Opens a pull request on GitHub asking to merge the head '
                'branch into the base branch. Preview the outgoing commits '
                'below before anything is created.',
              ),
              if (dashboardWarning != null)
                DashboardWarningBanner(dashboardWarning),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 460),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ForgeSheetField(
                        'Head branch',
                        _head,
                        onChanged: _formChanged,
                      ),
                      ForgeSheetField(
                        'Base branch',
                        _base,
                        onChanged: _formChanged,
                      ),
                      if (_headEqualsBase)
                        const FieldErrorNote(
                          'Head and base branches must be different.',
                        ),
                      ForgeSheetField('Title', _title, onChanged: _formChanged),
                      ForgeSheetField(
                        'Description',
                        _body,
                        maxLines: 4,
                        onChanged: _formChanged,
                      ),
                      ForgeSheetField(
                        'Reviewers (comma-separated)',
                        _reviewers,
                        placeholder: 'alice, bob',
                        onChanged: _formChanged,
                      ),
                      ForgeSheetField(
                        'Assignees (comma-separated)',
                        _assignees,
                        placeholder: 'alice',
                        onChanged: _formChanged,
                      ),
                      if (labels.isNotEmpty)
                        LabelPickerField(
                          labels: labels,
                          selected: _labels,
                          onToggle: (name) => setState(() {
                            _labels.contains(name)
                                ? _labels.remove(name)
                                : _labels.add(name);
                          }),
                        ),
                      if (milestones.isNotEmpty)
                        ForgeMilestonePicker(
                          milestones,
                          // Coerce a stale selection to null: if the dashboard
                          // reloaded without the previously-picked milestone,
                          // passing its now-absent id would trip
                          // MacosPopupButton's value-must-be-an-item assertion.
                          value: milestones.any((m) => m.id == _milestoneNumber)
                              ? _milestoneNumber
                              : null,
                          onChanged: (v) =>
                              setState(() => _milestoneNumber = v),
                        ),
                      const SizedBox(height: 6),
                      ForgeSheetToggle(
                        'Create as draft',
                        _draft,
                        onChanged: (v) => setState(() => _draft = v),
                      ),
                      ForgeDiffPreview(
                        repoPath: widget.repoPath,
                        from: _head.text.trim(),
                        into: _base.text.trim(),
                        emptyHint: 'Set head and base branches to preview.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SheetSubmitRow(
                submitting: _submitting,
                canSubmit: _canSubmit,
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
