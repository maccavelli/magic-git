import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Dialog;
import 'package:macos_ui/macos_ui.dart';

/// Runs a mutating [action], surfacing any failure in a macOS error dialog.
/// Returns true on success — callers use this to decide whether to refresh.
Future<bool> runAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) {
      await showErrorDialog(context, '$e');
    }
    return false;
  }
}

Future<void> showErrorDialog(BuildContext context, String message) {
  return showMacosAlertDialog<void>(
    context: context,
    builder: (context) => MacosAlertDialog(
      appIcon: const MacosIcon(
        CupertinoIcons.exclamationmark_triangle,
        size: 56,
        color: MacosColors.systemRedColor,
      ),
      title: const Text('Error'),
      message: Text(message, textAlign: TextAlign.center),
      primaryButton: PushButton(
        controlSize: ControlSize.large,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('OK'),
      ),
    ),
  );
}

/// A multi-choice dialog for a guardrail decision (e.g. "stash & switch",
/// "switch anyway", "cancel"). [primary] is the recommended/safe default; the
/// [secondary] options stack beneath it, secondary-styled. Returns the chosen
/// value, or null if dismissed. Used by the branch-switch and pre-push guards.
Future<T?> chooseAction<T>(
  BuildContext context, {
  required String title,
  required String message,
  required String primaryLabel,
  required T primaryValue,
  required List<(String, T)> secondary,
}) {
  // MacosAlertDialog supports only a primary + secondary button, so a genuine
  // three-way guardrail choice is rendered in a matching native frame with the
  // options stacked full-width.
  return showMacosAlertDialog<T>(
    context: context,
    builder: (context) {
      final theme = MacosTheme.of(context);
      final brightness = MacosTheme.brightnessOf(context);
      return Dialog(
        backgroundColor: brightness.resolve(
          CupertinoColors.systemGrey6.color,
          MacosColors.controlBackgroundColor.darkColor,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MacosIcon(
                  CupertinoIcons.question_circle,
                  size: 56,
                  color: MacosColors.systemBlueColor,
                ),
                const SizedBox(height: 16),
                DefaultTextStyle(
                  style: theme.typography.headline,
                  textAlign: TextAlign.center,
                  child: Text(title),
                ),
                const SizedBox(height: 10),
                DefaultTextStyle(
                  style: theme.typography.body,
                  textAlign: TextAlign.center,
                  child: Text(message),
                ),
                const SizedBox(height: 18),
                _choiceButton(context, primaryLabel, primaryValue, true),
                for (final (label, value) in secondary) ...[
                  const SizedBox(height: 8),
                  _choiceButton(context, label, value, false),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

Widget _choiceButton<T>(
  BuildContext context,
  String label,
  T value,
  bool primary,
) => Row(
  children: [
    Expanded(
      child: PushButton(
        controlSize: ControlSize.large,
        secondary: !primary,
        onPressed: () => Navigator.of(context).pop(value),
        child: Text(label),
      ),
    ),
  ],
);

/// Confirms an outward-facing action (e.g. approving an MR, retrying a
/// pipeline). Returns true only if the user explicitly confirms.
///
/// [cancelLabel] renames the dismiss button (default "Cancel"). Set
/// [destructive] for an irreversible delete: the header icon becomes a red
/// trash can instead of the neutral blue question mark.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showMacosAlertDialog<bool>(
    context: context,
    builder: (context) => MacosAlertDialog(
      appIcon: MacosIcon(
        destructive
            ? CupertinoIcons.trash
            : CupertinoIcons.question_circle,
        size: 56,
        color: destructive
            ? MacosColors.systemRedColor
            : MacosColors.systemBlueColor,
      ),
      title: Text(title),
      message: Text(message, textAlign: TextAlign.center),
      primaryButton: PushButton(
        controlSize: ControlSize.large,
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(confirmLabel),
      ),
      secondaryButton: PushButton(
        controlSize: ControlSize.large,
        secondary: true,
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(cancelLabel),
      ),
    ),
  );
  return result ?? false;
}
