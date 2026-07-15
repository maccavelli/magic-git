import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';

/// Compact ambient SSH link-latency indicator for the main shell.
///
/// Reads [pingSamplesProvider] (fed by [ConnectionHealthMonitor] RTT samples)
/// — does not open its own probes. Hidden when there are no samples yet (just
/// connected) or when the session is reconnecting (the overlay owns that state).
class LinkStatusChip extends ConsumerWidget {
  const LinkStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);
    if (!connection.isConnected || connection.reconnecting) {
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: MacosTooltip(
        message:
            'SSH link latency (median of recent keepalives). '
            'Samples come from the connection health monitor.',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.waveform_path, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: typography.caption1.copyWith(color: color),
            ),
          ],
        ),
      ),
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
