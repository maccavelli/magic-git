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
  final Set<String> _labels = {};
  // Keyed by the milestone's id (GitHub `number`, unique), resolved back to
  // its title for `gh pr create --milestone` in [_submit].
  int? _milestoneNumber;

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
                          value: _milestoneNumber,
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
