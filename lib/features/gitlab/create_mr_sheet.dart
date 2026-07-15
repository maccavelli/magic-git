import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../../core/utils/git_porcelain_parser.dart';
import '../common/actions.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/label_picker_field.dart';
import '../common/sized_sheet.dart';
import '../forge/forge_create_sheet_widgets.dart';

class CreateMrSheet extends ConsumerStatefulWidget {
  final String repoPath;

  const CreateMrSheet({super.key, required this.repoPath});

  @override
  ConsumerState<CreateMrSheet> createState() => _CreateMrSheetState();
}

class _CreateMrSheetState extends ConsumerState<CreateMrSheet> {
  final _source = TextEditingController();
  final _target = TextEditingController(text: 'main');
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _reviewers = TextEditingController();
  final _assignees = TextEditingController();

  bool _submitting = false;
  bool _sourcePrefilled = false;
  bool _draft = false;
  bool _squash = false;
  bool _removeSource = false;
  final Set<String> _labels = {};
  // Keyed by the milestone's `iid`, not its title: two milestones (typically
  // one project-level, one inherited from a group) can share the same title,
  // and `MacosPopupButton` requires each item's `value` to be unique — a
  // duplicate would crash the picker in debug builds and silently bind to the
  // wrong milestone in release. The title actually sent to `glab` is resolved
  // back from this id in [_submit].
  int? _milestoneIid;

  void _maybePrefillSource(GitStatus? status) {
    if (_sourcePrefilled || _source.text.trim().isNotEmpty) return;
    final head = status?.branch.head;
    if (head != null && head.isNotEmpty) {
      _source.text = head;
      _sourcePrefilled = true;
    }
  }

  @override
  void dispose() {
    _source.dispose();
    _target.dispose();
    _title.dispose();
    _description.dispose();
    _reviewers.dispose();
    _assignees.dispose();
    super.dispose();
  }

  /// Whether the source and target branch fields currently name the same
  /// branch — `glab`/GitLab would reject that MR outright, so it's caught
  /// here instead of round-tripping to the remote for a raw error.
  bool get _sourceEqualsTarget {
    final source = _source.text.trim();
    final target = _target.text.trim();
    return source.isNotEmpty && source == target;
  }

  bool get _canSubmit =>
      _source.text.trim().isNotEmpty &&
      _target.text.trim().isNotEmpty &&
      _title.text.trim().isNotEmpty &&
      !_sourceEqualsTarget &&
      !_submitting;

  // Rebuild hook for every form edit: validation and the diff preview both
  // react to the current field texts.
  void _formChanged() => setState(() {});

  Future<void> _submit() async {
    // Entry guard: the disabled-button state is a rebuild behind, so a rapid
    // double-activation would otherwise push and create the MR twice.
    if (_submitting) return;
    setState(() => _submitting = true);
    final glab = ref.read(glabServiceProvider);
    // `glab mr create --milestone` takes a title (or global id) — [_milestoneIid]
    // is only the *popup's* unique key (see its field doc), so resolve it back
    // to the selected milestone's title from the same dashboard data the popup
    // was built from.
    final milestones =
        ref.read(projectDashboardProvider(widget.repoPath)).value?.milestones ??
        const [];
    String? milestoneTitle;
    for (final m in milestones) {
      if (m.id == _milestoneIid) {
        milestoneTitle = m.title;
        break;
      }
    }
    final git = ref.read(gitServiceProvider);
    final source = _source.text.trim();
    final ok = await runAction(context, () async {
      // The GitLab API creates an MR from a branch that already exists on the
      // remote — `glab mr create` only pushes with an opt-in `--push` flag
      // this sheet never passes, so an unpushed branch used to die with a raw
      // API error. Push first (`-u` sets upstream); an already-pushed branch
      // is a no-op ("Everything up-to-date"). Mirrors the PR sheet.
      await git.push(
        widget.repoPath,
        remote: 'origin',
        branch: source,
        setUpstream: true,
      );
      await glab.createMergeRequest(
        widget.repoPath,
        sourceBranch: source,
        targetBranch: _target.text.trim(),
        title: _title.text.trim(),
        description: _description.text.trim(),
        draft: _draft,
        reviewers: csvUsernames(_reviewers.text),
        assignees: csvUsernames(_assignees.text),
        labels: _labels.toList(),
        milestone: milestoneTitle,
        squash: _squash,
        removeSourceBranch: _removeSource,
      );
    }, dock: true);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      ref.invalidate(mergeRequestsProvider(widget.repoPath));
      // The push set upstream / advanced the remote branch — refresh the repo
      // views so ahead/behind and refs reflect it (the shared helper, like
      // every other mutation).
      refreshAfterMutation(ref, widget.repoPath);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(statusProvider(widget.repoPath));
    status.whenData(_maybePrefillSource);
    // Reuses the Project panel's one-round-trip GraphQL dashboard instead of
    // two separate REST calls — real duplicate work if the dashboard is
    // already cached for this repo, and still cheaper (one round trip, not
    // two) even when this sheet is the first thing to fetch it.
    final dashboard = ref.watch(projectDashboardProvider(widget.repoPath)).value;
    final labels = dashboard?.labels ?? const [];
    final milestones = dashboard?.milestones ?? const [];
    // Set (non-fatal) when the dashboard's GraphQL query returned partial
    // data alongside a GraphQL `errors[]` entry (e.g. no permission on one
    // field) — the labels/milestones shown here may be incomplete rather than
    // this project genuinely having none. Carried on the fetch result —
    // reading the service's mutable lastGraphqlWarning at build time raced
    // against other GraphQL calls.
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
              Text('New Merge Request', style: typography.title2),
              const SheetDescription(
                'Opens a merge request on GitLab asking to merge the source '
                'branch into the target branch. Preview the outgoing commits '
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
                        'Source branch',
                        _source,
                        onChanged: _formChanged,
                      ),
                      ForgeSheetField(
                        'Target branch',
                        _target,
                        onChanged: _formChanged,
                      ),
                      if (_sourceEqualsTarget)
                        const FieldErrorNote(
                          'Source and target branches must be different.',
                        ),
                      ForgeSheetField('Title', _title, onChanged: _formChanged),
                      ForgeSheetField(
                        'Description',
                        _description,
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
                          value: _milestoneIid,
                          onChanged: (v) => setState(() => _milestoneIid = v),
                        ),
                      const SizedBox(height: 6),
                      ForgeSheetToggle(
                        'Mark as draft',
                        _draft,
                        onChanged: (v) => setState(() => _draft = v),
                      ),
                      ForgeSheetToggle(
                        'Squash commits when merged',
                        _squash,
                        onChanged: (v) => setState(() => _squash = v),
                      ),
                      ForgeSheetToggle(
                        'Remove source branch when merged',
                        _removeSource,
                        onChanged: (v) => setState(() => _removeSource = v),
                      ),
                      ForgeDiffPreview(
                        repoPath: widget.repoPath,
                        from: _source.text.trim(),
                        into: _target.text.trim(),
                        emptyHint: 'Set source and target branches to preview.',
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
