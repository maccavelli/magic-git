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

class CreatePrSheet extends ConsumerStatefulWidget {
  final String repoPath;

  const CreatePrSheet({super.key, required this.repoPath});

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
  bool _showPreview = false;
  final Set<String> _labels = {};
  // Keyed by the milestone's id (GitHub `number`, unique), resolved back to
  // its title for `gh pr create --milestone` in [_submit].
  int? _milestoneNumber;
  Future<String>? _preview;
  Timer? _previewDebounce;

  void _maybePrefillHead(GitStatus? status) {
    if (_headPrefilled || _head.text.trim().isNotEmpty) return;
    final head = status?.branch.head;
    if (head != null && head.isNotEmpty) {
      _head.text = head;
      _headPrefilled = true;
    }
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
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

  /// Splits a comma-separated field into trimmed, non-empty tokens, stripping a
  /// leading `@` (a copy-paste artifact `gh` doesn't expect).
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
    final base = _base.text.trim();
    final head = _head.text.trim();
    if (base.isEmpty || head.isEmpty) {
      _preview = null;
      return;
    }
    // `base...head`: what the head branch adds since it forked off base.
    _preview = ref
        .read(gitServiceProvider)
        .diffRange(widget.repoPath, '$base...$head');
  }

  void _refreshPreviewIfShown() {
    if (!_showPreview) return;
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(_refreshPreview);
    });
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
        reviewers: _csv(_reviewers),
        assignees: _csv(_assignees),
        labels: _labels.toList(),
        milestone: milestoneTitle,
      );
    }, dock: true);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      ref.invalidate(pullRequestsProvider(widget.repoPath));
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
    status.whenData(_maybePrefillHead);
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
                      _field(
                        'Head branch',
                        _head,
                        onExtraChanged: _refreshPreviewIfShown,
                      ),
                      _field(
                        'Base branch',
                        _base,
                        onExtraChanged: _refreshPreviewIfShown,
                      ),
                      if (_headEqualsBase)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10, top: 2),
                          child: Text(
                            'Head and base branches must be different.',
                            style: typography.caption1.copyWith(
                              color: MacosColors.systemRedColor,
                            ),
                          ),
                        ),
                      _field('Title', _title),
                      _field('Description', _body, maxLines: 4),
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
                      _toggle('Create as draft', _draft, (v) => _draft = v),
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
            value: _milestoneNumber,
            onChanged: (v) => setState(() => _milestoneNumber = v),
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
                      'Set head and base branches to preview.',
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
