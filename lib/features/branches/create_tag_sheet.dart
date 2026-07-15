import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../common/actions.dart';
import '../common/escape_dismissible.dart';
import '../common/field_styles.dart';
import '../common/sized_sheet.dart';

/// Creates a tag — annotated by default, at HEAD or at a commit handed in by
/// the History panel's "Tag `<sha>`…" menu item.
///
/// The sheet exists to defuse git's most surprising tag behavior: `git push`
/// does not send tags, so a tag created and forgotten silently stays local.
/// The "Push to `<remote>` after creating" checkbox makes that decision explicit
/// at the moment the tag is born, and both it and the annotated toggle
/// remember their last use (see [AppSettingsNotifier.setTagDefaults]).
///
/// Pops `true` when a tag was created (whether or not a requested push then
/// succeeded — the tag exists either way, and only the push failure is
/// reported), so the caller knows to refresh.
class CreateTagSheet extends ConsumerStatefulWidget {
  final String repoPath;

  /// The commit to tag — null tags HEAD.
  final String? initialRef;

  /// Human-readable form of [initialRef] for the target line, e.g.
  /// `abc1234 — subject`.
  final String? initialRefLabel;

  const CreateTagSheet({
    super.key,
    required this.repoPath,
    this.initialRef,
    this.initialRefLabel,
  });

  @override
  ConsumerState<CreateTagSheet> createState() => _CreateTagSheetState();
}

class _CreateTagSheetState extends ConsumerState<CreateTagSheet> {
  final _name = TextEditingController();
  final _message = TextEditingController();
  late bool _annotated;
  late bool _pushAfter;
  bool _submitting = false;

  /// True once the user typed in the message field themselves; until then the
  /// message mirrors the tag name (a release tag's message is its name more
  /// often than not, and a mirrored default is one field less to fill).
  bool _messageEdited = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(appSettingsProvider);
    _annotated = settings.tagAnnotatedByDefault;
    _pushAfter = settings.tagPushAfterCreate;
  }

  @override
  void dispose() {
    _name.dispose();
    _message.dispose();
    super.dispose();
  }

  /// Client-side approximation of `git check-ref-format` for one-component
  /// tag names — enough to catch every common mistake with a specific
  /// message before a round trip. git itself remains the authority (and
  /// `--end-of-options` already keeps any name out of argv-option position).
  static String? nameProblem(String name) {
    if (name.isEmpty) return null; // emptiness disables the button silently
    if (name.contains(RegExp(r'\s'))) return 'No spaces in a tag name.';
    const forbidden = ['~', '^', ':', '?', '*', '[', '\\'];
    for (final ch in forbidden) {
      if (name.contains(ch)) return 'A tag name cannot contain "$ch".';
    }
    if (name.contains('..')) return 'A tag name cannot contain "..".';
    if (name.contains('@{')) return 'A tag name cannot contain "@{".';
    if (name.startsWith('-')) return 'A tag name cannot start with "-".';
    if (name.startsWith('/') || name.endsWith('/') || name.contains('//')) {
      return 'A tag name cannot start or end with "/" (or contain "//").';
    }
    if (name.startsWith('.') || name.endsWith('.')) {
      return 'A tag name cannot start or end with ".".';
    }
    if (name.endsWith('.lock')) return 'A tag name cannot end with ".lock".';
    if (name.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      return 'A tag name cannot contain control characters.';
    }
    return null;
  }

  bool get _valid {
    final name = _name.text.trim();
    if (name.isEmpty || nameProblem(name) != null) return false;
    if (_annotated && _message.text.trim().isEmpty) return false;
    return true;
  }

  /// origin when configured, else the first remote — the same choice
  /// [remoteTagsProvider] makes, so the checkbox and the badges agree.
  String? get _remote {
    final remotes = ref.watch(remotesProvider(widget.repoPath)).value;
    if (remotes == null || remotes.isEmpty) return null;
    return remotes.contains('origin') ? 'origin' : remotes.first;
  }

  Future<void> _submit() async {
    if (!_valid || _submitting) return;
    final name = _name.text.trim();
    final message = _annotated ? _message.text.trim() : null;
    final remote = _remote;
    setState(() => _submitting = true);

    final git = ref.read(gitServiceProvider);

    // Phase 1: create. Only a failure HERE (a name collision, usually) keeps
    // the sheet open for another attempt.
    final created = await runAction(context, () async {
      await git.createTag(
        widget.repoPath,
        name,
        message: message,
        ref: widget.initialRef ?? 'HEAD',
      );
    });
    if (!mounted) return;
    if (!created) {
      setState(() => _submitting = false);
      return;
    }

    // Remember what they actually used, so the next tag starts from it.
    // Fire-and-forget: a failed preferences write must not block the flow.
    unawaited(
      ref
          .read(appSettingsProvider.notifier)
          .setTagDefaults(annotated: _annotated, pushAfterCreate: _pushAfter),
    );

    // Phase 2: the push. The tag EXISTS from here on — a failed push
    // surfaces its own error (with the full output in the Output view) and
    // the sheet still closes, leaving an intact local tag the tags list will
    // show as "local only".
    if (_pushAfter && remote != null) {
      final label = 'git push $remote refs/tags/$name';
      final log = ref.read(outputLogProvider.notifier);
      await runAction(context, () async {
        try {
          log.logResult(
            label,
            await git.pushTag(widget.repoPath, name, remote: remote),
          );
        } on GitException catch (e) {
          log.logResult(label, e.result);
          rethrow;
        }
      }, dock: true);
      if (!mounted) return;
      refreshRemoteTags(ref, widget.repoPath);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final remote = _remote;
    final problem = nameProblem(_name.text.trim());

    return EscapeDismissible(
      child: SizedSheet(
        width: kSheetWidth,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Create Tag', style: typography.title2),
              SheetDescription(
                'At ${widget.initialRefLabel ?? 'HEAD — the current commit'}.',
              ),
              const SizedBox(height: 14),

              MacosTextField(
                controller: _name,
                placeholder: 'v1.2.23',
                placeholderStyle: kAppPlaceholderStyle,
                autofocus: true,
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                onChanged: (v) => setState(() {
                  if (!_messageEdited) _message.text = v.trim();
                }),
                onSubmitted: (_) => _submit(),
              ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    problem,
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemRedColor,
                    ),
                  ),
                ),

              const SizedBox(height: 12),
              Row(
                children: [
                  MacosCheckbox(
                    value: _annotated,
                    onChanged: _submitting
                        ? null
                        : (v) => setState(() => _annotated = v),
                  ),
                  const SizedBox(width: 8),
                  const Flexible(child: Text('Annotated tag')),
                ],
              ),
              const FieldHint(
                'An annotated tag records who tagged, when, and a message — '
                'the right shape for a release. A lightweight tag is a bare '
                'pointer.',
              ),
              if (_annotated) ...[
                const SizedBox(height: 8),
                MacosTextField(
                  controller: _message,
                  placeholder: 'Tag message',
                  placeholderStyle: kAppPlaceholderStyle,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  maxLines: 3,
                  onChanged: (_) => setState(() => _messageEdited = true),
                ),
              ],

              if (remote != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    MacosCheckbox(
                      value: _pushAfter,
                      onChanged: _submitting
                          ? null
                          : (v) => setState(() => _pushAfter = v),
                    ),
                    const SizedBox(width: 8),
                    // Flexible: a long remote name must wrap, not overflow
                    // the fixed-width sheet.
                    Flexible(child: Text('Push to $remote after creating')),
                  ],
                ),
                const FieldHint(
                  'git push does not send tags on its own — an unpushed tag '
                  'exists only on this machine.',
                ),
              ],

              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: _valid && !_submitting ? _submit : null,
                    child: Text(_submitting ? 'Creating…' : 'Create Tag'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
