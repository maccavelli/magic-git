import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';

import '../common/buttons.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import 'commit_composer_controller.dart';

enum CommitComposerPresentation { collapsed, compact, expanded }

class CommitComposer extends StatefulWidget {
  final CommitComposerController controller;
  final CommitComposerPresentation presentation;
  final String branchLabel;
  final Future<void> Function(bool push) onAccept;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;
  final bool focused;

  const CommitComposer({
    super.key,
    required this.controller,
    required this.presentation,
    required this.branchLabel,
    required this.onAccept,
    this.onExpand,
    this.onCollapse,
    this.focused = false,
  });

  @override
  State<CommitComposer> createState() => _CommitComposerState();
}

class _CommitComposerState extends State<CommitComposer> {
  static const int _messageColumns = 80;
  final _message = TextEditingController();
  final _focus = FocusNode(debugLabel: 'commit-composer-message');
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
          AppPushButton(
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
        ],
      );
    }

    return Focus(
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
                    onPressed: () => controller.ensurePreview(regenerate: true),
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
                AppPushButton(
                  controlSize: ControlSize.regular,
                  secondary: true,
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
    );
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
