/// The wizard's "where does this land?" control, shared by the clone and
/// create sheets.
///
/// The two carried 50 lines of byte-identical widget code differing only in
/// the hint's verb — "cloned onto" versus "created on" (MADR 0033). Those two
/// strings are now the parameters; everything else is one implementation.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/providers/app_providers.dart';
import 'wizard.dart';
import 'workspace_targets.dart';

class WorkspaceDestinationSection extends ConsumerWidget {
  /// What the control is pointing at — This Mac, the session this tab already
  /// holds, or a saved connection (MADR 0038 F2).
  final WorkspaceDestination selected;

  /// Null disables the control. The callers pass null while submitting or
  /// while a host is still dialing: switching mid-dial otherwise adopts the
  /// in-flight session under the newly selected connection (0022 H4). The
  /// post-await guard in `ensureProvisioned` is the backstop; disabling here
  /// removes the race at the UI level so it cannot be triggered at all. The
  /// gate stays at the call site because that is where its reasons live.
  final ValueChanged<WorkspaceDestination>? onChanged;

  /// Shows the "Connecting…" row while a dial is in flight.
  final bool provisioning;

  /// Hint shown for "This Mac" and for a selected SSH host respectively.
  final String localHint;
  final String remoteHint;

  /// The label to show for a selected saved connection while the list has not
  /// loaded, or if that id is not in it. A connected sheet seeds its selection
  /// from the live session (MADR 0036, 2A) **before** the async list arrives,
  /// and `MacosPopupButton` asserts its value is among its items — so the
  /// seeded row must exist from the first frame.
  final String? selectedLabel;

  const WorkspaceDestinationSection({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.provisioning,
    required this.localHint,
    required this.remoteHint,
    this.selectedLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typography = MacosTheme.of(context).typography;
    final conns = ref.watch(savedConnectionsProvider).value ?? const [];
    final session = ref.watch(connectionProvider);
    // The session this tab holds is offered as its own row **only when it is
    // ad-hoc** — connected over SSH with no saved id. A saved session is
    // already in the list below by id, and offering both would show two rows
    // for one host (MADR 0038 F2).
    final adHoc =
        session.isConnected && !session.isLocal && session.connectionId == null;
    final savedId = switch (selected) {
      SavedConnectionDestination(:final id) => id,
      _ => null,
    };
    final selectedKnown = savedId == null || conns.any((c) => c.id == savedId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Target', style: typography.caption1),
        const SizedBox(height: 4),
        MacosPopupButton<WorkspaceDestination>(
          value: selected,
          onChanged: onChanged == null
              ? null
              : (v) => v == null ? null : onChanged!(v),
          items: [
            const MacosPopupMenuItem<WorkspaceDestination>(
              value: LocalMacDestination(),
              child: Text('This Mac'),
            ),
            if (adHoc)
              MacosPopupMenuItem<WorkspaceDestination>(
                value: const ActiveSessionDestination(),
                child: Text(
                  session.host == null || session.host!.isEmpty
                      ? 'This session'
                      : '${session.host} (this session)',
                ),
              ),
            for (final c in conns)
              MacosPopupMenuItem<WorkspaceDestination>(
                value: SavedConnectionDestination(c.id),
                child: Text(c.displayName),
              ),
            if (!selectedKnown)
              MacosPopupMenuItem<WorkspaceDestination>(
                value: SavedConnectionDestination(savedId),
                child: Text(selectedLabel ?? 'Saved connection'),
              ),
          ],
        ),
        WizardHint(selected is LocalMacDestination ? localHint : remoteHint),
        if (provisioning)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: ProgressCircle(radius: 6),
                ),
                const SizedBox(width: 8),
                Text('Connecting…', style: typography.caption1),
              ],
            ),
          ),
      ],
    );
  }
}
