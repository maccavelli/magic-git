import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

// Hide the app's connection-phase `ConnectionState` so FutureBuilder's
// framework `ConnectionState` (waiting/done) resolves unambiguously.
import '../../core/forge/forge_dashboard.dart';
import '../../core/providers/app_providers.dart' hide ConnectionState;
import '../../core/utils/display_error.dart';
import '../common/buttons.dart';
import '../common/diff_view.dart';
import '../common/field_styles.dart';
import '../common/labeled_text_field.dart';

/// Form pieces shared by the create-PR and create-MR sheets. The two sheets
/// are deliberately parallel (GitHub and GitLab vocabulary aside); these were
/// byte-identical private copies before being pulled out.

/// Splits a comma-separated usernames field into trimmed, non-empty tokens,
/// stripping a single leading `@` from each — a common copy-paste artifact
/// when a reviewer/assignee is pulled from a profile URL or an `@mention`,
/// which `gh`/`glab` expect as a bare username.
List<String> csvUsernames(String text) => text
    .split(',')
    .map((s) => s.trim())
    .map((s) => s.startsWith('@') ? s.substring(1) : s)
    .where((s) => s.isNotEmpty)
    .toList();

/// A labelled text field with the sheets' shared spacing. [onChanged] is the
/// owning sheet's rebuild hook (validation and the preview react to text).
class ForgeSheetField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final String? placeholder;
  final VoidCallback onChanged;

  const ForgeSheetField(
    this.label,
    this.controller, {
    super.key,
    required this.onChanged,
    this.maxLines = 1,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) => LabeledTextField(
    label: label,
    controller: controller,
    maxLines: maxLines,
    placeholder: placeholder,
    padding: const EdgeInsets.only(bottom: 10),
    onChanged: onChanged,
  );
}

/// A switch row (`Create as draft`, `Squash commits when merged`, …).
class ForgeSheetToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const ForgeSheetToggle(
    this.label,
    this.value, {
    super.key,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          MacosSwitch(value: value, onChanged: onChanged),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// The milestone popup. [value]/[onChanged] carry the milestone's unique key
/// ([ForgeMilestone.id] — GitHub `number`, GitLab `iid` or global REST id),
/// never its title: two milestones can share a title (project-level +
/// group-inherited) and `MacosPopupButton` requires unique item values. The
/// owning sheet resolves the key back to a title at submit time.
class ForgeMilestonePicker extends StatelessWidget {
  final List<ForgeMilestone> milestones;
  final int? value;
  final ValueChanged<int?> onChanged;

  const ForgeMilestonePicker(
    this.milestones, {
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 90,
            child: Text('Milestone', style: TextStyle(fontSize: 13)),
          ),
          MacosPopupButton<int?>(
            value: value,
            onChanged: onChanged,
            items: [
              const MacosPopupMenuItem<int?>(value: null, child: Text('None')),
              // Skip any milestone without a parseable id: it can't serve as a
              // unique popup value, and two such entries would otherwise share
              // one key and trip MacosPopupButton's duplicate-value assertion.
              for (final m in milestones)
                if (m.id != null)
                  MacosPopupMenuItem<int?>(value: m.id, child: Text(m.title)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Red caption under a field that fails client-side validation.
class FieldErrorNote extends StatelessWidget {
  final String text;

  const FieldErrorNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 2),
      child: Text(
        text,
        style: MacosTheme.of(
          context,
        ).typography.caption1.copyWith(color: MacosColors.systemRedColor),
      ),
    );
  }
}

/// The sheets' trailing Cancel / Create row; Create shows a spinner while the
/// submit is in flight.
class SheetSubmitRow extends StatelessWidget {
  final bool submitting;
  final bool canSubmit;
  final VoidCallback onSubmit;
  final String submitLabel;

  /// What Cancel does. Defaults to popping the enclosing route (the create
  /// sheets), but a pane-hosted form (the Project tab's inline issue create)
  /// has no route to pop and passes its own dismiss callback instead.
  final VoidCallback? onCancel;

  const SheetSubmitRow({
    super.key,
    required this.submitting,
    required this.canSubmit,
    required this.onSubmit,
    this.submitLabel = 'Create',
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        AppPushButton(
          controlSize: ControlSize.large,
          secondary: true,
          // Disabled while a submit is in flight: cancelling then would orphan
          // a PR/MR/issue that still gets created on the remote (and the sheet's
          // Escape key is likewise suppressed while submitting).
          onPressed: submitting
              ? null
              : (onCancel ?? () => Navigator.of(context).pop()),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        if (submitting)
          const ProgressCircle()
        else
          AppPushButton(
            controlSize: ControlSize.large,
            onPressed: canSubmit ? onSubmit : null,
            child: Text(submitLabel),
          ),
      ],
    );
  }
}

/// The collapsible outgoing-changes preview: a toggle button and, when open,
/// the `into...from` range diff (what [from] adds since it forked off [into])
/// in a bordered [DiffView].
///
/// Self-contained: pass the *current* branch texts and rebuild on form edits
/// (the sheets already setState on every keystroke for validation). A change
/// to either branch re-fetches, debounced by [kInputDebounce] so a remote
/// `git diff` doesn't fire per keystroke; other form edits rebuild this
/// widget with identical [from]/[into] and are ignored.
class ForgeDiffPreview extends ConsumerStatefulWidget {
  final String repoPath;

  /// The contributing branch (GitHub "head" / GitLab "source"), trimmed.
  final String from;

  /// The receiving branch (GitHub "base" / GitLab "target"), trimmed.
  final String into;

  /// Shown while either branch field is empty, naming the sheet's own
  /// vocabulary ("Set head and base branches to preview.").
  final String emptyHint;

  const ForgeDiffPreview({
    super.key,
    required this.repoPath,
    required this.from,
    required this.into,
    required this.emptyHint,
  });

  @override
  ConsumerState<ForgeDiffPreview> createState() => _ForgeDiffPreviewState();
}

class _ForgeDiffPreviewState extends ConsumerState<ForgeDiffPreview> {
  bool _show = false;
  Future<String>? _future;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (widget.from.isEmpty || widget.into.isEmpty) {
      _future = null;
      return;
    }
    _future = ref
        .read(gitServiceProvider)
        .diffRange(widget.repoPath, '${widget.into}...${widget.from}');
  }

  @override
  void didUpdateWidget(ForgeDiffPreview old) {
    super.didUpdateWidget(old);
    if (!_show) return;
    if (old.from != widget.from || old.into != widget.into) {
      _debounce?.cancel();
      _debounce = Timer(kInputDebounce, () {
        if (mounted) setState(_refresh);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: AppPushButton(
            controlSize: ControlSize.small,
            secondary: true,
            onPressed: () => setState(() {
              _show = !_show;
              if (_show) _refresh();
            }),
            child: Text(_show ? 'Hide preview' : 'Preview changes'),
          ),
        ),
        if (_show) ...[
          const SizedBox(height: 8),
          Container(
            height: 220,
            decoration: BoxDecoration(
              border: Border.all(color: MacosColors.separatorColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: FutureBuilder<String>(
              future: _future,
              builder: (context, snap) {
                if (_future == null) {
                  return Center(
                    child: Text(
                      widget.emptyHint,
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
                        displayError(snap.error!),
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
