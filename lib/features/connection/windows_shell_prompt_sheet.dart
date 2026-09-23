import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import '../../core/settings/tool_catalog.dart';
import '../../core/ssh/windows_host_probe.dart';
import '../common/buttons.dart';
import '../common/copyable_command_block.dart';
import '../common/sized_sheet.dart';

/// Shown when a connect to a Windows host stopped at the shell check (MADR
/// 0070, Amendment 0070.1; 0070-PLAN Phase 4): the host's SSH shell is not
/// Git Bash, so none of Magic Git's commands can run there yet.
///
/// Watches the connection state rather than holding a copy, so Enable's
/// progress and its failure appear here as they happen. Closing it releases
/// the SSH session the stopped connect kept open for Enable.
class WindowsShellPromptSheet extends ConsumerWidget {
  const WindowsShellPromptSheet({super.key, this.onOpenSettings});

  /// Opens Settings, where a custom Git Bash path can be set.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prompt = ref.watch(
      connectionProvider.select((c) => c.windowsShellPrompt),
    );
    // The prompt clears when a connect starts or the sheet is dismissed; the
    // shell pops this route then, so this frame only has to not crash.
    if (prompt == null) return const SizedBox.shrink();
    final typography = MacosTheme.of(context).typography;
    final controller = ref.read(connectionProvider.notifier);
    final caption = typography.caption1.copyWith(
      color: MacosColors.systemGrayColor,
    );

    return SizedSheet(
      width: 520,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const MacosIcon(
                  CupertinoIcons.exclamationmark_triangle_fill,
                  color: MacosColors.systemOrangeColor,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_title(prompt.kind), style: typography.title2),
                ),
              ],
            ),
            SheetDescription(prompt.message),
            ..._body(context, prompt, caption),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppPushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: prompt.enabling
                      ? null
                      : controller.dismissWindowsShellPrompt,
                  child: const Text('Cancel'),
                ),
                if (prompt.kind == WindowsShellPromptKind.notInstalled &&
                    onOpenSettings != null) ...[
                  const SizedBox(width: 8),
                  AppPushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: onOpenSettings,
                    child: const Text('Open Settings'),
                  ),
                ],
                const SizedBox(width: 8),
                AppPushButton(
                  controlSize: ControlSize.large,
                  secondary: prompt.kind == WindowsShellPromptKind.notActive,
                  onPressed: prompt.enabling ? null : controller.retryConnect,
                  child: const Text('Reconnect'),
                ),
                if (prompt.kind == WindowsShellPromptKind.notActive) ...[
                  const SizedBox(width: 8),
                  AppPushButton(
                    controlSize: ControlSize.large,
                    onPressed: prompt.enabling
                        ? null
                        : controller.enableGitBashShell,
                    child: Text(prompt.enabling ? 'Enabling…' : 'Enable'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _title(WindowsShellPromptKind kind) => switch (kind) {
    WindowsShellPromptKind.notActive => 'Git Bash Is Not the SSH Shell',
    WindowsShellPromptKind.notInstalled => 'Git Bash Is Not Installed',
    WindowsShellPromptKind.probeFailed => "Couldn't Check This Windows Host",
  };

  List<Widget> _body(
    BuildContext context,
    WindowsShellPrompt prompt,
    TextStyle caption,
  ) {
    final facts = prompt.facts;
    switch (prompt.kind) {
      case WindowsShellPromptKind.notActive:
        final command = prompt.enableCommand!;
        return [
          const SizedBox(height: 12),
          Text('Git Bash: ${facts!.bashPath}', style: caption),
          const SizedBox(height: 8),
          const FieldHint(
            'Enable sets the OpenSSH default shell for every SSH user of this '
            'host, not only this account.',
          ),
          if (!facts.isAdmin)
            const FieldHint(
              'This account is not an administrator, so Enable will be '
              'refused. Run the command below in an elevated PowerShell on '
              'the host, then Reconnect.',
            ),
          if (prompt.enableError != null) ...[
            const SizedBox(height: 8),
            Text(
              'Enable failed: ${prompt.enableError}',
              style: caption.copyWith(color: MacosColors.systemRedColor),
            ),
          ],
          const SizedBox(height: 12),
          CopyableCommandBlock(
            label: 'Or run this in an elevated PowerShell on the host',
            command: command,
          ),
          const SizedBox(height: 8),
          Text('To undo it later: $kDisableGitBashCommand', style: caption),
        ];
      case WindowsShellPromptKind.notInstalled:
        final install = installHints('bash', 'windows').first;
        return [
          const SizedBox(height: 12),
          CopyableCommandBlock(
            label: 'Install Git for Windows, which includes Git Bash',
            command: install.command,
          ),
          const SizedBox(height: 8),
          const FieldHint(
            'Installed somewhere else? Set its path in Settings, under '
            'External tools (bash), then Reconnect.',
          ),
        ];
      case WindowsShellPromptKind.probeFailed:
        return const [];
    }
  }
}
