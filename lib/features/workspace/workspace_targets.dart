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
