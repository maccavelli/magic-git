import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';

/// UI-facing SSH session status for toolbar / ambient chrome.
///
/// Distinct from [ConnectionPhase]: collapses reconnecting/lost into one
/// yellow state and ignores local sessions (returns null).
enum SshUiConnectionStatus { connected, disconnected, reconnecting }

/// Maps [connection] to a compact status for the link strip, or null when
/// the strip should not render (local backend).
SshUiConnectionStatus? sshUiConnectionStatus(ConnectionState connection) {
  if (connection.isLocal) return null;
  if (connection.reconnecting || connection.phase == ConnectionPhase.lost) {
    return SshUiConnectionStatus.reconnecting;
  }
  if (connection.phase == ConnectionPhase.connected) {
    return SshUiConnectionStatus.connected;
  }
  // disconnected, error, connecting (initial) — treat as disconnected for
  // the strip; connecting rarely reaches this chrome.
  return SshUiConnectionStatus.disconnected;
}

/// Compact SSH latency + connection status row.
///
/// Used in two places:
/// * Ambient shell strip (non-Repository pages) with [edgePadding].
/// * Repository toolbar (no outer padding; parent supplies spacing).
///
/// Hidden entirely for local sessions. Latency is hidden until the health
/// monitor has samples; connection status always shows for SSH.
class SshLinkStatusRow extends ConsumerWidget {
  /// Outer horizontal padding (ambient shell uses 8; toolbar uses 0).
  final double horizontalPadding;

  const SshLinkStatusRow({super.key, this.horizontalPadding = 0});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    final status = sshUiConnectionStatus(connection);
    if (status == null) return const SizedBox.shrink();

    // Flexible on both chips: this row rides inside toolbars that get
    // arbitrarily narrow, so each chip must shrink (its label ellipsizes)
    // instead of forcing the parent Row into a painted overflow.
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Flexible(child: LinkStatusChip(compact: true)),
        Flexible(
          child: ConnectionStatusChip(status: status, host: connection.host),
        ),
      ],
    );

    if (horizontalPadding <= 0) return child;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: child,
    );
  }
}

/// Compact ambient SSH link-latency indicator.
///
/// Reads [pingSamplesProvider] (fed by [ConnectionHealthMonitor] RTT samples)
/// — does not open its own probes. Hidden when there are no samples yet or
/// when the session is not in a healthy connected state (reconnect has no
/// meaningful RTT).
class LinkStatusChip extends ConsumerWidget {
  /// When true, omits outer horizontal padding (parent row supplies spacing).
  final bool compact;

  const LinkStatusChip({super.key, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    if (connection.isLocal ||
        !connection.isConnected ||
        connection.reconnecting) {
      return const SizedBox.shrink();
    }
    final samples = ref.watch(pingSamplesProvider);
    if (samples.isEmpty) return const SizedBox.shrink();

    // Rolling median of recent samples — more stable than the latest alone.
    final sorted = [...samples]..sort((a, b) => a.compareTo(b));
    final median = sorted[sorted.length ~/ 2];
    final ms = median.inMilliseconds;
    final (label, color) = _band(ms);
    final typography = MacosTheme.of(context).typography;

    final row = MacosTooltip(
      message:
          'SSH link latency (median of recent keepalives). '
          'Samples come from the connection health monitor.',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.waveform_path, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: typography.caption1.copyWith(color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (compact) const SizedBox(width: 10),
        ],
      ),
    );

    if (compact) return row;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: row,
    );
  }

  static (String, Color) _band(int ms) {
    if (ms < 80) {
      return ('$ms ms', MacosColors.systemGreenColor);
    }
    if (ms < 250) {
      return ('$ms ms', MacosColors.systemYellowColor);
    }
    return ('$ms ms', MacosColors.systemOrangeColor);
  }
}

/// Connected / Disconnected / Reconnecting label for SSH sessions.
class ConnectionStatusChip extends StatelessWidget {
  final SshUiConnectionStatus status;
  final String? host;

  const ConnectionStatusChip({super.key, required this.status, this.host});

  @override
  Widget build(BuildContext context) {
    final (label, color) = _appearance(status);
    final typography = MacosTheme.of(context).typography;
    final hostHint = host == null || host!.isEmpty ? '' : ' ($host)';

    return MacosTooltip(
      message: switch (status) {
        SshUiConnectionStatus.connected => 'SSH session connected$hostHint',
        SshUiConnectionStatus.reconnecting =>
          'SSH session reconnecting$hostHint',
        SshUiConnectionStatus.disconnected =>
          'SSH session disconnected$hostHint',
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.circle_fill, size: 8, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: typography.caption1.copyWith(color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static (String, Color) _appearance(SshUiConnectionStatus status) {
    return switch (status) {
      SshUiConnectionStatus.connected => (
        'Connected',
        MacosColors.systemGreenColor,
      ),
      SshUiConnectionStatus.reconnecting => (
        'Reconnecting',
        MacosColors.systemYellowColor,
      ),
      SshUiConnectionStatus.disconnected => (
        'Disconnected',
        MacosColors.systemRedColor,
      ),
    };
  }
}
