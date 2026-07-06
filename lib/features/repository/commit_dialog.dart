import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/field_styles.dart';

/// Commit sheet with a hook-aware flow:
///
///  * When a `prepare-commit-msg` hook is installed, the sheet first runs it to
///    generate a message, then shows that message read-only with **Edit** and
///    **Accept** — accept commits it as-is, edit unlocks the field to tweak it
///    mid-stream before accepting.
///  * With no hook (or if the hook produces nothing) it falls back to a plain
///    editable field. Either way the confirm button is **Accept**, so there is
///    never a redundant second "Commit" alongside the one that opened the sheet.
class CommitDialog extends ConsumerStatefulWidget {
  final String repoPath;
  final int stagedCount;

  const CommitDialog({
    super.key,
    required this.repoPath,
    required this.stagedCount,
  });

  @override
  ConsumerState<CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends ConsumerState<CommitDialog> {
  final _message = TextEditingController();
  final _focus = FocusNode();

  bool _loadingPreview = true; // running the hook to preview a message
  bool _committing = false;
  bool _generated = false; // a hook produced a message we're reviewing
  bool _editable = false; // the message field accepts edits
  String? _error; // preview generation failed (non-fatal: fall back to manual)

  String get repoPath => widget.repoPath;

  @override
  void initState() {
    super.initState();
    _generatePreview();
  }

  @override
  void dispose() {
    _message.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Runs the prepare-commit-msg hook (if any) to preview a message. A generated
  /// message opens review mode; no hook / empty / failure opens manual entry.
  Future<void> _generatePreview() async {
    final git = ref.read(gitServiceProvider);
    try {
      final msg = await git.generateCommitMessage(repoPath);
      if (!mounted) return;
      setState(() {
        _loadingPreview = false;
        if (msg != null && msg.trim().isNotEmpty) {
          _message.text = msg.trim();
          _generated = true;
          _editable = false; // review: read-only until the user hits Edit
        } else {
          _editable = true; // manual: empty, editable field
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPreview = false;
        _editable = true;
        _error = 'Could not generate a message. Enter one manually.\n$e';
      });
    }
  }

  void _beginEdit() {
    setState(() => _editable = true);
    _focus.requestFocus();
  }

  Future<void> _commit() async {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    setState(() => _committing = true);
    final git = ref.read(gitServiceProvider);
    // Commit with the exact reviewed/edited message; a well-behaved hook skips
    // regeneration when a message is supplied (the same assumption as override).
    final ok = await runAction(
      context,
      () => git.commit(repoPath, message: message),
    );
    if (!mounted) return;
    setState(() => _committing = false);
    if (ok) {
      ref.invalidate(statusProvider(repoPath));
      ref.invalidate(logProvider(repoPath));
      ref.invalidate(refsProvider(repoPath));
      // Best-effort — refreshes ahead/behind right away instead of leaving it
      // to the next manual/auto fetch. Routed through the connection
      // controller (not this dialog's own `ref`) since it outlives the sheet
      // we're about to close.
      unawaited(ref.read(connectionProvider.notifier).fetchInBackground(repoPath));
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final n = widget.stagedCount;
    final canAccept =
        !_committing && !_loadingPreview && _message.text.trim().isNotEmpty;
    final keymap = ref.watch(keymapProvider);

    return CallbackShortcuts(
      bindings: resolveShortcuts(keymap, {
        'commit.confirm': canAccept ? _commit : null,
      }),
      child: MacosSheet(
        // Width and height both track content: IntrinsicWidth sizes to the
        // widest child (mainly the text field's current longest line, per
        // its own text-aware intrinsic-width computation), clamped to a sane
        // range so an empty message isn't cramped and a single very long
        // unwrapped line doesn't stretch the sheet absurdly wide. Height
        // already tracks content via the text field's minLines/maxLines.
        // AnimatedSize eases between sizes instead of snapping, since both
        // dimensions can change on every keystroke.
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 420, maxWidth: 680),
            child: IntrinsicWidth(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Commit $n file${n == 1 ? '' : 's'}',
                      style: typography.title2,
                    ),
                    const SizedBox(height: 12),
                    if (_loadingPreview)
                      _previewLoading(context)
                    else ...[
                      MacosTextField(
                        controller: _message,
                        focusNode: _focus,
                        readOnly: !_editable,
                        autofocus: _editable,
                        placeholder: _generated ? null : 'Commit message',
                        minLines: 1,
                        maxLines: 12,
                        decoration: kAppTextFieldDecoration,
                        focusedDecoration: kAppTextFieldFocusedDecoration,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 8),
                      _hint(context),
                    ],
                    const SizedBox(height: 16),
                    _buttons(context, canAccept),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewLoading(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    return SizedBox(
      height: 120,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const ProgressCircle(),
          const SizedBox(height: 12),
          Text(
            'Generating commit message…',
            style: typography.body.copyWith(color: MacosColors.systemGrayColor),
          ),
        ],
      ),
    );
  }

  Widget _hint(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final (text, color) = switch (this) {
      _ when _error != null => (_error!, MacosColors.systemOrangeColor),
      _ when _generated && !_editable => (
        'Generated by your prepare-commit-msg hook. Accept to commit, or Edit '
            'to change it.',
        MacosColors.systemGrayColor,
      ),
      _ when _generated && _editable => (
        'Editing the generated message. Accept to commit.',
        MacosColors.systemGrayColor,
      ),
      _ => ('', MacosColors.systemGrayColor),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(text, style: typography.caption1.copyWith(color: color));
  }

  Widget _buttons(BuildContext context, bool canAccept) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: _committing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        if (_committing)
          const ProgressCircle()
        else if (!_loadingPreview) ...[
          if (_generated && !_editable) ...[
            PushButton(
              controlSize: ControlSize.large,
              secondary: true,
              onPressed: _beginEdit,
              child: const Text('Edit'),
            ),
            const SizedBox(width: 8),
          ],
          PushButton(
            controlSize: ControlSize.large,
            onPressed: canAccept ? _commit : null,
            child: const Text('Accept'),
          ),
        ],
      ],
    );
  }
}
