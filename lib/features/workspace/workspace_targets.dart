/// Where a clone/create lands, resolved from the sheet's mode + destination
/// selection. Shared by the clone and create sheets.
enum WorkspaceTarget {
  /// This machine's own filesystem (a picked parent folder). Applies to a
  /// connected local session and the landing's "This Mac" destination.
  localMac,

  /// The already-connected SSH host.
  sshActive,

  /// A saved SSH connection chosen from the landing, dialed on demand via the
  /// connection controller's provisioning flow.
  sshProvision,
}

/// What the wizard's Target control is pointing at.
///
/// **Three states, not a nullable id.** The destination was a `String?` where
/// null meant "This Mac" — which left no way to say "the session I am already
/// in" when that session is **ad-hoc** and has no saved id. MADR 0036 removed
/// [WorkspaceTarget.sshActive] on the reasoning that every tab is its own
/// session, and the ad-hoc case fell through the gap: the wizard silently
/// defaulted to This Mac while the user was working on a host, and no
/// selection could reach that host at all (MADR 0038 F2).
///
/// A sentinel id would have restored the capability and re-created the cause —
/// one value meaning two things. This is the type that cannot.
sealed class WorkspaceDestination {
  const WorkspaceDestination();
}

/// This machine's own filesystem.
final class LocalMacDestination extends WorkspaceDestination {
  const LocalMacDestination();

  @override
  bool operator ==(Object other) => other is LocalMacDestination;

  @override
  int get hashCode => 0;
}

/// The session this tab already holds, whether or not it was ever saved.
///
/// Restored 2026-09-08 by the maintainer. Its contract is the one the ported
/// `registerAndActivateSshActive` tests state: register into the saved
/// connection when there is one, and when there is not, **persist nothing but
/// still make the repository live on this session**.
final class ActiveSessionDestination extends WorkspaceDestination {
  const ActiveSessionDestination();

  @override
  bool operator ==(Object other) => other is ActiveSessionDestination;

  @override
  int get hashCode => 1;
}

/// A saved connection, dialled in its own tab (MADR 0036, 1C).
final class SavedConnectionDestination extends WorkspaceDestination {
  const SavedConnectionDestination(this.id);
  final String id;

  @override
  bool operator ==(Object other) =>
      other is SavedConnectionDestination && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
