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
/// repo's detected forge. [labels]/[milestones] come from the project dashboard
/// the panel already fetched, so the pickers need no round-trip of their own.
class IssueCreateForm extends ConsumerStatefulWidget {
  final String repoPath;
  final List<ForgeLabel> labels;
  final List<ForgeMilestone> milestones;

  /// Dismisses the form back to the "nothing selected" pane state — called on
  /// Cancel and after a successful create.
  final VoidCallback onClose;

  const IssueCreateForm({
    super.key,
    required this.repoPath,
    required this.labels,
    required this.milestones,
    required this.onClose,
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

  // Rebuild hook for every field edit: the Create button's enabled state tracks
  // the title text.
  void _formChanged() => setState(() {});

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
      // The new issue should show up in the left-pane list immediately.
      ref.invalidate(projectIssuesProvider(widget.repoPath));
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
                    onToggle: (name) => setState(() {
                      _labels.contains(name)
                          ? _labels.remove(name)
                          : _labels.add(name);
                    }),
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
                    onChanged: (v) => setState(() => _milestoneId = v),
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
