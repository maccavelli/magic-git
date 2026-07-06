import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Hide macos_ui's `Label` widget — we use the GitLab `Label` model here.
import 'package:macos_ui/macos_ui.dart' hide Label;
import '../../core/gitlab/models.dart';
// Hide the app's connection-phase `ConnectionState` so FutureBuilder's
// framework `ConnectionState` (waiting/done) resolves unambiguously.
import '../../core/providers/app_providers.dart' hide ConnectionState;
import '../../core/utils/git_porcelain_parser.dart';
import '../common/actions.dart';
import '../common/diff_view.dart';
import '../common/labeled_text_field.dart';

/// Sheet for creating a merge request. Source defaults to the current branch.
/// Beyond title/description it exposes the fields reviewers reach for most —
/// draft/WIP, reviewers, assignees, labels, milestone, squash, and
/// remove-source-branch — plus a pre-create diff preview of the change.
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
      if (m.iid == _milestoneIid) {
        milestoneTitle = m.title;
        break;
      }
    }
    final ok = await runAction(
      context,
      () => glab.createMergeRequest(
        widget.repoPath,
        sourceBranch: _source.text.trim(),
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
      ),
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      ref.invalidate(mergeRequestsProvider(widget.repoPath));
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
    // this project genuinely having none. Only trusted once a dashboard has
    // actually come back; a still-loading/failed fetch has nothing to report
    // here (and any hard failure already surfaces via its own AsyncValue).
    final dashboardWarning = dashboard == null
        ? null
        : ref.read(glabServiceProvider).lastGraphqlWarning;
    final typography = MacosTheme.of(context).typography;

    return MacosSheet(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New Merge Request', style: typography.title2),
              if (dashboardWarning != null)
                _dashboardWarningBanner(dashboardWarning),
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
                      if (labels.isNotEmpty) _labelsField(labels, typography),
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

  /// Non-fatal warning shown when the labels/milestones fetched for this
  /// sheet may be incomplete — see [GlabService.lastGraphqlWarning]. Mirrors
  /// [repo_status_view.dart]'s `_warningBanner` styling (orange, full-width,
  /// with a triangle icon) so a non-fatal warning reads the same way
  /// throughout the app.
  Widget _dashboardWarningBanner(String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        color: MacosColors.systemOrangeColor.withValues(alpha: 0.15),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const MacosIcon(
              CupertinoIcons.exclamationmark_triangle,
              size: 14,
              color: MacosColors.systemOrangeColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Some project data may be incomplete: $message',
                style: MacosTheme.of(context).typography.caption1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _labelsField(List<Label> labels, MacosTypography typography) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Labels',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final l in labels) _labelChip(l)],
          ),
        ],
      ),
    );
  }

  Widget _labelChip(Label label) {
    final selected = _labels.contains(label.name);
    final color = _hexColor(label.color) ?? MacosColors.systemBlueColor;
    return GestureDetector(
      onTap: () => setState(() {
        selected ? _labels.remove(label.name) : _labels.add(label.name);
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.28 : 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : MacosColors.separatorColor,
          ),
        ),
        child: Text(
          label.name,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _milestoneField(List<Milestone> milestones) {
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
                MacosPopupMenuItem<int?>(value: m.iid, child: Text(m.title)),
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

  /// Parses a GitLab `#RRGGBB` label color into a [Color]; null when malformed.
  static Color? _hexColor(String hex) {
    var h = hex.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length != 6) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(0xFF000000 | v);
  }
}
