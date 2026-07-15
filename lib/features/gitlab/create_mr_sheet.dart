import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge_dashboard.dart';
// Hide the app's connection-phase `ConnectionState` so FutureBuilder's
// framework `ConnectionState` (waiting/done) resolves unambiguously.
import '../../core/providers/app_providers.dart' hide ConnectionState;
import '../../core/utils/git_porcelain_parser.dart';
import '../common/actions.dart';
import '../common/dashboard_warning_banner.dart';
import '../common/diff_view.dart';
import '../common/label_picker_field.dart';
import '../common/labeled_text_field.dart';
import '../common/sized_sheet.dart';

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
  bool _showPreview = false;
  final Set<String> _labels = {};
  // Keyed by the milestone's `iid`, not its title: two milestones (typically
  // one project-level, one inherited from a group) can share the same title,
  // and `MacosPopupButton` requires each item's `value` to be unique — a
  // duplicate would crash the picker in debug builds and silently bind to the
  // wrong milestone in release. The title actually sent to `glab` is resolved
  // back from this id in [_submit].
  int? _milestoneIid;
  Future<String>? _preview;
  Timer? _previewDebounce;

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
    _previewDebounce?.cancel();
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

  /// Splits a comma-separated field into trimmed, non-empty tokens. Also
  /// strips a single leading `@` from each token — a common copy-paste
  /// artifact when a reviewer/assignee username is pulled from a GitLab
  /// profile URL or an `@mention`, which `glab`/GitLab's API expects as a bare
  /// username, not the `@`-prefixed mention form.
  List<String> _csv(TextEditingController c) => c.text
      .split(',')
      .map((s) => s.trim())
      .map((s) => s.startsWith('@') ? s.substring(1) : s)
      .where((s) => s.isNotEmpty)
      .toList();

  void _togglePreview() {
    setState(() {
      _showPreview = !_showPreview;
      if (_showPreview) _refreshPreview();
    });
  }

  void _refreshPreview() {
    final target = _target.text.trim();
    final source = _source.text.trim();
    if (target.isEmpty || source.isEmpty) {
      _preview = null;
      return;
    }
    // `target...source`: what the source branch adds since it forked off target.
    _preview = ref
        .read(gitServiceProvider)
        .diffRange(widget.repoPath, '$target...$source');
  }

  /// Re-fetches the preview only if it's actually showing — editing the
  /// source/target branch while the preview is open used to leave it
  /// pointing at whatever range was current when it was last opened/tapped.
  /// Debounced so a remote `git diff` doesn't fire on every keystroke while
  /// typing a branch name (mirrors the history search filter's debounce).
  void _refreshPreviewIfShown() {
    if (!_showPreview) return;
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(_refreshPreview);
    });
  }

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
        reviewers: _csv(_reviewers),
        assignees: _csv(_assignees),
        labels: _labels.toList(),
        milestone: milestoneTitle,
        squash: _squash,
        removeSourceBranch: _removeSource,
      );
    });
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
                      _field(
                        'Source branch',
                        _source,
                        onExtraChanged: _refreshPreviewIfShown,
                      ),
                      _field(
                        'Target branch',
                        _target,
                        onExtraChanged: _refreshPreviewIfShown,
                      ),
                      if (_sourceEqualsTarget)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10, top: 2),
                          child: Text(
                            'Source and target branches must be different.',
                            style: typography.caption1.copyWith(
                              color: MacosColors.systemRedColor,
                            ),
                          ),
                        ),
                      _field('Title', _title),
                      _field('Description', _description, maxLines: 4),
                      _field(
                        'Reviewers (comma-separated)',
                        _reviewers,
                        placeholder: 'alice, bob',
                      ),
                      _field(
                        'Assignees (comma-separated)',
                        _assignees,
                        placeholder: 'alice',
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
                      if (milestones.isNotEmpty) _milestoneField(milestones),
                      const SizedBox(height: 6),
                      _toggle('Mark as draft', _draft, (v) => _draft = v),
                      _toggle(
                        'Squash commits when merged',
                        _squash,
                        (v) => _squash = v,
                      ),
                      _toggle(
                        'Remove source branch when merged',
                        _removeSource,
                        (v) => _removeSource = v,
                      ),
                      _previewSection(typography),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (_submitting)
                    const ProgressCircle()
                  else
                    PushButton(
                      controlSize: ControlSize.large,
                      onPressed: _canSubmit ? _submit : null,
                      child: const Text('Create'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int maxLines = 1,
    String? placeholder,
    VoidCallback? onExtraChanged,
  }) => LabeledTextField(
    label: label,
    controller: controller,
    maxLines: maxLines,
    placeholder: placeholder,
    padding: const EdgeInsets.only(bottom: 10),
    onChanged: () => setState(() => onExtraChanged?.call()),
  );


  Widget _milestoneField(List<ForgeMilestone> milestones) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 90,
            child: Text('Milestone', style: TextStyle(fontSize: 13)),
          ),
          MacosPopupButton<int?>(
            value: _milestoneIid,
            onChanged: (v) => setState(() => _milestoneIid = v),
            items: [
              const MacosPopupMenuItem<int?>(
                value: null,
                child: Text('None'),
              ),
              for (final m in milestones)
                MacosPopupMenuItem<int?>(value: m.id, child: Text(m.title)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          MacosSwitch(
            value: value,
            onChanged: (v) => setState(() => onChanged(v)),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _previewSection(MacosTypography typography) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: PushButton(
            controlSize: ControlSize.small,
            secondary: true,
            onPressed: _togglePreview,
            child: Text(_showPreview ? 'Hide preview' : 'Preview changes'),
          ),
        ),
        if (_showPreview) ...[
          const SizedBox(height: 8),
          Container(
            height: 220,
            decoration: BoxDecoration(
              border: Border.all(color: MacosColors.separatorColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: FutureBuilder<String>(
              future: _preview,
              builder: (context, snap) {
                if (_preview == null) {
                  return Center(
                    child: Text(
                      'Set source and target branches to preview.',
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                    ),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: ProgressCircle());
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '${snap.error}',
                        style: typography.caption1.copyWith(
                          color: MacosColors.systemRedColor,
                        ),
                      ),
                    ),
                  );
                }
                return DiffView(diff: snap.data ?? '');
              },
            ),
          ),
        ],
      ],
    );
  }

}
