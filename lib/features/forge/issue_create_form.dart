import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/forge.dart';
import '../../core/forge/forge_dashboard.dart';
import '../../core/providers/app_providers.dart';
import '../common/actions.dart';
import '../common/label_picker_field.dart';
import 'forge_create_sheet_widgets.dart';

/// The Project tab's inline "New Issue" form — the create counterpart to the
/// issue/milestone detail views, hosted in the master-detail's right pane (not
/// a modal sheet). Forge-neutral: on submit it dispatches to `gh`/`glab` by the
/// repo's detected forge. [labels] come from the project dashboard and
/// [milestones] from the same list provider the left pane watches — the panel
/// already fetched both, so the pickers need no round-trip of their own.
class IssueCreateForm extends ConsumerStatefulWidget {
  final String repoPath;
  final List<ForgeLabel> labels;
  final List<ForgeMilestone> milestones;

  /// Dismisses the form back to the "nothing selected" pane state — called on
  /// Cancel and after a successful create.
  final VoidCallback onClose;

  /// Reports whether the form holds unsaved content, on every edit. The panel
  /// uses it to confirm before a row click would discard a live draft.
  final ValueChanged<bool>? onDirtyChanged;

  const IssueCreateForm({
    super.key,
    required this.repoPath,
    required this.labels,
    required this.milestones,
    required this.onClose,
    this.onDirtyChanged,
  });

  @override
  ConsumerState<IssueCreateForm> createState() => _IssueCreateFormState();
}

class _IssueCreateFormState extends ConsumerState<IssueCreateForm> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _assignees = TextEditingController();

  bool _submitting = false;
  final Set<String> _labels = {};
  // Keyed by the milestone's id (GitHub `number` / GitLab `iid`), resolved back
  // to its title for `--milestone` at submit time — see [ForgeMilestonePicker].
  int? _milestoneId;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _assignees.dispose();
    super.dispose();
  }

  bool get _canSubmit => _title.text.trim().isNotEmpty && !_submitting;

  bool get _dirty =>
      _title.text.trim().isNotEmpty ||
      _description.text.trim().isNotEmpty ||
      _assignees.text.trim().isNotEmpty ||
      _labels.isNotEmpty ||
      _milestoneId != null;

  // Rebuild hook for every field edit: the Create button's enabled state tracks
  // the title text, and the panel's draft guard tracks dirtiness.
  void _formChanged() {
    setState(() {});
    widget.onDirtyChanged?.call(_dirty);
  }

  Future<void> _submit() async {
    // Entry guard: the disabled-button state is a rebuild behind, so a rapid
    // double-activation would otherwise create the issue twice.
    if (_submitting) return;
    setState(() => _submitting = true);
    final gh = ref.read(ghServiceProvider);
    final glab = ref.read(glabServiceProvider);
    final title = _title.text.trim();
    final description = _description.text.trim();
    final labels = _labels.toList();
    final assignees = csvUsernames(_assignees.text);
    String? milestoneTitle;
    for (final m in widget.milestones) {
      if (m.id == _milestoneId) {
        milestoneTitle = m.title;
        break;
      }
    }

    final ok = await runAction(context, () async {
      switch (await ref.read(forgeProvider(widget.repoPath).future)) {
        case Forge.github:
          await gh.createIssue(
            widget.repoPath,
            title: title,
            body: description,
            labels: labels,
            assignees: assignees,
            milestone: milestoneTitle,
          );
        case Forge.gitlab:
          await glab.createIssue(
            widget.repoPath,
            title: title,
            description: description,
            labels: labels,
            assignees: assignees,
            milestone: milestoneTitle,
          );
        case Forge.none:
        case Forge.unknown:
          throw StateError('No forge configured for this repository.');
      }
    }, dock: true);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) {
      // The new issue should show up in the left-pane list immediately, and
      // the section header's "N of M" total lives on the dashboard — refresh
      // both so the count doesn't read one short until an unrelated reload.
      ref.invalidate(projectIssuesProvider(widget.repoPath));
      final forge = await ref.read(forgeProvider(widget.repoPath).future);
      if (!mounted) return;
      if (forge == Forge.github) {
        ref.invalidate(githubProjectDashboardProvider(widget.repoPath));
      } else if (forge == Forge.gitlab) {
        ref.invalidate(projectDashboardProvider(widget.repoPath));
      }
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text('New Issue', style: typography.title3),
        ),
        Container(height: 1, color: MacosColors.separatorColor),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ForgeSheetField('Title', _title, onChanged: _formChanged),
                ForgeSheetField(
                  'Description',
                  _description,
                  maxLines: 6,
                  onChanged: _formChanged,
                ),
                ForgeSheetField(
                  'Assignees (comma-separated)',
                  _assignees,
                  placeholder: 'alice, bob',
                  onChanged: _formChanged,
                ),
                if (widget.labels.isNotEmpty)
                  LabelPickerField(
                    labels: widget.labels,
                    selected: _labels,
                    onToggle: (name) {
                      _labels.contains(name)
                          ? _labels.remove(name)
                          : _labels.add(name);
                      _formChanged();
                    },
                  ),
                if (widget.milestones.isNotEmpty)
                  ForgeMilestonePicker(
                    widget.milestones,
                    // Coerce a stale selection to null: if the dashboard
                    // reloaded without the picked milestone, passing its
                    // now-absent id would trip MacosPopupButton's
                    // value-must-be-an-item assertion.
                    value: widget.milestones.any((m) => m.id == _milestoneId)
                        ? _milestoneId
                        : null,
                    onChanged: (v) {
                      _milestoneId = v;
                      _formChanged();
                    },
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
            submitLabel: 'Create issue',
          ),
        ),
      ],
    );
  }
}
