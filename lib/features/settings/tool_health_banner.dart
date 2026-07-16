import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/tool_health.dart';
import '../common/escape_dismissible.dart';
import '../common/tool_icon_button.dart';
import 'environment_health_sheet.dart';

/// A thin inline bar across the top of the main window that appears when a
/// connection is up but a required or feature tool is missing (or outdated) on
/// the host — the same summary shown in Settings → External tools, surfaced
/// where the user will see it. Offers a jump into the full doctor panel, and a
/// dismiss that hides it until the situation changes. Renders nothing (zero
/// height) when connected and healthy, or when disconnected.
class ToolHealthBanner extends ConsumerStatefulWidget {
  const ToolHealthBanner({super.key});

  @override
  ConsumerState<ToolHealthBanner> createState() => _ToolHealthBannerState();
}

class _ToolHealthBannerState extends ConsumerState<ToolHealthBanner> {
  /// The message the user last dismissed. Keyed by message text so a *different*
  /// problem (e.g. a second tool goes missing, or the wording changes) re-shows
  /// the banner rather than staying hidden.
  String? _dismissed;

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(connectionProvider).isConnected;
    final env = ref.watch(binaryEnvironmentProvider);
    final report = summarizeToolHealth(env);

    // Only surface a real problem on a live connection; healthy/disconnected
    // states show nothing. (summarizeToolHealth already returns `ok` when
    // disconnected, but guard on `connected` too so a stale env never leaks a
    // banner onto the landing page.)
    final show =
        connected &&
        report.level != ToolHealthLevel.ok &&
        report.message != _dismissed;
    if (!show) return const SizedBox.shrink();

    final isError = report.level == ToolHealthLevel.error;
    final color = isError
        ? MacosColors.systemRedColor
        : MacosColors.systemOrangeColor;
    final typography = MacosTheme.of(context).typography;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          MacosIcon(
            isError
                ? CupertinoIcons.exclamationmark_octagon_fill
                : CupertinoIcons.exclamationmark_triangle_fill,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              report.message,
              style: typography.body,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          ToolIconButton(
            icon: CupertinoIcons.wrench,
            tooltip: 'Scan environment',
            onPressed: _openDoctor,
          ),
          ToolIconButton(
            icon: CupertinoIcons.xmark,
            tooltip: 'Dismiss',
            size: 13,
            onPressed: () => setState(() => _dismissed = report.message),
          ),
        ],
      ),
    );
  }

  void _openDoctor() {
    showMacosSheet<void>(
      context: context,
      builder: (_) => const EscapeDismissible(child: EnvironmentHealthSheet()),
    );
  }
}
