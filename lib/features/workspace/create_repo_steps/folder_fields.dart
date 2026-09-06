/// The create sheet's folder-choosing rows: pick a folder on this Mac, or type
/// one on the host with a Browse button beside it.
///
/// Four near-identical layouts — "adopt this folder" and "create inside this
/// parent", each in a local and an SSH variant — plus the commit-all toggle
/// that belongs to the adopted-folder flow (MADR 0033 Phase 5).
library;

import 'package:flutter/cupertino.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../common/buttons.dart';
import '../../common/field_styles.dart';
import '../wizard.dart';
import '../workspace_widgets.dart';

/// A label, the chosen path (or a grey placeholder), and a Choose… button.
class LocalFolderRow extends StatelessWidget {
  final String label;

  /// The chosen path; null renders the "No folder chosen" placeholder.
  final String? path;

  /// Null while a picker is already in flight.
  final VoidCallback? onChoose;

  final String hint;

  const LocalFolderRow({
    super.key,
    required this.label,
    required this.path,
    required this.onChoose,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                path ?? 'No folder chosen',
                style: typography.body.copyWith(
                  color: path == null ? MacosColors.systemGrayColor : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            AppPushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: onChoose,
              child: const Text('Choose…'),
            ),
          ],
        ),
        WizardHint(hint),
      ],
    );
  }
}

/// A label, an absolute-path field, and a Browse… button that opens the host's
/// directory browser.
class RemotePathRow extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String placeholder;
  final VoidCallback onBrowse;
  final VoidCallback onChanged;
  final String hint;

  /// Rendered below the hint — the create sheet uses it for the
  /// "Create parent folders if missing" toggle and its own hint.
  final Widget? trailing;

  const RemotePathRow({
    super.key,
    required this.label,
    required this.controller,
    required this.placeholder,
    required this.onBrowse,
    required this.onChanged,
    required this.hint,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: typography.caption1),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: MacosTextField(
                controller: controller,
                placeholder: placeholder,
                placeholderStyle: kAppPlaceholderStyle,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (_) => onChanged(),
              ),
            ),
            const SizedBox(width: 8),
            AppPushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: onBrowse,
              child: const Text('Browse…'),
            ),
          ],
        ),
        WizardHint(hint),
        ?trailing,
      ],
    );
  }
}

/// "Commit all existing contents" — the adopted-folder flow's initial-commit
/// opt-in.
class CommitAllToggle extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;

  const CommitAllToggle({super.key, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) => WorkspaceToggleRow(
    on: on,
    onTap: onTap,
    onIcon: CupertinoIcons.doc_on_doc_fill,
    offIcon: CupertinoIcons.doc_on_doc,
    label: 'Commit all existing contents (initial commit)',
  );
}
