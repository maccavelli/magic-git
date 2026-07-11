import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../common/actions.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';

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
  VoidCallback? _escInterceptorDisposer;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Escape dismissal itself comes from the EscapeDismissible wrapper at
    // the call site (registry-based, so it works the moment the sheet opens
    // — even while the hook preview is loading and nothing has focus yet).
    // This interceptor only *blocks* it mid-commit: don't yank the sheet out
    // from under an in-flight `git commit`.
    _escInterceptorDisposer ??= EscapeInterceptor.of(context, () => _committing);
  }

  @override
  void dispose() {
    _escInterceptorDisposer?.call();
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
      // Focus the message field once it exists — in review mode it's read-only
      // and doesn't autofocus, and with nothing focused inside the sheet, key
      // events dispatch from the route's focus scope *above* this sheet's
      // CallbackShortcuts, leaving ⌘↩ (Accept) and ⎋ (Cancel) dead until a
      // click. (Manual mode's autofocus is covered too; this is idempotent.)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
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

  /// Commits the reviewed/edited message. When [push] is set (Commit & Push,
  /// ⌘⇧↩) the sheet pops with `true` so the caller runs its own push right
  /// after — the panel owns the logged/guarded push path, so it isn't
  /// reimplemented here.
  Future<void> _commit({bool push = false}) async {
    // Entry guard, not just a disabled button: the keyboard bindings above
    // capture `canAccept` from the previous build, so two rapid ⌘↩ presses in
    // one event batch would otherwise both get through and commit twice.
    if (_committing) return;
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
      // we're about to close. Skipped when we're about to push (which advances
      // the remote and refreshes anyway).
      if (!push) {
        unawaited(
          ref.read(connectionProvider.notifier).fetchInBackground(repoPath),
        );
      }
      if (context.mounted) Navigator.of(context).pop(push);
    }
  }

  /// Commit messages are conventionally hard-wrapped at this many columns
  /// (hooks and CLI tools emit them that way) — the field is sized to show
  /// exactly this many, so an authored line never soft-wraps.
  static const int _messageColumns = 80;

  /// The message is rendered in the system monospace face: hard-wrapped
  /// text keeps its authored shape and column indentation (bullets, code
  /// snippets) stays aligned — a proportional face can't do either.
  static TextStyle _messageStyle(MacosTypography typography) =>
      typography.body.copyWith(
        fontFamily: 'Menlo',
        fontFamilyFallback: const ['Monaco', 'Courier New'],
        fontSize: 12,
        height: 1.4,
      );

  /// Sheet width = [_messageColumns] of the message font + the field's own
  /// chrome + the dialog padding, capped to the window. Measured from real
  /// type metrics so a font substitution can't silently break the fit.
  double _sheetWidth(BuildContext context) {
    final mono = _messageStyle(MacosTheme.of(context).typography);
    final line = TextPainter(
      text: TextSpan(text: 'M' * _messageColumns, style: mono),
      textDirection: TextDirection.ltr,
    )..layout();
    const fieldChrome = 12.0; // MacosTextField padding + border
    const dialogPadding = 40.0; // EdgeInsets.all(20)
    final ideal = line.width + fieldChrome + dialogPadding;
    final cap = MediaQuery.sizeOf(context).width - 40;
    return ideal.clamp(420.0, cap < 420.0 ? 420.0 : cap);
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final n = widget.stagedCount;
    final canAccept =
        !_committing && !_loadingPreview && _message.text.trim().isNotEmpty;
    final keymap = ref.watch(keymapProvider);

    return CallbackShortcuts(
      bindings: {
        ...resolveShortcuts(keymap, {
          'commit.confirm': canAccept ? () => _commit() : null,
          'commit.confirmAndPush': canAccept ? () => _commit(push: true) : null,
        }),
        // No Escape here: the EscapeDismissible wrapper (call site) owns
        // dismissal, gated by the mid-commit interceptor registered in
        // didChangeDependencies.
      },
      child: SizedSheet(
        // Sized from the type, not a magic number: wide enough that the
        // message field shows exactly [_messageColumns] monospace columns.
        // Hook-generated messages arrive hard-wrapped at ~72–80 columns; in
        // a narrower proportional field every authored line re-wrapped into
        // two ragged visual lines and column indentation fell apart.
        width: _sheetWidth(context),
        // Height tracks content via the text field's minLines/maxLines;
        // AnimatedSize eases between heights instead of snapping.
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
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
                const SheetDescription(
                  'Records the listed changes as a new commit on the current '
                  'branch. Accept + Push also sends it to the remote right '
                  'away.',
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
                    style: _messageStyle(typography),
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
      _ => (
        'A short summary line works best — add detail on following lines '
            'if needed.',
        MacosColors.systemGrayColor,
      ),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(text, style: typography.caption1.copyWith(color: color));
  }

  Widget _buttons(BuildContext context, bool canAccept) {
    // A Wrap (not a Row): four large buttons don't fit the standard sheet
    // width on one line when the Edit affordance is showing — let the row
    // break rather than overflow.
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: _committing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_committing)
          const ProgressCircle()
        else if (!_loadingPreview) ...[
          if (_generated && !_editable)
            PushButton(
              controlSize: ControlSize.large,
              secondary: true,
              onPressed: _beginEdit,
              child: const Text('Edit'),
            ),
          PushButton(
            controlSize: ControlSize.large,
            onPressed: canAccept ? () => _commit(push: true) : null,
            child: const Text('Accept + Push'),
          ),
          PushButton(
            controlSize: ControlSize.large,
            onPressed: canAccept ? () => _commit() : null,
            child: const Text('Accept'),
          ),
        ],
      ],
    );
  }
}
