import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/tool_catalog.dart';
import '../../core/ssh/environment_probe.dart';
import '../common/tool_icon_button.dart';

/// The health state of one tool for the current host.
enum _Health { ok, outdated, overridden, missing, unknown }

class _ToolStatus {
  final _Health health;
  final String? version; // detected x.y.z, when known
  const _ToolStatus(this.health, {this.version});
}

/// "Doctor" panel: for each external tool Magic Git uses, shows whether it's
/// present on the connected host, its version against the minimum we rely on,
/// and — when something's missing or outdated — copy-pasteable, platform-aware
/// install commands. Read-only: it never runs anything on the host; the user
/// runs the commands themselves. Re-check re-probes the live connection.
class EnvironmentHealthSheet extends ConsumerWidget {
  const EnvironmentHealthSheet({super.key});

  static _ToolStatus _statusFor(ToolSpec spec, RemoteEnvironment env) {
    if (env.os == 'unknown') return const _ToolStatus(_Health.unknown);
    if (!env.has(spec.bin)) return const _ToolStatus(_Health.missing);
    final vStr = env.versionOf(spec.bin);
    final v = vStr == null ? null : ToolVersion.parse(vStr);
    if (spec.minVersion != null && v != null && v < spec.minVersion!) {
      return _ToolStatus(_Health.outdated, version: v.display);
    }
    if (env.overridden.contains(spec.bin)) {
      return _ToolStatus(_Health.overridden, version: v?.display);
    }
    return _ToolStatus(_Health.ok, version: v?.display);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typography = MacosTheme.of(context).typography;
    final env = ref.watch(binaryEnvironmentProvider);
    final connected = ref.watch(connectionProvider).isConnected;
    final tools = kToolCatalog.where((t) => t.relevantOn(env.os)).toList();

    return MacosSheet(
      child: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 12),
              child: Row(
                children: [
                  const MacosIcon(CupertinoIcons.wrench, size: 18),
                  const SizedBox(width: 8),
                  Text('Environment health', style: typography.title2),
                  const Spacer(),
                  Text(
                    env.os == 'unknown' ? 'Not connected' : 'Host: ${env.osLabel}',
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (env.os == 'unknown')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Connect to a repository to detect the host and check '
                          'which tools are installed.',
                          style: typography.caption1.copyWith(
                            color: MacosColors.systemGrayColor,
                          ),
                        ),
                      ),
                    for (final spec in tools)
                      _toolCard(context, spec, _statusFor(spec, env), env.os),
                    const SizedBox(height: 4),
                    Text(
                      'File watchers (fswatch / inotifywait) are optional — '
                      'without one, Magic Git refreshes by polling every few '
                      'seconds instead of instantly. git is required; glab and '
                      'gh unlock GitLab and GitHub features.',
                      style: typography.caption1.copyWith(
                        color: MacosColors.systemGrayColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PushButton(
                    controlSize: ControlSize.large,
                    secondary: true,
                    onPressed: connected
                        ? () => ref
                              .read(connectionProvider.notifier)
                              .reprobeBinaries()
                        : null,
                    child: const Text('Re-check'),
                  ),
                  const SizedBox(width: 10),
                  PushButton(
                    controlSize: ControlSize.large,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolCard(
    BuildContext context,
    ToolSpec spec,
    _ToolStatus status,
    String os,
  ) {
    final typography = MacosTheme.of(context).typography;
    final (badge, color) = _badge(spec, status);
    // Install/upgrade guidance is shown only when there's action to take, to
    // keep healthy tools quiet.
    final showHints =
        status.health == _Health.missing || status.health == _Health.outdated;
    final hints = showHints ? installHints(spec.bin, os) : const <InstallHint>[];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MacosColors.systemGrayColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(spec.bin, style: typography.headline),
              const SizedBox(width: 8),
              _tierChip(context, spec.tier),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  badge,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: typography.body.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            spec.purpose,
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          for (final hint in hints) _hintRow(context, hint),
        ],
      ),
    );
  }

  Widget _hintRow(BuildContext context, InstallHint hint) {
    final typography = MacosTheme.of(context).typography;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  hint.label,
                  style: typography.caption1.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ToolIconButton(
                icon: CupertinoIcons.doc_on_clipboard,
                tooltip: 'Copy command',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: hint.command)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: MacosColors.black.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              hint.command,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tierChip(BuildContext context, ToolTier tier) {
    final color = switch (tier) {
      ToolTier.essential => MacosColors.systemRedColor,
      ToolTier.feature => MacosColors.systemBlueColor,
      ToolTier.optional => MacosColors.systemGrayColor,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        tier.label,
        style: MacosTheme.of(context).typography.caption2.copyWith(color: color),
      ),
    );
  }

  /// The status badge text + color for a tool.
  (String, Color) _badge(ToolSpec spec, _ToolStatus status) {
    switch (status.health) {
      case _Health.ok:
        return (
          status.version != null ? 'OK · ${status.version}' : 'Installed',
          MacosColors.systemGreenColor,
        );
      case _Health.outdated:
        return (
          'Update · ${status.version} < ${spec.minVersion!.display}',
          MacosColors.systemOrangeColor,
        );
      case _Health.overridden:
        return (
          status.version != null ? 'Override · ${status.version}' : 'Override',
          MacosColors.systemBlueColor,
        );
      case _Health.missing:
        final color = switch (spec.tier) {
          ToolTier.essential => MacosColors.systemRedColor,
          ToolTier.feature => MacosColors.systemOrangeColor,
          ToolTier.optional => MacosColors.systemGrayColor,
        };
        return ('Not installed', color);
      case _Health.unknown:
        return ('Connect to check', MacosColors.systemGrayColor);
    }
  }
}
