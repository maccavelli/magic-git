import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../../core/utils/git_porcelain_parser.dart';
import '../common/actions.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/label_picker_field.dart';
import '../forge/forge_create_sheet_widgets.dart';

/// The Forge tab's inline "New Pull Request" form, hosted in the
/// master-detail's right pane (the same creation paradigm as the issue form —
/// no modal sheet). On submit it pushes the head branch first, then creates
/// the PR via `gh`.
class CreatePrForm extends ConsumerStatefulWidget {
  final String repoPath;

  /// Pre-fills the PR head (source) branch, overriding the current-branch
  /// default — used when the form is opened by dropping a branch on the Forge
  /// nav item. Null keeps the default "prefill from the checked-out branch".
  final String? initialHead;

  /// Pre-fills the PR base branch once in initState. Null defaults to `main`.
  /// Never rewritten after the user can edit it.
  final String? initialBase;

  /// Dismisses the form back to the "nothing selected" pane state — called on
  /// Cancel and after a successful create.
  final VoidCallback onClose;

  /// Reports whether the form holds unsaved content, on every edit. The panel
  /// uses it to confirm before a row click would discard a live draft.
  final ValueChanged<bool>? onDirtyChanged;

  const CreatePrForm({
    super.key,
    required this.repoPath,
    required this.onClose,
    this.initialHead,
    this.initialBase,
    this.onDirtyChanged,
  });

  @override
  ConsumerState<CreatePrForm> createState() => _CreatePrFormState();
}

class _CreatePrFormState extends ConsumerState<CreatePrForm> {
  late final TextEditingController _head;
  late final TextEditingController _base;
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
      _head = TextEditingController(text: seeded);
      _headPrefilled = true;
    } else {
      _head = TextEditingController();
    }
    final baseSeed = widget.initialBase;
    _base = TextEditingController(
      text: (baseSeed != null && baseSeed.isNotEmpty) ? baseSeed : 'main',
    );
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

  /// User-authored content only — the auto-prefilled branches don't count, or
  /// merely opening the form would already claim a draft worth guarding.
  bool get _dirty =>
      _title.text.trim().isNotEmpty ||
      _body.text.trim().isNotEmpty ||
      _reviewers.text.trim().isNotEmpty ||
      _assignees.text.trim().isNotEmpty ||
      _labels.isNotEmpty ||
      _milestoneNumber != null;

  // Rebuild hook for every form edit: validation and the diff preview both
  // react to the current field texts, and the panel's draft guard tracks
  // dirtiness.
  void _formChanged() {
    setState(() {});
    widget.onDirtyChanged?.call(_dirty);
  }

  Future<void> _submit() async {
    // Entry guard: the disabled-button state is a rebuild behind, so a rapid
    // double-activation would otherwise push and create the PR twice.
    if (_submitting) return;
    setState(() => _submitting = true);
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
      // `gh pr create --head` assumes the branch already exists on the remote.
      // Push it first (`-u` sets upstream) WHEN it exists locally — publishing
      // any local commits; an already-pushed branch is a no-op ("Everything
      // up-to-date") and a non-fast-forward push surfaces its own error rather
      // than a confusing "No commits between…" from the API. When the branch
      // exists ONLY on the remote (opening a PR for a branch you never checked
      // out), there's nothing local to push — skip straight to create instead
      // of dying on `src refspec <head> does not match any`. The MR form
      // mirrors this.
      final localExists =
          await git.revParse(widget.repoPath, 'refs/heads/$head') != null;
      if (localExists) {
        await git.push(
          widget.repoPath,
          remote: 'origin',
          branch: head,
          setUpstream: true,
        );
      }
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
      widget.onClose();
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text('New Pull Request', style: typography.title3),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (dashboardWarning != null)
                  DashboardWarningBanner(dashboardWarning),
                ForgeSheetField('Head branch', _head, onChanged: _formChanged),
                ForgeSheetField('Base branch', _base, onChanged: _formChanged),
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
                    onToggle: (name) {
                      _labels.contains(name)
                          ? _labels.remove(name)
                          : _labels.add(name);
                      _formChanged();
                    },
                  ),
                if (milestones.isNotEmpty)
                  ForgeMilestonePicker(
                    milestones,
                    // Coerce a stale selection to null: if the dashboard
                    // reloaded without the previously-picked milestone,
                    // passing its now-absent id would trip MacosPopupButton's
                    // value-must-be-an-item assertion.
                    value: milestones.any((m) => m.id == _milestoneNumber)
                        ? _milestoneNumber
                        : null,
                    onChanged: (v) {
                      _milestoneNumber = v;
                      _formChanged();
                    },
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
        Container(height: 1, color: MacosColors.separatorColor),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SheetSubmitRow(
            submitting: _submitting,
            canSubmit: _canSubmit,
            onSubmit: _submit,
            onCancel: widget.onClose,
            submitLabel: 'Create pull request',
          ),
        ),
      ],
    );
  }
}
