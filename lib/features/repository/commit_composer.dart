import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/settings/keymap.dart';
import '../common/buttons.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import 'commit_composer_controller.dart';

enum CommitComposerPresentation { collapsed, compact, expanded }

class CommitComposer extends ConsumerStatefulWidget {
  final CommitComposerController controller;
  final CommitComposerPresentation presentation;
  final String branchLabel;
  final Future<void> Function(bool push) onAccept;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;
  final bool focused;
  final String? policyAdvisory;

  const CommitComposer({
    super.key,
    required this.controller,
    required this.presentation,
    required this.branchLabel,
    required this.onAccept,
    this.onExpand,
    this.onCollapse,
    this.focused = false,
    this.policyAdvisory,
  });

  @override
  ConsumerState<CommitComposer> createState() => _CommitComposerState();
}

class _CommitComposerState extends ConsumerState<CommitComposer> {
  static const int _messageColumns = 80;
  final _message = TextEditingController();
  final _focus = FocusNode(debugLabel: 'commit-composer-message');
  final _coAuthorName = TextEditingController();
  final _coAuthorEmail = TextEditingController();
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _message.text = widget.controller.message;
    widget.controller.addListener(_syncFromController);
    if (widget.presentation != CommitComposerPresentation.collapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.expand();
      });
    }
    if (widget.focused) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focus.requestFocus(),
      );
    }
  }

  @override
  void didUpdateWidget(CommitComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncFromController);
      widget.controller.addListener(_syncFromController);
      _syncFromController();
    }
    if (oldWidget.presentation == CommitComposerPresentation.collapsed &&
        widget.presentation != CommitComposerPresentation.collapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.expand();
      });
    }
  }

  void _syncFromController() {
    if (!mounted) return;
    if (_message.text != widget.controller.message) {
      _syncing = true;
      _message.value = TextEditingValue(
        text: widget.controller.message,
        selection: TextSelection.collapsed(
          offset: widget.controller.message.length,
        ),
      );
      _syncing = false;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromController);
    _message.dispose();
    _focus.dispose();
    _coAuthorName.dispose();
    _coAuthorEmail.dispose();
    super.dispose();
  }

  static TextStyle _messageStyle(MacosTypography typography) =>
      typography.body.copyWith(
        fontFamily: 'Menlo',
        fontFamilyFallback: const ['Monaco', 'Courier New'],
        fontSize: 12,
        height: 1.4,
      );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final count = controller.stagedCount;
    final summary = '$count staged file${count == 1 ? '' : 's'}';
    if (widget.presentation == CommitComposerPresentation.collapsed) {
      return Row(
        children: [
          const MacosIcon(CupertinoIcons.square_pencil, size: 16),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '$summary · ${widget.branchLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MacosTheme.of(context).typography.caption1,
            ),
          ),
          const SizedBox(width: 8),
          Builder(
            builder: (context) {
              // Teach the live focus-composer chord (⌘G default, remaps
              // honored) on the button that does the same thing (0009 L10).
              final bindings = ref.watch(
                keymapProvider,
              )['repository.focusCommit'];
              final suffix = (bindings == null || bindings.isEmpty)
                  ? ''
                  : ' (${bindings.first.label})';
              return MacosTooltip(
                message: 'Focus commit composer$suffix',
                child: AppPushButton(
                  controlSize: ControlSize.regular,
                  secondary: false,
                  onPressed: count == 0
                      ? null
                      : () {
                          controller.expand();
                          widget.onExpand?.call();
                        },
                  child: const Text('Commit…'),
                ),
              );
            },
          ),
        ],
      );
    }

    // 0009 H8: the docked composer is the production commit surface — the
    // advertised commit chords (⌘↩ / ⇧⌘↩ by default, remaps honored) must
    // work here, not only on the sheet-hosted CommitDialog. Dialog/sheet-
    // scoped CallbackShortcuts deliberately fire while typing (see
    // panel_shortcuts.dart).
    return CallbackShortcuts(
      bindings: resolveShortcuts(ref.watch(keymapProvider), {
        'commit.confirm': controller.canAccept
            ? () => unawaited(widget.onAccept(false))
            : null,
        'commit.confirmAndPush': controller.canAccept
            ? () => unawaited(widget.onAccept(true))
            : null,
      }),
      child: Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape &&
              !controller.committing) {
            controller.collapse();
            widget.onCollapse?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'Commit $count file${count == 1 ? '' : 's'}',
                    style: MacosTheme.of(context).typography.title3,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$summary · ${widget.branchLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (controller.previewStale)
                    InlineActionButton(
                      label: 'Regenerate',
                      icon: CupertinoIcons.refresh,
                      onPressed: () =>
                          controller.ensurePreview(regenerate: true),
                    ),
                  InlineActionButton(
                    label: controller.assistanceExpanded
                        ? 'Hide Assistance'
                        : 'Assistance',
                    icon: CupertinoIcons.lightbulb,
                    onPressed: controller.committing
                        ? null
                        : controller.toggleAssistance,
                  ),
                  InlineActionButton(
                    label: 'Clear',
                    icon: CupertinoIcons.clear,
                    onPressed: controller.committing
                        ? null
                        : controller.clearDraft,
                  ),
                  if (widget.onCollapse != null)
                    InlineActionButton(
                      label: 'Collapse',
                      icon: CupertinoIcons.chevron_down,
                      onPressed: controller.committing
                          ? null
                          : () {
                              controller.collapse();
                              widget.onCollapse?.call();
                            },
                    ),
                ],
              ),
              if (controller.gpgSignConfigured)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'GPG signing is configured; commits use --no-gpg-sign because '
                    'remote signing is unavailable.',
                    style: MacosTheme.of(context).typography.caption1.copyWith(
                      color: MacosColors.systemOrangeColor,
                    ),
                  ),
                ),
              if (controller.assistanceExpanded) ...[
                const SizedBox(height: 8),
                _assistancePanel(context, controller),
              ],
              const SizedBox(height: 8),
              if (controller.loadingPreview && controller.message.isEmpty)
                const Expanded(child: Center(child: ProgressCircle()))
              else
                Expanded(
                  child: MacosTextField(
                    controller: _message,
                    focusNode: _focus,
                    readOnly: !controller.editable,
                    maxLines: null,
                    expands: true,
                    placeholder: 'Commit message',
                    placeholderStyle: kAppPlaceholderStyle,
                    style: _messageStyle(MacosTheme.of(context).typography),
                    decoration: kAppTextFieldDecoration,
                    focusedDecoration: kAppTextFieldFocusedDecoration,
                    onChanged: (value) {
                      if (!_syncing) controller.updateMessage(value);
                    },
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: _statusText(context, controller)),
                  if (controller.generated && !controller.editable)
                    AppPushButton(
                      controlSize: ControlSize.regular,
                      secondary: true,
                      onPressed: controller.beginEdit,
                      child: const Text('Edit'),
                    ),
                  const SizedBox(width: 8),
                  // Both ways of accepting are accented: each is a complete,
                  // correct way to finish the commit, and greying one implied
                  // it was the lesser choice rather than simply the other one.
                  // Accept stays the *default* — ⌘↩ and the focus ring say
                  // which one Return takes; colour only says "you can do this".
                  AppPushButton(
                    controlSize: ControlSize.regular,
                    onPressed: controller.canAccept
                        ? () => widget.onAccept(true)
                        : null,
                    child: const Text('Accept + Push'),
                  ),
                  const SizedBox(width: 8),
                  AppPushButton(
                    controlSize: ControlSize.regular,
                    onPressed: controller.canAccept
                        ? () => widget.onAccept(false)
                        : null,
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _assistancePanel(
    BuildContext context,
    CommitComposerController controller,
  ) {
    final typography = MacosTheme.of(context).typography;
    final template = controller.template;
    final templateAvailable = template != null && template.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: MacosColors.controlBackgroundColor,
        border: Border.all(color: MacosColors.separatorColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Commit assistance', style: typography.caption1),
              const Spacer(),
              Text(
                'Request/check advisory: '
                '${widget.policyAdvisory ?? 'Not checked'}',
                key: const ValueKey('commit-policy-advisory'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (controller.recentSubjects.isNotEmpty)
                Expanded(
                  child: MacosPopupButton<String>(
                    key: const ValueKey('recent-commit-subjects'),
                    hint: const Text('Use a recent subject…'),
                    items: [
                      for (final subject in controller.recentSubjects)
                        MacosPopupMenuItem(
                          value: subject,
                          child: Text(subject),
                        ),
                    ],
                    onChanged: controller.committing
                        ? null
                        : (subject) {
                            if (subject != null) {
                              controller.useRecentSubject(subject);
                            }
                          },
                  ),
                )
              else
                const Expanded(
                  child: Text(
                    'No landed History subjects cached.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(width: 6),
              AppPushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed:
                    controller.committing || controller.loadingRecentSubjects
                    ? null
                    : () => unawaited(controller.loadRecentSubjects()),
                child: Text(
                  controller.loadingRecentSubjects
                      ? 'Loading recent…'
                      : 'Load recent',
                ),
              ),
              const SizedBox(width: 6),
              AppPushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: controller.committing || controller.loadingTemplate
                    ? null
                    : !controller.templateLoaded
                    ? () => unawaited(controller.loadTemplate())
                    : templateAvailable && controller.message.trim().isEmpty
                    ? controller.useTemplate
                    : null,
                child: Text(
                  controller.loadingTemplate
                      ? 'Loading template…'
                      : !controller.templateLoaded
                      ? 'Load template'
                      : templateAvailable
                      ? 'Use template'
                      : 'No template',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: MacosTextField(
                  key: const ValueKey('co-author-name'),
                  controller: _coAuthorName,
                  placeholder: 'Co-author name',
                  placeholderStyle: kAppPlaceholderStyle,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  enabled: !controller.committing,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: MacosTextField(
                  key: const ValueKey('co-author-email'),
                  controller: _coAuthorEmail,
                  placeholder: 'email@example.com',
                  placeholderStyle: kAppPlaceholderStyle,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  enabled: !controller.committing,
                  onSubmitted: (_) => _addCoAuthor(controller),
                ),
              ),
              const SizedBox(width: 6),
              AppPushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: controller.committing
                    ? null
                    : () => _addCoAuthor(controller),
                child: const Text('Add co-author'),
              ),
            ],
          ),
          if (controller.coAuthors.isNotEmpty) ...[
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final author in controller.coAuthors) ...[
                    InlineActionButton(
                      label: '${author.name} <${author.email}>',
                      icon: CupertinoIcons.xmark_circle,
                      onPressed: controller.committing
                          ? null
                          : () => controller.removeCoAuthor(author),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _addCoAuthor(CommitComposerController controller) {
    if (!controller.addCoAuthor(_coAuthorName.text, _coAuthorEmail.text)) {
      return;
    }
    _coAuthorName.clear();
    _coAuthorEmail.clear();
  }

  Widget _statusText(
    BuildContext context,
    CommitComposerController controller,
  ) {
    final text =
        controller.error ??
        (controller.previewStale
            ? 'Staged changes changed; review this draft or regenerate.'
            : controller.generated && !controller.editable
            ? 'Generated by prepare-commit-msg. Review, Edit, or Accept.'
            : 'Keep the summary concise; wrap message lines at $_messageColumns columns.');
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: MacosTheme.of(context).typography.caption1.copyWith(
        color: controller.error == null
            ? MacosColors.systemGrayColor
            : MacosColors.systemOrangeColor,
      ),
    );
  }
}
