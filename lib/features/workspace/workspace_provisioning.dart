import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/storage/saved_connection.dart';

/// The "dial a saved SSH connection so this sheet can work on its host" step,
/// shared by the clone and create-repo sheets.
///
/// Both sheets carried a byte-for-byte copy of this logic, which is how the
/// mid-dial destination-switch bug (0022 H4) came to exist in both while the
/// third caller — `AddExistingRepoSheet` — had already been fixed. One
/// implementation, like the sibling `workspace_registration.dart` keeps one
/// registration matrix, so a guard cannot be fixed in one copy and missed in
/// the other.
///
/// The host sheet supplies its destination and target through
/// [destConnectionId] / [needsProvisioning], and surfaces failures through
/// [onProvisioningError].
mixin WorkspaceProvisioning<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// The provisioning attempt token, once a dial has succeeded. Null means no
  /// session has been adopted — `_register`/submit must not run.
  int? provisionToken;

  /// True while a dial is in flight. Sheets gate their destination control on
  /// this (see the class doc), and their wizard steps treat it as invalid.
  bool provisioning = false;

  /// The saved connection currently chosen as the destination, or null for
  /// "This Mac".
  String? get destConnectionId;

  /// Whether the current target actually needs a provisioned SSH session.
  bool get needsProvisioning;

  /// Surfaces a dial failure in the host sheet's own error slot; null clears.
  void onProvisioningError(String? message);

  /// The controller, captured when a dial starts.
  ///
  /// [resetProvisioning] runs from `dispose()`, where `ref` is already unsafe
  /// ("Using \"ref\" when a widget is about to or has been unmounted"). Before
  /// this was captured, that path threw instead of hanging up — so a wizard
  /// dismissed by its barrier after dialing left a live session stranded at
  /// `phase: connecting`, the buttonless "Connecting…" tab. The controller
  /// outlives the sheet, so holding it is safe.
  ConnectionController? _notifier;

  /// Dials the chosen saved connection (once) so the sheet's work can run on
  /// its host. Returns whether the session is ready.
  Future<bool> ensureProvisioned() async {
    if (!needsProvisioning) return true;
    if (provisionToken != null) return true;
    if (provisioning) return false;
    final conn = await connectionById(destConnectionId);
    if (conn == null || !mounted) return false;
    setState(() {
      provisioning = true;
    });
    onProvisioningError(null);
    // Capture the notifier BEFORE the (seconds-long) dial: `ref` is unusable
    // once this State is disposed, but the controller outlives the sheet, so
    // this is what lets the guard below — and dispose()'s own teardown — still
    // hang up a session nobody owns.
    final ConnectionController notifier =
        _notifier ?? ref.read(connectionProvider.notifier);
    _notifier = notifier;
    final token = await notifier.beginProvisioning(conn);
    if (!mounted || destConnectionId != conn.id) {
      // The sheet closed, or the destination switched to a different host,
      // while this host was still dialing. Adopting the session now would
      // finalize THIS host's repo into the OTHER connection (0022 H4), and
      // leaving it un-adopted strands a live client at phase:connecting — a
      // buttonless "Connecting…" tab. Abort it instead.
      if (token != null) await notifier.abortProvisioning(token);
      // Load-bearing: both sheets' wizard steps are `valid: () => !provisioning`,
      // so returning with this still true permanently disables Continue.
      if (mounted) setState(() => provisioning = false);
      return false;
    }
    setState(() {
      provisioning = false;
      provisionToken = token;
    });
    if (token == null) {
      onProvisioningError(
        ref.read(connectionProvider).error ?? 'Could not connect to host.',
      );
    }
    return token != null;
  }

  /// Abandons any in-flight or adopted provisioning session.
  ///
  /// Safe to call from `dispose()`: it goes through the captured controller,
  /// never `ref`. A null [_notifier] means no dial ever started, so there is
  /// nothing to hang up.
  Future<void> resetProvisioning() async {
    final token = provisionToken;
    provisionToken = null;
    if (token == null) return;
    await _notifier?.abortProvisioning(token);
  }

  /// Resolves a saved connection by id through the provider *future* — the
  /// sync `.value` is null unless something else happens to be watching the
  /// provider (true on the landing, not in connected mode).
  Future<SavedConnection?> connectionById(String? id) async {
    if (id == null) return null;
    final List<SavedConnection> list;
    try {
      list = await ref.read(savedConnectionsProvider.future);
    } catch (_) {
      return null;
    }
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }
}
